import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../ble/pump_session.dart';

/// Sends the selected pump's state to the home screen widget and the Quick
/// Settings tile (`PumpGlance.kt`), only when something they show changed.
class GlanceBridge {
  GlanceBridge(this._session) {
    _session.addListener(_push);
  }

  static const _channel = MethodChannel('com.tanklink/glance');

  final PumpSession _session;
  String? _last;

  void _push() {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final s = _session;
    final pump = s.selected;
    final live = s.ready;
    final on = live && s.pumpOn;
    final tank = !live || !s.tankBound
        ? ''
        : '${s.activeTankName} · ${!s.tankOnline
              ? 'Offline'
              : s.tankFull
              ? 'Full'
              : 'Not full'}';
    // The run start moves a little with each run-time read: compare it in
    // 10-second steps so the timer doesn't resend every second.
    final runStart = on
        ? DateTime.now().millisecondsSinceEpoch - s.runSeconds * 1000
        : 0;
    final key = [
      pump?.serial,
      pump?.name,
      live,
      on,
      runStart ~/ 10000,
      tank,
    ].join('|');
    if (key == _last) return;
    _last = key;
    unawaited(
      _channel.invokeMethod<void>('update', {
        'serial': pump?.serial,
        'name': pump?.name,
        'live': live,
        'on': on,
        'runStart': runStart,
        'tank': tank,
        'at': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }
}
