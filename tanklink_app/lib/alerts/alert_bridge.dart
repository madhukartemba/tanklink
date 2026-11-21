import 'dart:io';

import 'package:flutter/services.dart';

import '../diag/app_log.dart';

/// Dart side of the Android alert code (MainActivity.kt, AlertStore.kt):
/// background pump alerts that work with the app closed. Everything here is
/// a no-op off Android.
class AlertBridge {
  static const _channel = MethodChannel('tanklink/alerts');

  static Future<T?> _call<T>(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } catch (e) {
      AppLog.w('alerts', '$method failed: $e');
      return null;
    }
  }

  /// Background alerts need Android 12 or later (Bluetooth scans for an app
  /// that isn't running).
  static Future<bool> isSupported() async =>
      await _call<bool>('isSupported') ?? false;

  /// Hand Kotlin the pumps it needs to recognise: device id, the phone's
  /// Bluetooth address for it, its name, alert key (hex) and tank and sensor
  /// names (for the notification text).
  static Future<void> syncPumps(List<Map<String, Object?>> pumps) =>
      _call<bool>('syncPumps', {'pumps': pumps});

  static Future<bool> isEnabled() async =>
      await _call<bool>('isEnabled') ?? false;

  static Future<void> setEnabled(bool on) =>
      _call<bool>('setEnabled', {'on': on});

  /// Alert types that notify (pump_alert.h types 1 to 5).
  static Future<List<int>> types() async =>
      (await _call<List<Object?>>('types'))?.cast<int>() ??
      const [1, 2, 3, 4, 5];

  static Future<void> setTypes(List<int> types) =>
      _call<bool>('setTypes', {'types': types});

  /// An alert the app saw over its own connection. Kotlin shows it unless it
  /// already showed that alert (from a scan, or earlier).
  static Future<void> showAlert(String pumpId, int seq, int type, int arg) =>
      _call<bool>('showAlert', {
        'id': pumpId,
        'seq': seq,
        'type': type,
        'arg': arg,
      });

  /// Whether the notification and Bluetooth scan permissions are granted.
  static Future<({bool notifications, bool scan})> permissions() async {
    final m = await _call<Map<Object?, Object?>>('permissions');
    return (
      notifications: m?['notifications'] as bool? ?? false,
      scan: m?['scan'] as bool? ?? false,
    );
  }

  static Future<void> requestPermissions() => _call<bool>('requestPermissions');

  static Future<bool> batteryUnrestricted() async =>
      await _call<bool>('batteryUnrestricted') ?? false;

  static Future<void> openNotificationSettings() =>
      _call<bool>('openNotificationSettings');

  static Future<void> openBatterySettings() =>
      _call<bool>('openBatterySettings');
}
