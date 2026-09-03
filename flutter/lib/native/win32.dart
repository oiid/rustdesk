import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'package:win32/win32.dart' as win32;

/// Get windows target build number.
///
/// [Note]
/// Please use this function wrapped with `Platform.isWindows`.
int getWindowsTargetBuildNumber_() {
  final rtlGetVersion = DynamicLibrary.open('ntdll.dll').lookupFunction<
      Void Function(Pointer<win32.OSVERSIONINFOEX>),
      void Function(Pointer<win32.OSVERSIONINFOEX>)>('RtlGetVersion');
  final osVersionInfo = _getOSVERSIONINFOEXPointer();
  rtlGetVersion(osVersionInfo);
  int buildNumber = osVersionInfo.ref.dwBuildNumber;
  calloc.free(osVersionInfo);
  return buildNumber;
}

/// Get Windows OS version pointer
///
/// [Note]
/// Please use this function wrapped with `Platform.isWindows`.
Pointer<win32.OSVERSIONINFOEX> _getOSVERSIONINFOEXPointer() {
  final pointer = calloc<win32.OSVERSIONINFOEX>();
  pointer.ref
    ..dwOSVersionInfoSize = sizeOf<win32.OSVERSIONINFOEX>()
    ..dwBuildNumber = 0
    ..dwMajorVersion = 0
    ..dwMinorVersion = 0
    ..dwPlatformId = 0
    ..szCSDVersion = ''
    ..wServicePackMajor = 0
    ..wServicePackMinor = 0
    ..wSuiteMask = 0
    ..wProductType = 0
    ..wReserved = 0;
  return pointer;
}

// ===== Hide window from screen capture (SetWindowDisplayAffinity) =====
//
// Applies WDA_EXCLUDEFROMCAPTURE to every top-level window owned by the
// current process, so the RustDesk window(s) stay visible on the physical
// monitor but do not appear in screen capture / screen sharing (OBS, Zoom,
// Teams, PrintScreen, most recorders, ...).
//
// [Note]
// - Windows 10 version 2004 (build 19041) or newer is required for
//   WDA_EXCLUDEFROMCAPTURE. On older builds it degrades to WDA_MONITOR
//   (the window shows up black in captures), per the Win32 documentation.
// - This is a privacy convenience, not DRM: it cannot stop a photograph of
//   the screen or kernel/driver-level capture, and only works while the
//   Desktop Window Manager is compositing the desktop.
// - Please call this wrapped with `Platform.isWindows` (also guarded below).

const int _kWdaNone = 0x00000000;
const int _kWdaExcludeFromCapture = 0x00000011;

typedef _NativeEnumWindowsProc = Int32 Function(IntPtr hWnd, IntPtr lParam);

// Shared state for the EnumWindows callback. `Pointer.fromFunction` cannot
// capture a closure, so these top-level fields are set right before each
// enumeration (usage is synchronous and single-threaded).
int _excludeTargetPid = 0;
int _excludeAffinity = _kWdaNone;
int Function(int hWnd, Pointer<Uint32> lpdwProcessId)? _getWindowThreadProcessId;
int Function(int hWnd)? _isWindowVisible;
int Function(int hWnd, int dwAffinity)? _setWindowDisplayAffinity;

int _applyAffinityToWindow(int hWnd, int lParam) {
  final pid = calloc<Uint32>();
  try {
    _getWindowThreadProcessId!(hWnd, pid);
    if (pid.value == _excludeTargetPid) {
      _setWindowDisplayAffinity!(hWnd, _excludeAffinity);
    }
  } finally {
    calloc.free(pid);
  }
  return 1; // TRUE -> continue enumeration
}

