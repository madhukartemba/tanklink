/// Byte layouts of the TankLink BLE payloads, as pure functions.
///
/// docs/PROTOCOL.md describes every layout. Nothing here touches Bluetooth,
/// so it is easy to read next to the firmware and to unit test.
///
/// Readers follow the versioning rule: they read the fields they know and
/// ignore extra trailing bytes from a newer protocol minor.
library;

import 'dart:typed_data';

import 'models.dart';
import 'tanklink_uuids.dart';

int _u16(List<int> b, int o) => b[o] | (b[o + 1] << 8);

int _u32(List<int> b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

int _i8(int v) => v > 127 ? v - 256 : v;

String _hex(List<int> bytes) =>
    bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

/// Pump local wall-clock seconds since 1970 (not UTC), 0 = unknown.
DateTime? _pumpLocalTime(int sec) {
  if (sec <= 0) return null;
  final u = DateTime.fromMillisecondsSinceEpoch(sec * 1000, isUtc: true);
  return DateTime(u.year, u.month, u.day, u.hour, u.minute, u.second);
}

/// Pump Info characteristic. This layout is frozen across protocol majors,
/// so it can always be read, even from a pump the app cannot control.
class PumpInfo {
  const PumpInfo({
    required this.protoMajor,
    required this.protoMinor,
    required this.hwRev,
    required this.paired,
    required this.deviceIdHex,
    required this.firmware,
    required this.runSeconds,
  });

  final int protoMajor;
  final int protoMinor;
  final int hwRev;
  final bool paired;
  final String deviceIdHex;
  final String firmware;
  final int runSeconds;

  String get serial => serialFromDeviceId(deviceIdHex);

  static PumpInfo parse(List<int> b) {
    if (b.length < TankLinkUuids.infoLen) {
      throw const FormatException(
        'Pump firmware is too old. Update it over USB.',
      );
    }
    return PumpInfo(
      protoMajor: b[0],
      protoMinor: b[1],
      hwRev: b[2],
      paired: b[3] != 0,
      // b[4] is flags (pairing window open, this connection authed).
      deviceIdHex: _hex(b.sublist(5, 11)),
      firmware: '${b[11]}.${b[12]}.${b[13]}',
      runSeconds: _u32(b, 14),
    );
  }
}

/// Pump Settings characteristic (everything except per-tank auto-off).
class PumpSettings {
  const PumpSettings({
    required this.buzzerFlags,
    required this.buzzerTone,
    required this.ledBrightness,
    required this.starterType,
    required this.relayPulseMs,
    required this.sensorMode,
    this.runSeconds = 0,
  });

  final int buzzerFlags;
  final int buzzerTone;
  final int ledBrightness;
  final int starterType;
  final int relayPulseMs;
  final int sensorMode;

  /// Only present on reads.
  final int runSeconds;

  static const _readLen = 16;

  /// run(4) serial(5) buzzer_flags tone led starter pulse_ms(2) sensor_mode.
  static PumpSettings? parse(List<int> b) {
    if (b.length < _readLen) return null;
    return PumpSettings(
      runSeconds: _u32(b, 0),
      buzzerFlags: b[9],
      buzzerTone: b[10].clamp(0, 3),
      ledBrightness: b[11].clamp(1, 100),
      starterType: b[12],
      relayPulseMs: _u16(b, 13)
          .clamp(TankLinkUuids.relayPulseMsMin, TankLinkUuids.relayPulseMsMax)
          .toInt(),
      sensorMode: b[15].clamp(0, TankLinkUuids.sensorModeTwo),
    );
  }

  /// buzzer_flags tone led starter pulse_ms(2) sensor_mode.
  List<int> encode() => [
    buzzerFlags,
    buzzerTone,
    ledBrightness,
    starterType,
    relayPulseMs & 0xff,
    (relayPulseMs >> 8) & 0xff,
    sensorMode,
  ];
}

/// The pump's Tank characteristic: what it knows about the paired tank.
class TankStatus {
  const TankStatus({
    required this.bound,
    required this.pairing,
    required this.tankIdHex,
    required this.firmware,
    required this.flags,
    required this.batteryPct,
    required this.online,
    required this.ageSec,
    required this.rssiDbm,
    required this.snrDb,
    required this.pumpLastError,
    required this.bleToken,
    required this.interruption,
    required this.hwRev,
  });

  final bool bound;
  final bool pairing;
  final String tankIdHex;

  /// Empty while the tank has never been heard (it reports 0.0.0).
  final String firmware;
  final int flags;
  final int batteryPct;
  final bool online;

  /// Seconds since the last packet, null if never heard.
  final int? ageSec;
  final int rssiDbm;
  final int snrDb;
  final int pumpLastError;

  /// Null when the pump has no token for this tank.
  final Uint8List? bleToken;
  final FillInterruption? interruption;
  final int hwRev;

  static TankStatus? parse(List<int> b) {
    if (b.length < TankLinkUuids.tankStatusLen) return null;
    final fw = '${b[8]}.${b[9]}.${b[10]}';
    final age = _u16(b, 14);
    const t = TankLinkUuids.tankStatusTokenAt;
    final token = Uint8List.fromList(b.sublist(t, t + TankLinkUuids.tokenLen));
    return TankStatus(
      bound: b[0] != 0,
      pairing: b[1] != 0,
      tankIdHex: _hex(b.sublist(2, 8)),
      firmware: fw == '0.0.0' ? '' : fw,
      flags: b[11],
      batteryPct: b[12].clamp(0, 100),
      online: b[13] != 0,
      ageSec: age == 0xFFFF ? null : age,
      rssiDbm: _i8(b[16]),
      snrDb: _i8(b[17]),
      pumpLastError: b[18],
      bleToken: token.any((v) => v != 0) ? token : null,
      interruption: _parseInterruption(b),
      hwRev: b[TankLinkUuids.tankStatusHwRevAt],
    );
  }

  static FillInterruption? _parseInterruption(List<int> b) {
    const o = TankLinkUuids.tankStatusInterruptAt;
    final reason = b[o];
    if (reason == TankLinkUuids.interruptNone) return null;
    return FillInterruption(
      reason: reason,
      startedAt: _pumpLocalTime(_u32(b, o + 1)),
      lastSeenRunningAt: _pumpLocalTime(_u32(b, o + 5)),
      backAt: _pumpLocalTime(_u32(b, o + 9)),
      ranSec: _u32(b, o + 13),
    );
  }
}

/// The pump's Tanks characteristic: float mode and the tank slots.
class TankList {
  const TankList({
    required this.sensorMode,
    required this.activeSlot,
    required this.rawFlags,
    required this.slots,
  });

  final int sensorMode;
  final int activeSlot;
  final int rawFlags;
  final List<TankSlot> slots;

  /// mode active_slot raw_flags count, then count × 19-byte entries.
  static TankList? parse(List<int> b) {
    if (b.length < 4) return null;
    const entry = TankLinkUuids.tanksEntryLen;
    final slots = <TankSlot>[];
    var o = 4;
    for (var i = 0; i < b[3] && o + entry <= b.length; i++, o += entry) {
      final raw = b.sublist(o + 3, o + entry);
      final end = raw.indexOf(0);
      slots.add(
        TankSlot(
          index: b[o],
          sensor: b[o + 1],
          autoOffMin: b[o + 2],
          name: String.fromCharCodes(end < 0 ? raw : raw.sublist(0, end)),
        ),
      );
    }
    return TankList(
      sensorMode: b[0].clamp(0, TankLinkUuids.sensorModeTwo),
      activeSlot: b[1],
      rawFlags: b[2],
      slots: slots,
    );
  }
}

/// The pump's Schedule characteristic: its clock and the daily fill times.
class ScheduleState {
  const ScheduleState({
    required this.clockValid,
    required this.clockHour,
    required this.clockMinute,
    required this.schedules,
    required this.rtcOk,
  });

  final bool clockValid;
  final int clockHour;
  final int clockMinute;
  final List<FillSchedule> schedules;

  /// The DS3231 holds a trusted time, so schedules survive a restart.
  final bool rtcOk;

  static ScheduleState? parse(List<int> b) {
    if (b.length < 5) return null;
    final count = b[3];
    if (count > TankLinkUuids.schedMax || b.length < 5 + count * 4) {
      return null;
    }
    return ScheduleState(
      clockValid: b[0] != 0,
      clockHour: b[1],
      clockMinute: b[2],
      schedules: [
        for (var o = 4; o < 4 + count * 4; o += 4)
          FillSchedule(
            enabled: b[o] != 0,
            hour: b[o + 1],
            minute: b[o + 2],
            slot: b[o + 3],
          ),
      ],
      // clock_flags: bit 0 DS3231 present, bit 1 it holds a trusted time.
      rtcOk: (b[4 + count * 4] & 0x02) != 0,
    );
  }

  /// Set-clock write: the phone's local time.
  static List<int> encodeClock(DateTime now) => [
    TankLinkUuids.schedOpSetClock,
    now.year & 0xff,
    (now.year >> 8) & 0xff,
    now.month,
    now.day,
    now.hour,
    now.minute,
    now.second,
  ];

  /// Replace-list write. [schedules] must already be sorted and valid.
  static List<int> encodeList(List<FillSchedule> schedules) => [
    TankLinkUuids.schedOpSetList,
    schedules.length,
    for (final s in schedules) ...[s.enabled ? 1 : 0, s.hour, s.minute, s.slot],
  ];
}

/// Rename command body: printable ASCII only, as the pump stores it,
/// trimmed after dropping anything else.
List<int> encodeTankName(String name) => String.fromCharCodes([
  for (final c in name.codeUnits)
    if (c >= 0x20 && c <= 0x7e) c,
]).trim().codeUnits;
