import 'dart:convert';
import 'dart:typed_data';

import 'tanklink_uuids.dart';

/// Last four hex digits of a device id, shown as the pump's serial (#A1B2).
String serialFromDeviceId(String hex) {
  final clean = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
  if (clean.length >= 4) {
    return clean.substring(clean.length - 4);
  }
  if (clean.isEmpty) return '----';
  return clean.padLeft(4, '0');
}

class SavedPump {
  SavedPump({
    required this.remoteId,
    required this.deviceIdHex,
    required this.token,
    String? name,
    String? serial,
  }) : serial = (serial != null && serial.isNotEmpty)
           ? serial.toUpperCase()
           : serialFromDeviceId(deviceIdHex),
       name = _resolveName(name, serial ?? serialFromDeviceId(deviceIdHex));

  final String remoteId;
  final String deviceIdHex;
  final Uint8List token;
  final String name;
  final String serial;

  static String _resolveName(String? name, String serial) {
    if (name == null || name.trim().isEmpty) {
      return 'Pump $serial';
    }
    return name.trim();
  }

  /// "Kitchen · #A1B2"
  String get displayTitle => '$name · #$serial';

  SavedPump copyWith({
    String? remoteId,
    String? name,
    String? deviceIdHex,
    String? serial,
    Uint8List? token,
  }) {
    final id = deviceIdHex ?? this.deviceIdHex;
    return SavedPump(
      remoteId: remoteId ?? this.remoteId,
      deviceIdHex: id,
      token: token ?? this.token,
      name: name ?? this.name,
      serial: serial ?? this.serial,
    );
  }

  Map<String, dynamic> toJson() => {
    'remoteId': remoteId,
    'deviceIdHex': deviceIdHex,
    'token': base64Encode(token),
    'name': name,
    'serial': serial,
  };

  static SavedPump? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final tokenB64 = json['token'] as String?;
    final remoteId = json['remoteId'] as String?;
    final deviceIdHex = json['deviceIdHex'] as String?;
    if (tokenB64 == null || remoteId == null || deviceIdHex == null) {
      return null;
    }
    return SavedPump(
      remoteId: remoteId,
      deviceIdHex: deviceIdHex,
      token: Uint8List.fromList(base64Decode(tokenB64)),
      name: json['name'] as String?,
      serial: json['serial'] as String?,
    );
  }
}

/// One daily fill time stored on the pump. Runs every day.
class FillSchedule {
  FillSchedule({
    required this.enabled,
    required this.hour,
    required this.minute,
    this.slot = 0,
  });

  final bool enabled;
  final int hour;
  final int minute;
  final int slot;

  int get minutesOfDay => hour * 60 + minute;

  FillSchedule copyWith({bool? enabled, int? hour, int? minute, int? slot}) {
    return FillSchedule(
      enabled: enabled ?? this.enabled,
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
      slot: slot ?? this.slot,
    );
  }
}

/// One logical tank stored on the pump.
class TankSlot {
  TankSlot({
    required this.index,
    required this.sensor,
    required this.name,
    required this.autoOffMin,
    required this.node,
  });

  final int index;

  /// Which float pin of its sensor is this tank's full float: 0 or 1.
  final int sensor;
  final String name;

  /// Index of the tank sensor it belongs to, [TankLinkUuids.sensorNone] for
  /// a pump with no sensor.
  final int node;

  /// Stop a fill into this tank after this many minutes. 0 = off.
  final int autoOffMin;

  TankSlot copyWith({String? name, int? autoOffMin}) => TankSlot(
    index: index,
    sensor: sensor,
    name: name ?? this.name,
    autoOffMin: autoOffMin ?? this.autoOffMin,
    node: node,
  );
}

/// A fill the pump was running when it lost power or restarted.
class FillInterruption {
  FillInterruption({
    required this.reason,
    this.startedAt,
    this.lastSeenRunningAt,
    this.backAt,
    required this.ranSec,
  });

  /// One of [TankLinkUuids.interruptPowerLost] / `interruptBrownout` /
  /// `interruptRestarted`.
  final int reason;
  final DateTime? startedAt;

  /// About when it stopped (last time the pump saw itself running, ±1 min).
  final DateTime? lastSeenRunningAt;

  /// When the pump came back.
  final DateTime? backAt;
  final int ranSec;
}

/// One finished fill, from the pump's History characteristic.
class FillRecord {
  FillRecord({
    required this.startedAt,
    required this.ranSec,
    required this.slot,
    required this.startedBy,
    required this.stoppedBy,
  });

  /// Pump-local time, null when the pump's clock was unknown.
  final DateTime? startedAt;
  final int ranSec;
  final int slot;

  /// [TankLinkUuids.causeApp] and the other `cause*` values.
  final int startedBy;
  final int stoppedBy;
}

/// A sensor's lowest and highest battery on one pump-local day.
class BatteryDay {
  const BatteryDay({
    required this.day,
    required this.minPct,
    required this.maxPct,
  });

  /// Days since 1970 on the pump's local clock.
  final int day;
  final int minPct;
  final int maxPct;
}