/// Exclude (or restore) all top-level windows of the current process from
/// screen capture. Safe no-op on non-Windows platforms.
///
/// [Note]
/// Please use this function wrapped with `Platform.isWindows`.
void setWindowExcludeFromCapture_(bool enable) {
  if (!Platform.isWindows) return;
  final user32 = DynamicLibrary.open('user32.dll');
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  _setWindowDisplayAffinity = user32.lookupFunction<
      Int32 Function(IntPtr hWnd, Uint32 dwAffinity),
      int Function(int hWnd, int dwAffinity)>('SetWindowDisplayAffinity');
  _getWindowThreadProcessId = user32.lookupFunction<
      Uint32 Function(IntPtr hWnd, Pointer<Uint32> lpdwProcessId),
      int Function(int hWnd, Pointer<Uint32> lpdwProcessId)>(
      'GetWindowThreadProcessId');
  _isWindowVisible = user32.lookupFunction<Int32 Function(IntPtr hWnd),
      int Function(int hWnd)>('IsWindowVisible');
  final getCurrentProcessId = kernel32
      .lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');
  final enumWindows = user32.lookupFunction<
      Int32 Function(Pointer<NativeFunction<_NativeEnumWindowsProc>> lpEnumFunc,
          IntPtr lParam),
      int Function(Pointer<NativeFunction<_NativeEnumWindowsProc>> lpEnumFunc,
          int lParam)>('EnumWindows');

  _excludeTargetPid = getCurrentProcessId();
  _excludeAffinity = enable ? _kWdaExcludeFromCapture : _kWdaNone;
  final callback =
      Pointer.fromFunction<_NativeEnumWindowsProc>(_applyAffinityToWindow, 0);
  enumWindows(callback, 0);
}

// ===== Show / hide all app windows (used by the in-session hotkey) =====
// Mirrors the native SetAllProcessWindowsShown in the runner, but callable from
// any isolate (including a remote-session sub-window) so the hide/show hotkey
// works even while the remote view has keyboard focus.

const int _gwOwner = 4;
// SetWindowPos flags: NOSIZE | NOZORDER | NOACTIVATE.
const int _swpMove = 0x0001 | 0x0004 | 0x0010;
// Offset added to stashed coordinates so they are always positive & non-zero
// (a window property value of 0 is indistinguishable from "not set").
const int _hideOff = 100000;

int _showTargetPid = 0;
bool _showStateShow = false;
int Function(int hWnd, Pointer<Uint32> lpdwProcessId)? _showGetWinThreadPid;
int Function(int hWnd, int uCmd)? _getWindow;
int Function(int hWnd)? _getWindowTextLength;
int Function(int hWnd, Pointer<Utf16> lpString)? _getProp;
int Function(int hWnd, Pointer<Utf16> lpString, int hData)? _setProp;
int Function(int hWnd, Pointer<Utf16> lpString)? _removeProp;
int Function(int hWnd, Pointer<Int32> lpRect)? _getWindowRect;
int Function(int hWnd, int after, int x, int y, int cx, int cy, int flags)?
    _setWindowPos;
Pointer<Utf16>? _mainWinPropPtr;
Pointer<Utf16>? _hideXPropPtr;
Pointer<Utf16>? _hideYPropPtr;

// Move each window far off-screen to "hide" and back to "show". We never use
// SW_HIDE/SW_SHOW: hiding recreates the render surface, which then leaks black
// in captures. The original top-left is stashed in window properties so hide
// and show stay consistent regardless of which code path runs them.
int _applyShowStateToWindow(int hWnd, int lParam) {
  final pid = calloc<Uint32>();
  try {
    _showGetWinThreadPid!(hWnd, pid);
    if (pid.value != _showTargetPid ||
        _getWindow!(hWnd, _gwOwner) != 0 ||
        _getWindowTextLength!(hWnd) == 0 ||
        _getProp!(hWnd, _mainWinPropPtr!) != 0) {
      return 1; // skip other processes, dialogs, helpers and the main window
    }
    if (_showStateShow) {
      final hx = _getProp!(hWnd, _hideXPropPtr!);
      if (hx != 0) {
        final x = hx - _hideOff;
        final y = _getProp!(hWnd, _hideYPropPtr!) - _hideOff;
        _setWindowPos!(hWnd, 0, x, y, 0, 0, _swpMove);
        _removeProp!(hWnd, _hideXPropPtr!);
        _removeProp!(hWnd, _hideYPropPtr!);
      }
    } else {
      if (_getProp!(hWnd, _hideXPropPtr!) == 0) {
        final rect = calloc<Int32>(4);
        _getWindowRect!(hWnd, rect);
        final left = rect[0];
        final top = rect[1];
        calloc.free(rect);
        _setProp!(hWnd, _hideXPropPtr!, left + _hideOff);
        _setProp!(hWnd, _hideYPropPtr!, top + _hideOff);
        _setWindowPos!(hWnd, 0, -32000, -32000, 0, 0, _swpMove);
      }
    }
  } finally {
    calloc.free(pid);
  }
  return 1;
}

