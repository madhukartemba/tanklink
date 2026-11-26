/// Byte layouts of the TankLink BLE payloads, as pure functions.
///
/// docs/PROTOCOL.md describes every layout. Nothing here touches Bluetooth,
/// so it is easy to read next to the firmware and to unit test.
///
/// Readers follow the versioning rule: they read the fields they know and
/// ignore extra trailing bytes from a newer protocol minor.
library;

import 'dart:typed_data';

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../util/water_use.dart';

import 'models.dart';
import 'tanklink_uuids.dart';

int _u16(List<int> b, int o) => b[o] | (b[o + 1] << 8);

int _u32(List<int> b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

int _i8(int v) => v > 127 ? v - 256 : v;

/// The Auth answer for a board's 16-byte [nonce]: HMAC-SHA256(token,
/// "TLauth" || nonce), first 16 bytes. Same on pump and tank
/// (components/tanklink_lora/tanklink_crypto.c). The token never goes on air.
Uint8List authResponse(List<int> token, List<int> nonce) {
  if (nonce.length != TankLinkUuids.nonceLen) {
    throw ArgumentError('nonce must be ${TankLinkUuids.nonceLen} bytes');
  }
  final mac = Hmac(sha256, token).convert([...'TLauth'.codeUnits, ...nonce]);
  return Uint8List.fromList(mac.bytes.sublist(0, TankLinkUuids.tokenLen));
}

String _hex(List<int> bytes) =>
    bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

/// 12 hex digits (colons allowed) to 6 bytes.
List<int> _unhex(String hex) {
  final clean = hex.replaceAll(':', '');
  if (clean.length != 12) {
    throw ArgumentError.value(hex, 'hex', 'expected a 6-byte id');
  }
  return [
    for (var i = 0; i < 12; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ];
}

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
    this.pairingOpen = false,
  });

  final int protoMajor;
  final int protoMinor;
  final int hwRev;
  final bool paired;
  final String deviceIdHex;
  final String firmware;
  final int runSeconds;

  /// The phone pairing window is open (Info flags bit 0).
  final bool pairingOpen;

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
      // b[4] is flags: bit 0 pairing window open, bit 1 this connection
      // is authed.
      pairingOpen: (b[4] & 0x01) != 0,
      deviceIdHex: _hex(b.sublist(5, 11)),
      firmware: '${b[11]}.${b[12]}.${b[13]}',
      runSeconds: _u32(b, 14),
    );
  }
}

/// Whether a pump seen in a scan can be added, from its advertising.
enum PumpAdvState {
  /// A phone can add it now (pairing window open, or never set up).
  ready,

  /// It belongs to someone and its pairing window is closed.
  notReady,

  /// Firmware before protocol minor 2 doesn't say.
  unknown,
}

/// Reads the pump's advertising state byte: manufacturer data under
/// company 0xFFFF as flutter_blue_plus gives it (company ID → bytes).
PumpAdvState pumpAdvState(Map<int, List<int>> manufacturerData) {
  final d = manufacturerData[TankLinkUuids.tankMfgCompanyId];
  if (d == null || d.isEmpty) return PumpAdvState.unknown;
  return (d[0] & TankLinkUuids.advStateClaimable) != 0
      ? PumpAdvState.ready
      : PumpAdvState.notReady;
}

/// One alert from the pump: its number, what happened and to which tank or
/// sensor. [arg] is a tank slot, or a sensor index for a low battery.
class PumpAlert {
  const PumpAlert({
    required this.seq,
    required this.type,
    required this.arg,
    this.ageMin,
  });

  final int seq;
  final int type;
  final int arg;

  /// Minutes since the pump raised it (log entries only).
  final int? ageMin;
}

/// The first 4 bytes of HMAC-SHA256(alertKey, deviceId[6] || seq || type ||
/// arg): what proves an alert came from this pump. Same as make_tag in
/// pump_node/main/pump_alert.c and AlertNotifier.kt.
List<int> alertTag(
  List<int> key,
  List<int> deviceId,
  int seq,
  int type,
  int arg,
) {
  final mac = Hmac(sha256, key).convert([...deviceId, seq, type, arg]).bytes;
  return mac.sublist(0, TankLinkUuids.alertTagLen);
}

