import 'dart:io';

import 'package:flutter/services.dart';

import '../diag/app_log.dart';

/// Looks a pump up on the home network by its mDNS record (Android's
/// NsdManager, through MainActivity). Used when the saved address stopped
/// working, for example after the router handed the pump a new one.
class PumpFinder {
  static const _channel = MethodChannel('com.tanklink/install');

  /// The pump's IPv4 address, or null if it wasn't heard in [timeout].
  static Future<String?> find(
    String deviceIdHex, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('findPump', {
        'id': deviceIdHex.toLowerCase(),
        'timeoutMs': timeout.inMilliseconds,
      });
    } catch (e) {
      AppLog.w('wifi', 'Pump lookup failed: $e');
      return null;
    }
  }
}