/// Show or hide every top-level app window of this process by moving it
/// off-screen and back (never SW_HIDE/SW_SHOW). Safe no-op off Windows. Call
/// wrapped with `Platform.isWindows`.
void setAllWindowsShown_(bool show) {
  if (!Platform.isWindows) return;
  final user32 = DynamicLibrary.open('user32.dll');
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  _showGetWinThreadPid = user32.lookupFunction<
      Uint32 Function(IntPtr hWnd, Pointer<Uint32> lpdwProcessId),
      int Function(int hWnd, Pointer<Uint32> lpdwProcessId)>(
      'GetWindowThreadProcessId');
  _getWindow = user32.lookupFunction<IntPtr Function(IntPtr hWnd, Uint32 uCmd),
      int Function(int hWnd, int uCmd)>('GetWindow');
  _getWindowTextLength = user32.lookupFunction<Int32 Function(IntPtr hWnd),
      int Function(int hWnd)>('GetWindowTextLengthW');
  _getProp = user32.lookupFunction<
      IntPtr Function(IntPtr hWnd, Pointer<Utf16> lpString),
      int Function(int hWnd, Pointer<Utf16> lpString)>('GetPropW');
  _setProp = user32.lookupFunction<
      Int32 Function(IntPtr hWnd, Pointer<Utf16> lpString, IntPtr hData),
      int Function(int hWnd, Pointer<Utf16> lpString, int hData)>('SetPropW');
  _removeProp = user32.lookupFunction<
      IntPtr Function(IntPtr hWnd, Pointer<Utf16> lpString),
      int Function(int hWnd, Pointer<Utf16> lpString)>('RemovePropW');
  _getWindowRect = user32.lookupFunction<
      Int32 Function(IntPtr hWnd, Pointer<Int32> lpRect),
      int Function(int hWnd, Pointer<Int32> lpRect)>('GetWindowRect');
  _setWindowPos = user32.lookupFunction<
      Int32 Function(IntPtr hWnd, IntPtr after, Int32 x, Int32 y, Int32 cx,
          Int32 cy, Uint32 flags),
      int Function(int hWnd, int after, int x, int y, int cx, int cy,
          int flags)>('SetWindowPos');
  final getCurrentProcessId = kernel32
      .lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');
  final enumWindows = user32.lookupFunction<
      Int32 Function(Pointer<NativeFunction<_NativeEnumWindowsProc>> lpEnumFunc,
          IntPtr lParam),
      int Function(Pointer<NativeFunction<_NativeEnumWindowsProc>> lpEnumFunc,
          int lParam)>('EnumWindows');
  _showTargetPid = getCurrentProcessId();
  _showStateShow = show;
  _mainWinPropPtr = 'RustDeskMainWin'.toNativeUtf16(allocator: calloc);
  _hideXPropPtr = 'RDHideX'.toNativeUtf16(allocator: calloc);
  _hideYPropPtr = 'RDHideY'.toNativeUtf16(allocator: calloc);
  final cb =
      Pointer.fromFunction<_NativeEnumWindowsProc>(_applyShowStateToWindow, 0);
  enumWindows(cb, 0);
  calloc.free(_mainWinPropPtr!);
  calloc.free(_hideXPropPtr!);
  calloc.free(_hideYPropPtr!);
  _mainWinPropPtr = null;
  _hideXPropPtr = null;
  _hideYPropPtr = null;
}
