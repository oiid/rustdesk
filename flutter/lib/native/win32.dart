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
