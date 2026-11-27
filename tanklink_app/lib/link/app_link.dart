import 'package:flutter/services.dart';

import '../ble/models.dart';

/// Links that open the app: https://tanklink.madhukartemba.in/pump and
/// `/pump/<serial>` (Android App Links, verified by the report service's
/// /.well-known/assetlinks.json). An NFC tag on the pump holds one. Without
/// the app the same link opens the website.
class AppLink {
  AppLink._();

  static const _channel = MethodChannel('com.tanklink/link');

  static const host = 'tanklink.madhukartemba.in';

  /// The link the app was opened with, once (null after the first call, or
  /// when it was opened another way).
  static Future<String?> initial() =>
      _channel.invokeMethod<String>('initialLink');

  /// The launcher icon's long-press menu: one shortcut per saved pump, each
  /// opening its `/pump/<serial>` link.
  static Future<void> setShortcuts(List<SavedPump> pumps) =>
      _channel.invokeMethod<void>('setShortcuts', [
        for (final p in pumps) {'serial': p.serial, 'name': p.name},
      ]);

  /// Links that arrive while the app is running.
  static void listen(void Function(String url) onLink) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'link' && call.arguments is String) {
        onLink(call.arguments as String);
      }
    });
  }
}

final _pumpPath = RegExp(r'^/pump/([0-9a-fA-F]{4})/?$');

/// The pump serial ("A1B2", as in "#A1B2") a link names, or null for a link
/// that only opens the app (/pump) or isn't ours.
String? pumpSerialFromLink(String? url) {
  if (url == null) return null;
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https' || uri.host != AppLink.host) {
    return null;
  }
  return _pumpPath.firstMatch(uri.path)?.group(1)!.toUpperCase();
}