/// An alert in the pump's advertisement, if it carries one: manufacturer
/// data state(1) seq type arg tag(4). Null without the alert bit.
PumpAlert? pumpAdvAlert(Map<int, List<int>> manufacturerData) {
  final d = manufacturerData[TankLinkUuids.tankMfgCompanyId];
  if (d == null ||
      d.length < 8 ||
      (d[0] & TankLinkUuids.advStateAlert) == 0 ||
      d[1] == 0) {
    return null;
  }
  return PumpAlert(seq: d[1], type: d[2], arg: d[3]);
}

/// The Alert log read: count(1), then count x seq type arg age_min(u16),
/// newest first.
List<PumpAlert> parseAlertLog(List<int> b) {
  if (b.isEmpty) return const [];
  final out = <PumpAlert>[];
  var o = 1;
  for (var i = 0; i < b[0] && o + 5 <= b.length; i++, o += 5) {
    out.add(
      PumpAlert(
        seq: b[o],
        type: b[o + 1],
        arg: b[o + 2],
        ageMin: b[o + 3] | (b[o + 4] << 8),
      ),
    );
  }
  return out;
}

/// UTF-8 text up to its first NUL.
String _nulTerminated(List<int> b) {
  final end = b.indexOf(0);
  return utf8.decode(end < 0 ? b : b.sublist(0, end), allowMalformed: true);
}

/// Pump Settings characteristic (pump-wide; auto-off and float modes are
/// per tank and per sensor, the buzzer and auto-fill have their own).
class PumpSettings {
  const PumpSettings({
    required this.ledBrightness,
    required this.starterType,
    required this.relayPulseMs,
    this.runSeconds = 0,
    this.usage = const UsageSettings(),
    this.autoUpdate = false,
    this.name = '',
    this.tankUpdateSec = TankLinkUuids.tankUpdateDefaultSec,
  });

  final int ledBrightness;
  final int starterType;
  final int relayPulseMs;

  /// Only present on reads.
  final int runSeconds;

  /// Flow, power and price for the usage charts (read only here; written
  /// with [encodeUsage]).
  final UsageSettings usage;

  /// The pump installs its own updates when it is idle.
  final bool autoUpdate;

  /// The pump's own name, shown by every phone that has it. Empty until
  /// someone names it.
  final String name;

  /// Seconds between tank sensor updates (read only here; written with
  /// [encodeTankUpdateSec]).
  final int tankUpdateSec;

  static const readLen = 50;

  /// run(4) serial(5) led starter pulse_ms(2), then flow_dlpm(2) watts(2)
  /// price_centi(2) currency(4) auto_update(1) name(24, UTF-8, NUL-padded),
  /// then tank_update_sec(2).
  static PumpSettings? parse(List<int> b) {
    if (b.length < readLen) return null;
    final flow = _u16(b, 13);
    final price = _u16(b, 17);
    final cur = b.sublist(19, 23);
    final end = cur.indexOf(0);
    return PumpSettings(
      usage: UsageSettings(
        flowLpm: flow == 0 ? null : flow / 10,
        pumpWatts: _u16(b, 15).toDouble(),
        pricePerKwh: price == 0 ? null : price / 100,
        currency: utf8.decode(end < 0 ? cur : cur.sublist(0, end)),
      ),
      autoUpdate: b[23] != 0,
      name: _nulTerminated(b.sublist(24, 48)),
      tankUpdateSec: _u16(b, 48),
      runSeconds: _u32(b, 0),
      ledBrightness: b[9].clamp(1, 100),
      starterType: b[10],
      relayPulseMs: _u16(b, 11)
          .clamp(TankLinkUuids.relayPulseMsMin, TankLinkUuids.relayPulseMsMax)
          .toInt(),
    );
  }

  /// Cmd 0xAF: how often every tank sensor sends an update.
  static List<int> encodeTankUpdateSec(int sec) => [
    TankLinkUuids.cmdTankUpdateSec,
    sec & 0xff,
    (sec >> 8) & 0xff,
  ];

  /// led starter pulse_ms(2) auto_update(1).
  List<int> encode() => [
    ledBrightness,
    starterType,
    relayPulseMs & 0xff,
    (relayPulseMs >> 8) & 0xff,
    autoUpdate ? 1 : 0,
  ];
}

/// One daily time window (auto-fill's allowed times, the buzzer's quiet
/// hours), in pump-local time. [end] before [start] runs past midnight;
/// [days] are the days it starts on, bit 0 = Monday ... bit 6 = Sunday.
class DayWindow {
  const DayWindow({
    required this.start,
    required this.end,
    this.days = allDays,
    this.enabled = true,
  });

