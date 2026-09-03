#include "flutter_window.h"

#include <desktop_multi_window/desktop_multi_window_plugin.h>
#include <texture_rgba_renderer/texture_rgba_renderer_plugin_c_api.h>
#include <flutter_gpu_texture_renderer/flutter_gpu_texture_renderer_plugin_c_api.h>

#include "flutter/generated_plugin_registrant.h"

#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>

#include <optional>
#include <memory>
#include <vector>

#include "win32_desktop.h"

namespace {

// If the window is resized between the creation of the Flutter surface and the
// present of the first frame - which is what the PowerToys FancyZones option
// "Move newly created windows to their last known zone" does - the embedder's
// resize synchronization enters kResizeStarted and from then on only presents
// frames that match the new size. A frame already generated for the old size
// is rejected, nothing schedules a matching one, and the window stays white
// until a real resize re-enters OnWindowSizeChanged, which resets the resize
// target and resends the window metrics. That is why minimize/restore heals
// it; ForceChildRefresh() below does the same programmatically.
// https://github.com/rustdesk/rustdesk/issues/6756
// https://github.com/flutter/flutter/issues/159630
//
// The timer below drives that recovery. Two subtleties, verified against the
// embedder sources (identical in 3.24.5 and 3.44.0):
// - FlutterViewController::ForceRedraw() only schedules a frame when NO resize
//   is pending (resize_status_ == kDone), so it cannot heal the wedge above.
//   It is kept as a cheap first kick for the case it was designed for: a
//   window created hidden and shown later, with nothing scheduling a frame.
// - The SetNextFrameCallback used to detect the first frame fires when a frame
//   is GENERATED (raster thread), even if the resize gate then rejects its
//   present. So it must not be the only stop condition: one final
//   ForceChildRefresh() is issued to guarantee a present at the current size.
//   Note this premise is not load-bearing, and the redundancy is deliberate:
//   if the callback in fact only fired on a successful present, then
//   first_frame_rendered_ would stay false and the timer below would keep
//   nudging until it healed.
// This also relies on HandleTopLevelWindowProc not consuming WM_TIMER (no
// plugin registers a delegate for it today).
constexpr UINT_PTR kForceRedrawTimerId = 0xFB15;
constexpr UINT kForceRedrawIntervalMs = 200;
// Give up eventually (with a log), so a genuinely stuck engine doesn't keep a
// timer alive forever. 25 * 200ms covers slow starts comfortably.
constexpr UINT kForceRedrawMaxTries = 25;
// The first ticks use the cheap ForceRedraw(); later ticks use
// ForceChildRefresh(), which may block the platform thread for up to 2x100ms
// per call (each nudge re-enters the 100ms resize wait).
constexpr UINT kForceRedrawCheapTries = 2;

// Re-enters the embedder's OnWindowSizeChanged by nudging the Flutter child
// window by 1px and back: this resets the resize target and resends the window
// metrics. Same as BaseFlutterWindow::ForceChildRefresh() on the
// rustdesk_desktop_multi_window side.
void ForceChildRefresh(HWND child) {
  if (!child) {
    return;
  }
  RECT rect;
  GetWindowRect(child, &rect);
  LONG width = rect.right - rect.left;
  LONG height = rect.bottom - rect.top;
  SetWindowPos(child, nullptr, 0, 0, width + 1, height,
               SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_NOMOVE | SWP_FRAMECHANGED);
  SetWindowPos(child, nullptr, 0, 0, width, height,
               SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_NOMOVE | SWP_FRAMECHANGED);
}

// ---- Global hide/show hotkey ----
// A single global hotkey (configured from the Dart settings page) toggles the
// visibility of every top-level window of this process, so the whole app can be
// summoned / dismissed instantly.
// Two independent hotkeys: one hides all app windows, one shows them.
constexpr int kHideHotkeyId = 0xB0B1;
constexpr int kShowHotkeyId = 0xB0B2;

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif
// Whether hide-from-capture is enabled (set from Dart; default on to match the
// app default). Used to re-apply capture exclusion when re-showing a window.
bool g_hide_from_capture = true;

// Reliably bring a window to the foreground in one shot (Windows' foreground
// lock otherwise makes a plain SetForegroundWindow no-op, so "show" needed a
// second press). Attaching to the current foreground thread grants the right.
void ForceForeground(HWND hwnd) {
  HWND fg = GetForegroundWindow();
  DWORD fgTid = fg ? GetWindowThreadProcessId(fg, nullptr) : 0;
  DWORD myTid = GetCurrentThreadId();
  bool attached = false;
  if (fgTid != 0 && fgTid != myTid) {
    attached = AttachThreadInput(myTid, fgTid, TRUE) != 0;
  }
  BringWindowToTop(hwnd);
  SetForegroundWindow(hwnd);
  SetFocus(hwnd);
  if (attached) {
    AttachThreadInput(myTid, fgTid, FALSE);
  }
}

// The window of THIS process that held the foreground when we last hid, so
// "show" can hand keyboard focus back to exactly that window (e.g. the remote
// window that owns the connect-password field) instead of some other window.
HWND g_last_foreground = nullptr;
// First eligible window seen during a "show" pass - the fallback focus target
// when we have no recorded foreground (e.g. show without a prior native hide).
HWND g_show_first = nullptr;

// Show (lparam != 0) or hide (lparam == 0) every top-level app window of this
// process. EnumWindows also enumerates hidden windows, so "show" can un-hide
// windows previously hidden by the hide hotkey.
BOOL CALLBACK ApplyShowStateProc(HWND hwnd, LPARAM show) {
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  if (pid != GetCurrentProcessId()) {
    return TRUE;
  }
  if (GetWindow(hwnd, GW_OWNER) != nullptr) {
    return TRUE;  // skip owned/dialog windows
  }
  if (GetWindowTextLengthW(hwnd) == 0) {
    return TRUE;  // skip title-less helper windows
  }
  // Keep every app window out of the taskbar / Alt+Tab (covers the plugin-
  // created sub-windows that the runner's OnCreate never touches).
  {
    LONG_PTR ex = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
    if (!(ex & WS_EX_TOOLWINDOW)) {
      SetWindowLongPtr(hwnd, GWL_EXSTYLE,
                       (ex | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW);
    }
  }
  // We do NOT use SW_HIDE / SW_SHOW (or off-screen moves): hiding recreates the
  // window's render surface, which then leaks black in captures, and moving a
  // maximized window breaks its restore. Instead we clip the window to an empty
  // region to hide it (invisible to the user, still never SW_HIDDEN) and remove
  // the region to show it. The surface, position, maximize state and capture
  // exclusion are all left untouched. Stateless, so it works no matter which
  // code path (native hotkey or Dart) runs hide vs show.
  if (show) {
    SetWindowRgn(hwnd, nullptr, TRUE);  // restore the full window
    if (g_hide_from_capture) {
      SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
    }
    // Do NOT foreground here: foregrounding every window in turn lets the last
    // one enumerated (lowest in Z-order) steal focus, which is what broke
    // typing/paste in the connect-password field after a hide/show. We restore
    // focus to a single window once, in SetAllProcessWindowsShown.
    if (g_show_first == nullptr && IsWindowVisible(hwnd)) {
      g_show_first = hwnd;
    }
  } else {
    SetWindowRgn(hwnd, CreateRectRgn(0, 0, 0, 0), TRUE);  // clip to nothing
  }
  return TRUE;
}

void SetAllProcessWindowsShown(bool show) {
  if (!show) {
    // Remember which of our windows had keyboard focus so "show" can give it
    // straight back (the password field lives in whichever window was active).
    HWND fg = GetForegroundWindow();
    DWORD pid = 0;
    if (fg) {
      GetWindowThreadProcessId(fg, &pid);
    }
    g_last_foreground = (fg && pid == GetCurrentProcessId()) ? fg : nullptr;
    EnumWindows(ApplyShowStateProc, FALSE);
    return;
  }
  g_show_first = nullptr;
  EnumWindows(ApplyShowStateProc, TRUE);
  // Restore focus to exactly one window: the one that was active when we hid,
  // else the top-most window we just un-hid.
  HWND target = (g_last_foreground && IsWindow(g_last_foreground) &&
                 IsWindowVisible(g_last_foreground))
                    ? g_last_foreground
                    : g_show_first;
  if (target && IsWindow(target) && IsWindowVisible(target)) {
    ForceForeground(target);
  }
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  flutter::MethodChannel<> channel(
    flutter_controller_->engine()->messenger(),
    "org.rustdesk.rustdesk/host",
    &flutter::StandardMethodCodec::GetInstance());

  channel.SetMethodCallHandler(
    [this](const flutter::MethodCall<>& call, std::unique_ptr<flutter::MethodResult<>> result) {
      if (call.method_name() == "bumpMouse") {
        auto arguments = call.arguments();

        int dx = 0, dy = 0;

        if (std::holds_alternative<flutter::EncodableMap>(*arguments)) {
          auto argsMap = std::get<flutter::EncodableMap>(*arguments);

          auto dxIt = argsMap.find(flutter::EncodableValue("dx"));
          auto dyIt = argsMap.find(flutter::EncodableValue("dy"));

          if ((dxIt != argsMap.end()) && std::holds_alternative<int>(dxIt->second)) {
            dx = std::get<int>(dxIt->second);
          }
          if ((dyIt != argsMap.end()) && std::holds_alternative<int>(dyIt->second)) {
            dy = std::get<int>(dyIt->second);
          }
        } else if (std::holds_alternative<flutter::EncodableList>(*arguments)) {
          auto argsList = std::get<flutter::EncodableList>(*arguments);

          if ((argsList.size() >= 1) && std::holds_alternative<int>(argsList[0])) {
            dx = std::get<int>(argsList[0]);
          }
          if ((argsList.size() >= 2) && std::holds_alternative<int>(argsList[1])) {
            dy = std::get<int>(argsList[1]);
          }
        }

        bool succeeded = Win32Desktop::BumpMouse(dx, dy);

        result->Success(succeeded);
      } else if (call.method_name() == "setHideHotkey" ||
                 call.method_name() == "setShowHotkey") {
        int mods = 0, vk = 0;
        auto arguments = call.arguments();
        if (std::holds_alternative<flutter::EncodableMap>(*arguments)) {
          auto argsMap = std::get<flutter::EncodableMap>(*arguments);
          auto mIt = argsMap.find(flutter::EncodableValue("modifiers"));
          auto kIt = argsMap.find(flutter::EncodableValue("keyCode"));
          if ((mIt != argsMap.end()) && std::holds_alternative<int>(mIt->second)) {
            mods = std::get<int>(mIt->second);
          }
          if ((kIt != argsMap.end()) && std::holds_alternative<int>(kIt->second)) {
            vk = std::get<int>(kIt->second);
          }
        }
        int id = (call.method_name() == "setHideHotkey") ? kHideHotkeyId
                                                         : kShowHotkeyId;
        UnregisterHotKey(this->GetHandle(), id);
        bool ok = true;
        if (vk != 0) {
          ok = RegisterHotKey(this->GetHandle(), id,
                              static_cast<UINT>(mods) | MOD_NOREPEAT,
                              static_cast<UINT>(vk)) != 0;
        }
        result->Success(flutter::EncodableValue(ok));
      } else if (call.method_name() == "setHideFromCapture") {
        auto args = call.arguments();
        if (std::holds_alternative<bool>(*args)) {
          g_hide_from_capture = std::get<bool>(*args);
        }
        result->Success();
      }
    });

  DesktopMultiWindowSetWindowCreatedCallback([](void *controller) {
    auto *flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController *>(controller);
    auto *registry = flutter_view_controller->engine();
    TextureRgbaRendererPluginCApiRegisterWithRegistrar(
        registry->GetRegistrarForPlugin("TextureRgbaRendererPlugin"));
    FlutterGpuTextureRendererPluginCApiRegisterWithRegistrar(
        registry->GetRegistrarForPlugin("FlutterGpuTextureRendererPluginCApi"));
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Hide this window from screen capture by default, applied here (before the
  // window is ever shown) so it can't be missed by startup-timing races. The
  // Dart side reconciles this to the saved option after startup and drives the
  // Settings toggle.
#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif
  SetWindowDisplayAffinity(GetHandle(), WDA_EXCLUDEFROMCAPTURE);

  // Keep this window out of the taskbar and Alt+Tab (set before it is shown, so
  // no taskbar button is ever created).
  {
    LONG_PTR ex = GetWindowLongPtr(GetHandle(), GWL_EXSTYLE);
    SetWindowLongPtr(GetHandle(), GWL_EXSTYLE,
                     (ex | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW);
  }

  // See the comment on kForceRedrawTimerId above.
  flutter_controller_->engine()->SetNextFrameCallback(
      [this]() { first_frame_rendered_ = true; });
  SetTimer(GetHandle(), kForceRedrawTimerId, kForceRedrawIntervalMs, nullptr);

  return true;
}

void FlutterWindow::OnDestroy() {
  KillTimer(GetHandle(), kForceRedrawTimerId);
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_HOTKEY:
      if (static_cast<int>(wparam) == kHideHotkeyId) {
        SetAllProcessWindowsShown(false);
        return 0;
      }
      if (static_cast<int>(wparam) == kShowHotkeyId) {
        SetAllProcessWindowsShown(true);
        return 0;
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_TIMER:
      if (wparam == kForceRedrawTimerId) {
        if (!flutter_controller_) {
          KillTimer(hwnd, kForceRedrawTimerId);
        } else if (first_frame_rendered_) {
          // A frame was generated, which does not mean it was presented: if a
          // resize was pending, the gate rejected it (see the comment on
          // kForceRedrawTimerId). One child refresh guarantees a present at the
          // current size. Unconditional because gating it bought nothing: the
          // WM_SIZE that CreateWindow() sends already arrives before the first
          // frame, so the flag this used to check was always set by the time we
          // got here. Doing it unconditionally is safe either way - at worst it
          // is one extra nudge, and it is cheap once the engine is running.
          ForceChildRefresh(flutter_controller_->view()->GetNativeWindow());
          KillTimer(hwnd, kForceRedrawTimerId);
        } else if (++force_redraw_tries_ > kForceRedrawMaxTries) {
          // Not std::cerr: the runner only attaches a console when started from
          // one or under a debugger (see main.cpp), and this fires on end-user
          // machines. OutputDebugString is readable with DebugView there.
          OutputDebugStringA(
              "rustdesk: Flutter window did not render its first frame, "
              "giving up.\n");
          KillTimer(hwnd, kForceRedrawTimerId);
        } else if (force_redraw_tries_ <= kForceRedrawCheapTries) {
          flutter_controller_->ForceRedraw();
        } else {
          ForceChildRefresh(flutter_controller_->view()->GetNativeWindow());
        }
        return 0;
      }
      break;
    case WM_SHOWWINDOW:
      // A window created hidden (e.g. the connection manager) may be shown
      // long after the creation-time force-redraw timer has given up, and
      // FancyZones moves windows exactly when they are shown. Re-arm the
      // protection if the first frame still hasn't been rendered by now (see
      // kForceRedrawTimerId).
      if (wparam == TRUE && !first_frame_rendered_ && flutter_controller_) {
        force_redraw_tries_ = 0;
        SetTimer(hwnd, kForceRedrawTimerId, kForceRedrawIntervalMs, nullptr);
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
