import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/main.dart';
import 'package:flutter_hbb/common.dart';

enum SystemWindowTheme { light, dark }

/// The platform channel for RustDesk.
class RdPlatformChannel {
  RdPlatformChannel._();

  static final RdPlatformChannel _windowUtil = RdPlatformChannel._();

  static RdPlatformChannel get instance => _windowUtil;

  final MethodChannel _hostMethodChannel =
      MethodChannel("org.rustdesk.rustdesk/host");

  /// Bump the position of the mouse cursor, if applicable
  Future<bool> bumpMouse({required int dx, required int dy}) async {
    // No debug output; this call is too chatty.

    bool? result = await _hostMethodChannel
      .invokeMethod("bumpMouse", {"dx": dx, "dy": dy});

    return result ?? false;
  }

  /// Register (or re-register) the global "hide window(s)" hotkey. Windows only.
  /// [keyCode] of 0 clears it. Returns whether registration succeeded.
  Future<bool> setHideHotkey(
      {required int modifiers, required int keyCode}) async {
    bool? result = await _hostMethodChannel.invokeMethod(
        "setHideHotkey", {"modifiers": modifiers, "keyCode": keyCode});
    return result ?? false;
  }

  /// Register (or re-register) the global "show window(s)" hotkey. Windows only.
  Future<bool> setShowHotkey(
      {required int modifiers, required int keyCode}) async {
    bool? result = await _hostMethodChannel.invokeMethod(
        "setShowHotkey", {"modifiers": modifiers, "keyCode": keyCode});
    return result ?? false;
  }

  /// Tell the native runner whether hide-from-capture is enabled, so it can
  /// re-apply capture exclusion whenever it re-shows a window. Windows only.
  Future<void> setHideFromCapture(bool enable) {
    return _hostMethodChannel.invokeMethod("setHideFromCapture", enable);
  }

  /// Change the theme of the system window
  Future<void> changeSystemWindowTheme(SystemWindowTheme theme) {
    assert(isMacOS);
    if (kDebugMode) {
      print(
          "[Window ${kWindowId ?? 'Main'}] change system window theme to ${theme.name}");
    }
    return _hostMethodChannel
        .invokeMethod("setWindowTheme", {"themeName": theme.name});
  }

  /// Terminate .app manually.
  Future<void> terminate() {
    assert(isMacOS);
    return _hostMethodChannel.invokeMethod("terminate");
  }
}