  static const allDays = 0x7f;

  /// Minutes after midnight, 0-1439.
  final int start;
  final int end;
  final int days;
  final bool enabled;

  bool get crossesMidnight => end < start;

  /// Valid for the pump: some day set, start != end.
  bool get valid => days & allDays != 0 && start != end;

  bool onDay(int weekday0) => (days >> weekday0) & 1 == 1;

  DayWindow copyWith({int? start, int? end, int? days, bool? enabled}) =>
      DayWindow(
        start: start ?? this.start,
        end: end ?? this.end,
        days: days ?? this.days,
        enabled: enabled ?? this.enabled,
      );

  @override
  bool operator ==(Object other) =>
      other is DayWindow &&
      other.start == start &&
      other.end == end &&
      other.days == days &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(start, end, days, enabled);
}

/// The Buzzer characteristic: master switch, quiet hours, and a switch and a
/// sound for each event (index = TankLinkUuids.buzzEvent*).
class BuzzerConfig {
  const BuzzerConfig({
    required this.enabled,
    required this.quiet,
    required this.quietButton,
    required this.events,
    required this.sounds,
    required this.quietStart,
    required this.quietEnd,
  });

  final bool enabled;

  /// Quiet hours on: only button sounds (if [quietButton]) play in them.
  final bool quiet;
  final bool quietButton;

  /// Bit i = event i sounds.
  final int events;

  /// Sound for each event (TankLinkUuids.buzzSound*).
  final List<int> sounds;

  /// Minutes after midnight.
  final int quietStart;
  final int quietEnd;

  static const len = 3 + TankLinkUuids.buzzEventCount + 4;

  bool on(int event) => (events >> event) & 1 == 1;
  int soundFor(int event) => sounds[event];

  /// flags(1) events(u16) sounds(event count) quiet_start_h/m quiet_end_h/m.
  static BuzzerConfig? parse(List<int> b) {
    if (b.length != len) return null;
    const n = TankLinkUuids.buzzEventCount;
    final q = 3 + n;
    return BuzzerConfig(
      enabled: b[0] & 1 != 0,
      quiet: b[0] & 2 != 0,
      quietButton: b[0] & 4 != 0,
      events: _u16(b, 1),
      sounds: List.unmodifiable(b.sublist(3, 3 + n)),
      quietStart: b[q] * 60 + b[q + 1],
      quietEnd: b[q + 2] * 60 + b[q + 3],
    );
  }

  List<int> encode() => [
    (enabled ? 1 : 0) | (quiet ? 2 : 0) | (quietButton ? 4 : 0),
    events & 0xff,
    (events >> 8) & 0xff,
    ...sounds,
    quietStart ~/ 60,
    quietStart % 60,
    quietEnd ~/ 60,
    quietEnd % 60,
  ];

  BuzzerConfig copyWith({
    bool? enabled,
    bool? quiet,
    bool? quietButton,
    int? events,
    List<int>? sounds,
    int? quietStart,
    int? quietEnd,
  }) => BuzzerConfig(
    enabled: enabled ?? this.enabled,
    quiet: quiet ?? this.quiet,
    quietButton: quietButton ?? this.quietButton,
    events: events ?? this.events,
    sounds: sounds ?? this.sounds,
    quietStart: quietStart ?? this.quietStart,
    quietEnd: quietEnd ?? this.quietEnd,
  );

  BuzzerConfig withEvent(int event, bool on) =>
      copyWith(events: on ? events | (1 << event) : events & ~(1 << event));

  BuzzerConfig withSound(int event, int sound) =>
      copyWith(sounds: [...sounds]..[event] = sound);
}

/// The AutoFill characteristic: how auto-fill behaves pump-wide, and what it
/// is doing for the selected tank right now.
class AutoFillInfo {
  const AutoFillInfo({
    required this.state,
    required this.slot,
    required this.waitMin,
    required this.limitTimes,
    required this.stopAtEnd,
    required this.gapMin,
    required this.windows,
  });

  /// TankLinkUuids.afState*.
  final int state;

  /// The tank [state] is about (the selected one).
  final int slot;

  /// Minutes until it may start ([TankLinkUuids.afStateCooldown],
  /// [TankLinkUuids.afStateWaitTime]); null when unknown or none.
  final int? waitMin;

