import 'dart:io';

import 'package:flutter/services.dart';

/// Android-only: open system package installer for a verified APK path.
class AppInstall {
  static const _channel = MethodChannel('com.tanklink/install');

  static Future<void> installApk(String path) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('In-app APK install is Android-only');
    }
    await _channel.invokeMethod<void>('installApk', {'path': path});
  }
}