  /// Only start within [windows].
  final bool limitTimes;

  /// Stop an auto-fill when its allowed time ends.
  final bool stopAtEnd;

  /// Least time between a stop and the next automatic start.
  final int gapMin;
  final List<DayWindow> windows;

  /// state slot wait_min(u16) flags gap count, then count x
  /// enabled days start_h start_m end_h end_m.
  static AutoFillInfo? parse(List<int> b) {
    if (b.length < 7) return null;
    final count = b[6];
    if (b[0] > TankLinkUuids.afStateNotSelected ||
        count > TankLinkUuids.autoFillWindowMax ||
        b.length != 7 + count * 6) {
      return null;
    }
    final wait = _u16(b, 2);
    return AutoFillInfo(
      state: b[0],
      slot: b[1],
      waitMin: wait == 0xffff ? null : wait,
      limitTimes: b[4] & 1 != 0,
      stopAtEnd: b[4] & 2 != 0,
      gapMin: b[5],
      windows: [
        for (var i = 0; i < count; i++)
          DayWindow(
            enabled: b[7 + i * 6] != 0,
            days: b[8 + i * 6],
            start: b[9 + i * 6] * 60 + b[10 + i * 6],
            end: b[11 + i * 6] * 60 + b[12 + i * 6],
          ),
      ],
    );
  }

  /// The settings write: 0x01 flags gap count windows.
  static List<int> encodeConfig({
    required bool limitTimes,
    required bool stopAtEnd,
    required int gapMin,
    required List<DayWindow> windows,
  }) => [
    TankLinkUuids.autoFillOpConfig,
    (limitTimes ? 1 : 0) | (stopAtEnd ? 2 : 0),
    gapMin,
    windows.length,
    for (final w in windows) ...[
      w.enabled ? 1 : 0,
      w.days,
      w.start ~/ 60,
      w.start % 60,
      w.end ~/ 60,
      w.end % 60,
    ],
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
    required this.tankFault,
    required this.clockLostPower,
    required this.pumpBootId,
    required this.staleSec,
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

  /// The selected tank sensor's own light code, 0 when it has none.
  final int tankFault;

  /// The pump's clock chip lost power since the pump started: its coin cell
  /// is likely flat. Stays set after the phone sets the time.
  final bool clockLostPower;

  /// Random, new every time the pump starts: tells the app it restarted.
  final int pumpBootId;

  /// The selected sensor counts as offline after this many seconds without
  /// a packet.
  final int staleSec;

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
      tankFault: b[TankLinkUuids.tankStatusFaultAt],
      clockLostPower:
          b[TankLinkUuids.tankStatusPumpFlagsAt] &
              TankLinkUuids.tankStatusClockLost !=
          0,
      pumpBootId: _u32(b, TankLinkUuids.tankStatusBootIdAt),
      staleSec: _u16(b, TankLinkUuids.tankStatusStaleAt),
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

/// The pump's Tanks characteristic: the tank slots and which one it fills.
class TankList {
  const TankList({required this.activeSlot, required this.slots});

  final int activeSlot;
  final List<TankSlot> slots;

  /// active_slot count, then count × 20-byte entries:
  /// index sensor_pin sensor_index auto_off name(16), then
  /// auto_fill_slot(1), 0xFF = none.
  static TankList? parse(List<int> b) {
    if (b.length < 2) return null;
    const entry = TankLinkUuids.tanksEntryLen;
    final slots = <TankSlot>[];
    var o = 2;
    final entries = <List<int>>[];
    for (var i = 0; i < b[1] && o + entry <= b.length; i++, o += entry) {
      entries.add(b.sublist(o, o + entry));
    }
    if (o >= b.length) return null;
    final autoFillSlot = b[o];
    for (final e in entries) {
      final raw = e.sublist(4);
      final end = raw.indexOf(0);
      slots.add(
        TankSlot(
          index: e[0],
          sensor: e[1],
          node: e[2],
          autoOffMin: e[3],
          name: String.fromCharCodes(end < 0 ? raw : raw.sublist(0, end)),
          autoFill: e[0] == autoFillSlot,
        ),
      );
    }
    return TankList(activeSlot: b[0], slots: slots);
  }
}

/// One paired tank sensor, from the pump's Sensors characteristic.
class TankSensor {
  const TankSensor({
    required this.index,
    required this.idHex,
    required this.mode,
    required this.rawFlags,
    required this.batteryPct,
    required this.online,
    required this.ageSec,
    required this.rssiDbm,
    required this.snrDb,
    required this.firmware,
    required this.hwRev,
    required this.bleToken,
    required this.fault,
    required this.updateSec,
    required this.staleSec,
  });

  /// Index the pump uses for it (stable while it stays paired).
  final int index;
  final String idHex;

  /// Float mode: [TankLinkUuids.sensorModeOff] / `Empty` / `Two`.
  final int mode;

  /// Last pin levels: bit 0 sensor 1, bit 1 sensor 2.
  final int rawFlags;
  final int batteryPct;
  final bool online;

  /// Seconds since the last packet, null if never heard.
  final int? ageSec;
  final int rssiDbm;
  final int snrDb;

  /// Empty while never heard.
  final String firmware;
  final int hwRev;

  /// Null when the pump has no token for it.
  final Uint8List? bleToken;

  /// This sensor's own light code, 0 when it reported none.
  final int fault;

  /// The update interval the sensor last reported, null until it has.
  final int? updateSec;

  /// It counts as offline after this many seconds without a packet.
  final int staleSec;

  /// Last four hex digits, as printed on the board's BLE name.
  String get shortId => serialFromDeviceId(idHex);

  bool get otaReady => bleToken != null;

  /// count max, then count × [TankLinkUuids.sensorEntryLen] entries, then one
  /// fault byte per entry, then interval(u16) stale(u16) per entry.
  static List<TankSensor>? parseList(List<int> b) {
    if (b.length < 2) return null;
    const len = TankLinkUuids.sensorEntryLen;
    final count = b[0];
    final faultsAt = 2 + count * len;
    final beatsAt = faultsAt + count;
    if (b.length < beatsAt + count * 4) return null;
    final out = <TankSensor>[];
    for (var i = 0; i < count; i++) {
      final o = 2 + i * len;
      final fw = '${b[o + 15]}.${b[o + 16]}.${b[o + 17]}';
      final age = _u16(b, o + 11);
      final token = Uint8List.fromList(b.sublist(o + 19, o + 35));
      out.add(
        TankSensor(
          index: b[o],
          idHex: _hex(b.sublist(o + 1, o + 7)),
          mode: b[o + 7].clamp(0, TankLinkUuids.sensorModeTwo),
          rawFlags: b[o + 8],
          batteryPct: b[o + 9].clamp(0, 100),
          online: b[o + 10] != 0,
          ageSec: age == 0xFFFF ? null : age,
          rssiDbm: _i8(b[o + 13]),
          snrDb: _i8(b[o + 14]),
          firmware: fw == '0.0.0' ? '' : fw,
          hwRev: b[o + 18],
          bleToken: token.any((v) => v != 0) ? token : null,
          fault: b[faultsAt + i],
          updateSec: _u16(b, beatsAt + i * 4) == 0
              ? null
              : _u16(b, beatsAt + i * 4),
          staleSec: _u16(b, beatsAt + i * 4 + 2),
        ),
      );
    }
    return out;
  }

  /// Cmd 0xA7: set this sensor's float mode.
  static List<int> encodeMode(String idHex, int mode) => [
    TankLinkUuids.cmdSensorMode,
    ..._unhex(idHex),
    mode,
  ];

  /// Cmd 0xA2 with an id: unpair this sensor.
  static List<int> encodeUnpair(String idHex) => [
    TankLinkUuids.cmdTankUnpair,
    ..._unhex(idHex),
  ];
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

  /// Set-clock write: the phone's local time, then its UTC offset in minutes
  /// (i16), so the pump can turn SNTP time into local time.
  static List<int> encodeClock(DateTime now) => [
    TankLinkUuids.schedOpSetClock,
    now.year & 0xff,
    (now.year >> 8) & 0xff,
    now.month,
    now.day,
    now.hour,
    now.minute,
    now.second,
    now.timeZoneOffset.inMinutes & 0xff,
    (now.timeZoneOffset.inMinutes >> 8) & 0xff,
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

/// History: count, then count × 12-byte fills, newest first.
/// One page of the History characteristic.
class HistoryPage {
  const HistoryPage({
    required this.total,
    required this.start,
    required this.fills,
  });

  /// Fills the pump holds in all.
  final int total;

  /// Index of the first fill on this page (0 = newest).
  final int start;
  final List<FillRecord> fills;

  /// total(1) start(1) count(1), then count × 12-byte fills, newest first.
  static HistoryPage? parse(List<int> b) {
    if (b.length < 3) return null;
    const len = TankLinkUuids.historyEntryLen;
    return HistoryPage(
      total: b[0],
      start: b[1],
      fills: [
        for (var i = 0, o = 3; i < b[2] && o + len <= b.length; i++, o += len)
          FillRecord(
            startedAt: _pumpLocalTime(_u32(b, o)),
            ranSec: _u32(b, o + 4),
            slot: b[o + 8],
            startedBy: b[o + 9],
            stoppedBy: b[o + 10],
          ),
      ],
    );
  }
}

/// Cmd that saves the usage settings on the pump. Flow in tenths of a litre
/// a minute and price in hundredths, both 0 when not set; the currency is cut
/// to whole characters that fit in 4 UTF-8 bytes.
List<int> encodeUsage(UsageSettings s) {
  int u16(double? v, double scale, int max) =>
      v == null || v <= 0 ? 0 : (v * scale).round().clamp(1, max);
  final flow = u16(s.flowLpm, 10, 0xFFFF);
  final watts = u16(s.pumpWatts, 1, 0xFFFF);
  final price = u16(s.pricePerKwh, 100, 0xFFFF);
  final cur = <int>[];
  for (final rune in s.currency.runes) {
    final bytes = utf8.encode(String.fromCharCode(rune));
    if (cur.length + bytes.length > TankLinkUuids.usageCurrencyLen) break;
    cur.addAll(bytes);
  }
  return [
    TankLinkUuids.cmdUsage,
    flow & 0xff,
    flow >> 8,
    watts & 0xff,
    watts >> 8,
    price & 0xff,
    price >> 8,
    ...cur,
    ...List.filled(TankLinkUuids.usageCurrencyLen - cur.length, 0),
  ];
}

/// Battery: count, then per sensor index(1) days(1) and days × 4 bytes.
/// Returns days by sensor index, oldest first.
Map<int, List<BatteryDay>>? parseBatteryLog(List<int> b) {
  if (b.isEmpty) return null;
  const len = TankLinkUuids.batteryDayLen;
  final out = <int, List<BatteryDay>>{};
  var o = 1;
  for (var i = 0; i < b[0] && o + 2 <= b.length; i++) {
    final index = b[o];
    final days = b[o + 1];
    o += 2;
    if (o + days * len > b.length) return null;
    out[index] = [
      for (var d = 0; d < days; d++, o += len)
        BatteryDay(day: _u16(b, o), minPct: b[o + 2], maxPct: b[o + 3]),
    ];
  }
  return out;
}

/// What the pump's Wi-Fi is doing (Wifi characteristic state byte).
enum WifiState { off, connecting, connected, wrongPassword, notFound }

/// What the pump's own update check is doing (after the SSID, minor 5).
enum PumpUpdateState { none, available, checking, installing }

/// How the pump's last update check went.
enum PumpCheckResult { never, ok, noInternet, error }

/// Wifi read: state rssi ip(4) ssid_len ssid, then (minor 5) update_state
/// check_result available_version(3) overnight_version(3).
class WifiStatus {
  const WifiStatus({
    required this.state,
    required this.rssi,
    required this.ip,
    required this.ssid,
    required this.update,
    required this.check,
    required this.availableVersion,
    required this.overnightVersion,
    required this.lastCheckAgeMin,
    required this.availableSize,
  });

  final WifiState state;

  /// dBm while connected, null otherwise.
  final int? rssi;

  /// Dotted address, null when the pump has none.
  final String? ip;
  final String ssid;

  /// What the pump's own update check is doing, how it went, and the update it
  /// found (null = none).
  final PumpUpdateState update;
  final PumpCheckResult check;
  final String? availableVersion;

  /// Bytes of the update it found, 0 when none: for a progress bar.
  final int availableSize;

  /// Minutes since the last check that got an answer, null = never.
  final int? lastCheckAgeMin;

  /// Version the pump installed by itself, until the app dismisses the notice.
  final String? overnightVersion;

  /// Fixed part (7 bytes plus the name), then the update block: update_state
  /// check_result available_version(3) overnight_version(3) last_check_age_min(u16)
  /// available_size(u32).
  static const _updateBlockLen = 14;

  static WifiStatus? parse(List<int> b) {
    if (b.length < 7 || b.length < 7 + b[6] + _updateBlockLen) {
      return null;
    }
    final u = 7 + b[6];
    String? version(int at) => b[at] == 0 && b[at + 1] == 0 && b[at + 2] == 0
        ? null
        : '${b[at]}.${b[at + 1]}.${b[at + 2]}';
    final age = b[u + 8] | (b[u + 9] << 8);
    final hasIp = b[2] != 0 || b[3] != 0 || b[4] != 0 || b[5] != 0;
    return WifiStatus(
      state: WifiState.values[b[0]],
      rssi: b[1] == 0 ? null : (b[1] > 127 ? b[1] - 256 : b[1]),
      ip: hasIp ? '${b[2]}.${b[3]}.${b[4]}.${b[5]}' : null,
      ssid: utf8.decode(b.sublist(7, 7 + b[6]), allowMalformed: true),
      update: PumpUpdateState.values[b[u]],
      check: PumpCheckResult.values[b[u + 1]],
      availableVersion: version(u + 2),
      overnightVersion: version(u + 5),
      lastCheckAgeMin: age == 0xFFFF ? null : age,
      availableSize:
          b[u + 10] | (b[u + 11] << 8) | (b[u + 12] << 16) | (b[u + 13] << 24),
    );
  }
}

/// One network from a Wifi scan page.
class WifiNetwork {
  const WifiNetwork({
    required this.ssid,
    required this.rssi,
    required this.secured,
    required this.supported,
  });

  final String ssid;
  final int rssi;
  final bool secured;

  /// False for WPA-Enterprise, which the pump can't join.
  final bool supported;
}

/// Wifi scan page: scanning total count, then ssid_len ssid rssi auth.
class WifiScanPage {
  const WifiScanPage({
    required this.scanning,
    required this.total,
    required this.networks,
  });

  final bool scanning;
  final int total;
  final List<WifiNetwork> networks;

  static WifiScanPage? parse(List<int> b) {
    if (b.length < 3) {
      return null;
    }
    final nets = <WifiNetwork>[];
    var o = 3;
    for (var i = 0; i < b[2]; i++) {
      if (o >= b.length || o + 1 + b[o] + 2 > b.length) {
        return null;
      }
      final n = b[o];
      final rssi = b[o + 1 + n];
      nets.add(
        WifiNetwork(
          ssid: utf8.decode(b.sublist(o + 1, o + 1 + n), allowMalformed: true),
          rssi: rssi > 127 ? rssi - 256 : rssi,
          secured: b[o + 2 + n] != 0,
          supported: b[o + 2 + n] != 2,
        ),
      );
      o += n + 3;
    }
    return WifiScanPage(scanning: b[0] != 0, total: b[1], networks: nets);
  }
}

/// Wifi write encoders.
class WifiCommands {
  /// 64 bytes of keystream for the password: HMAC-SHA256(token, nonce ||
  /// "wifi" || 0) followed by the same with 1. [nonce] is the Auth nonce this
  /// connection signed in with. Same as pump_node/main/gatt_svr.c.
  static Uint8List keystream(List<int> token, List<int> nonce) {
    final out = <int>[];
    for (var block = 0; block < 2; block++) {
      out.addAll(
        Hmac(
          sha256,
          token,
        ).convert([...nonce, ...'wifi'.codeUnits, block]).bytes,
      );
    }
    return Uint8List.fromList(out);
  }

  /// SET: the password is XOR'd with the keystream, so it never crosses BLE
  /// in the clear. Up to 32 UTF-8 bytes of name and 63 of password.
  static List<int> set(
    String ssid,
    String password,
    List<int> token,
    List<int> nonce,
  ) {
    final name = utf8.encode(ssid);
    final pass = utf8.encode(password);
    if (name.isEmpty || name.length > 32 || pass.length > 63) {
      throw ArgumentError('network name or password too long');
    }
    final ks = keystream(token, nonce);
    return [
      TankLinkUuids.wifiOpSet,
      name.length,
      ...name,
      pass.length,
      for (var i = 0; i < pass.length; i++) pass[i] ^ ks[i],
    ];
  }

  static List<int> forget() => [TankLinkUuids.wifiOpForget];
  static List<int> scan() => [TankLinkUuids.wifiOpScan];
  static List<int> scanPage(int page) => [TankLinkUuids.wifiOpScanPage, page];
  static List<int> status() => [TankLinkUuids.wifiOpStatus];
}
