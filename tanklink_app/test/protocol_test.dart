// Byte-layout tests for lib/ble/protocol.dart. Each payload is built here
// the way the firmware builds it (see docs/PROTOCOL.md), so a change on
// either side that breaks the contract fails here.

import 'package:flutter_test/flutter_test.dart';
import 'package:tanklink/ble/models.dart';
import 'package:tanklink/ble/protocol.dart';
import 'package:tanklink/ble/tanklink_uuids.dart';

List<int> u32(int v) => [
  v & 0xff,
  (v >> 8) & 0xff,
  (v >> 16) & 0xff,
  (v >> 24) & 0xff,
];

void main() {
  group('PumpInfo', () {
    final bytes = [
      1, 0, 2, // proto 1.0, board rev 2
      1, 0x02, // paired, authed
      0xa4, 0xcf, 0x12, 0x34, 0xe5, 0xfe, // device id
      0, 12, 0, // fw 0.12.0
      ...u32(75),
    ];

    test('parses the frozen layout', () {
      final info = PumpInfo.parse(bytes);
      expect(info.protoMajor, 1);
      expect(info.protoMinor, 0);
      expect(info.hwRev, 2);
      expect(info.paired, isTrue);
      expect(info.deviceIdHex, 'a4cf1234e5fe');
      expect(info.serial, 'E5FE');
      expect(info.firmware, '0.12.0');
      expect(info.runSeconds, 75);
    });

    test('ignores fields added by a newer minor', () {
      expect(PumpInfo.parse([...bytes, 9, 9, 9]).firmware, '0.12.0');
    });

    test('rejects a short (pre-versioning) Info', () {
      expect(() => PumpInfo.parse(bytes.sublist(0, 12)), throwsFormatException);
    });

    test('flags bit 0 is the phone pairing window', () {
      expect(PumpInfo.parse(bytes).pairingOpen, isFalse);
      final open = [...bytes]..[4] = 0x03;
      expect(PumpInfo.parse(open).pairingOpen, isTrue);
    });
  });

  group('pumpAdvState', () {
    // flutter_blue_plus: company ID -> the bytes after it.
    test('claimable bit means ready to add', () {
      expect(
        pumpAdvState({
          0xFFFF: [0x01],
        }),
        PumpAdvState.ready,
      );
      expect(
        pumpAdvState({
          0xFFFF: [0x03],
        }),
        PumpAdvState.ready,
      );
    });

    test('paired with the window closed is not ready', () {
      expect(
        pumpAdvState({
          0xFFFF: [0x02],
        }),
        PumpAdvState.notReady,
      );
      expect(
        pumpAdvState({
          0xFFFF: [0x00],
        }),
        PumpAdvState.notReady,
      );
    });

    test('older firmware without the byte is unknown', () {
      expect(pumpAdvState({}), PumpAdvState.unknown);
      expect(pumpAdvState({0xFFFF: []}), PumpAdvState.unknown);
      expect(
        pumpAdvState({
          0x004C: [0x01],
        }),
        PumpAdvState.unknown,
      );
    });
  });

  group('PumpSettings', () {
    test('parses a read and encodes a write', () {
      final read = [
        ...u32(30), // run seconds
        ...'E5FE'.codeUnits, 0, // serial
        0x0f,
        2,
        70,
        1,
        ...[0xe8, 0x03], // flags tone led starter 1000ms
      ];
      final s = PumpSettings.parse(read)!;
      expect(s.runSeconds, 30);
      expect(s.buzzerFlags, 0x0f);
      expect(s.buzzerTone, 2);
      expect(s.ledBrightness, 70);
      expect(s.starterType, 1);
      expect(s.relayPulseMs, 1000);
      expect(s.encode(), [0x0f, 2, 70, 1, 0xe8, 0x03]);
    });

    test('returns null when too short', () {
      expect(PumpSettings.parse(List.filled(10, 0)), isNull);
    });
  });

  group('TankStatus', () {
    List<int> status({int reason = 0}) {
      final b = List<int>.filled(TankLinkUuids.tankStatusLen, 0);
      b[0] = 1; // bound
      b.setRange(2, 8, [1, 2, 3, 4, 5, 6]);
      b.setRange(8, 11, [0, 3, 0]);
      b[11] = 0x01; // sensor 1 high
      b[12] = 82;
      b[13] = 1; // online
      b.setRange(14, 16, [120, 0]);
      b[16] = 0xA4; // -92 dBm
      b[17] = 7;
      b[18] = TankLinkUuids.pumpErrTankOffline;
      b.setRange(19, 35, List.filled(16, 0xAB));
      b[35] = reason;
      b.setRange(48, 52, u32(600));
      b[TankLinkUuids.tankStatusHwRevAt] = 1;
      b[TankLinkUuids.tankStatusFaultAt] = TankLinkUuids.tankErrBattery;
      return b;
    }

    test('parses every field', () {
      final t = TankStatus.parse(status())!;
      expect(t.bound, isTrue);
      expect(t.tankIdHex, '010203040506');
      expect(t.firmware, '0.3.0');
      expect(t.batteryPct, 82);
      expect(t.online, isTrue);
      expect(t.ageSec, 120);
      expect(t.rssiDbm, -92);
      expect(t.snrDb, 7);
      expect(t.pumpLastError, TankLinkUuids.pumpErrTankOffline);
      expect(t.bleToken, hasLength(16));
      expect(t.interruption, isNull);
      expect(t.hwRev, 1);
      expect(t.tankFault, TankLinkUuids.tankErrBattery);
    });

    test('reads an interrupted fill', () {
      final t = TankStatus.parse(
        status(reason: TankLinkUuids.interruptPowerLost),
      )!;
      expect(t.interruption!.reason, TankLinkUuids.interruptPowerLost);
      expect(t.interruption!.ranSec, 600);
      expect(t.interruption!.startedAt, isNull); // 0 = unknown
    });

    test('never heard: no age, no firmware', () {
      final b = status();
      b.setRange(8, 11, [0, 0, 0]);
      b.setRange(14, 16, [0xff, 0xff]);
      final t = TankStatus.parse(b)!;
      expect(t.ageSec, isNull);
      expect(t.firmware, '');
    });
  });

  test('TankList parses slots with their sensor and auto-off', () {
    List<int> entry(int index, int pin, int node, int autoOff, String name) => [
      index,
      pin,
      node,
      autoOff,
      ...name.codeUnits,
      ...List.filled(16 - name.length, 0),
    ];
    final list = TankList.parse([
      2, 3, // slot 2 active, 3 slots
      ...entry(0, 0, 0, 30, 'Roof'),
      ...entry(1, 1, 0, 0, 'Sump'),
      ...entry(2, 0, 3, 45, 'Garden'),
    ])!;
    expect(list.activeSlot, 2);
    expect(list.slots.map((s) => s.name), ['Roof', 'Sump', 'Garden']);
    expect(list.slots.map((s) => s.sensor), [0, 1, 0]);
    expect(list.slots.map((s) => s.node), [0, 0, 3]);
    expect(list.slots.map((s) => s.autoOffMin), [30, 0, 45]);
  });

  test('TankList reads the auto-fill mask after the entries (minor 3)', () {
    List<int> entry(int index, String name) => [
      index,
      0,
      0,
      30,
      ...name.codeUnits,
      ...List.filled(16 - name.length, 0),
    ];
    final withMask = TankList.parse([
      0, 2, //
      ...entry(0, 'Roof'),
      ...entry(3, 'Sump'),
      0x08, // slot 3 fills when low
    ])!;
    expect(withMask.slots.map((s) => s.autoFill), [false, true]);
    // An older pump sends no mask byte: auto-fill reads as off.
    final noMask = TankList.parse([0, 1, ...entry(0, 'Roof')])!;
    expect(noMask.slots.single.autoFill, isFalse);
  });

  test('TankList: a pump with no sensor has one sensorless slot', () {
    final list = TankList.parse([
      0, 1, //
      0, 0, TankLinkUuids.sensorNone, 30, ...'Tank'.codeUnits,
      ...List.filled(12, 0),
    ])!;
    expect(list.slots.single.node, TankLinkUuids.sensorNone);
  });

  group('TankSensor', () {
    final token = List.generate(16, (i) => i + 1);
    List<int> entry({
      required int index,
      required List<int> id,
      int age = 42,
    }) => [
      index,
      ...id,
      TankLinkUuids.sensorModeTwo,
      0x02, // raw flags: sensor 2 pin high
      87, // battery
      1, // online
      age & 0xff, age >> 8,
      0xb5, // -75 dBm
      0xfb, // -5 dB
      1, 2, 3, // fw
      1, // hw rev
      ...token,
    ];
    const idA = [0xa4, 0xcf, 0x12, 0x34, 0xe5, 0x01];
    const idB = [0xa4, 0xcf, 0x12, 0x34, 0xe5, 0x02];

    test('parses every sensor', () {
      final list = TankSensor.parseList([
        2,
        TankLinkUuids.sensorMax,
        ...entry(index: 0, id: idA),
        ...entry(index: 3, id: idB, age: 0xffff),
        0, TankLinkUuids.tankErrBattery, // fault per entry
      ])!;
      expect(list, hasLength(2));
      final a = list.first;
      expect(a.index, 0);
      expect(a.idHex, 'a4cf1234e501');
      expect(a.shortId, 'E501');
      expect(a.mode, TankLinkUuids.sensorModeTwo);
      expect(a.rawFlags, 0x02);
      expect(a.batteryPct, 87);
      expect(a.online, isTrue);
      expect(a.ageSec, 42);
      expect(a.rssiDbm, -75);
      expect(a.snrDb, -5);
      expect(a.firmware, '1.2.3');
      expect(a.hwRev, 1);
      expect(a.bleToken, token);
      expect(list.last.index, 3);
      expect(list.last.ageSec, isNull);
      expect(a.fault, 0);
      expect(list.last.fault, TankLinkUuids.tankErrBattery);
    });

    test('returns null without the fault bytes', () {
      expect(
        TankSensor.parseList([
          1,
          TankLinkUuids.sensorMax,
          ...entry(index: 0, id: idA),
        ]),
        isNull,
      );
    });

    test('entry length matches the constant', () {
      expect(entry(index: 0, id: idA), hasLength(TankLinkUuids.sensorEntryLen));
    });

    test('encodes mode and unpair commands with the sensor id', () {
      expect(TankSensor.encodeMode('a4:cf:12:34:e5:01', 1), [
        TankLinkUuids.cmdSensorMode,
        ...idA,
        1,
      ]);
      expect(TankSensor.encodeUnpair('a4cf1234e501'), [
        TankLinkUuids.cmdTankUnpair,
        ...idA,
      ]);
    });
  });

  group('ScheduleState', () {
    test('parses times and clock flags', () {
      final st = ScheduleState.parse([1, 6, 30, 1, 1, 6, 0, 0, 0x03])!;
      expect(st.clockValid, isTrue);
      expect(st.clockHour, 6);
      expect(st.schedules.single.minute, 0);
      expect(st.rtcOk, isTrue);
    });

    test('encodes the clock and the list', () {
      expect(ScheduleState.encodeClock(DateTime(2026, 11, 17, 14, 5, 9)), [
        TankLinkUuids.schedOpSetClock,
        0xEA,
        0x07,
        11,
        17,
        14,
        5,
        9,
      ]);
      expect(
        ScheduleState.encodeList([
          FillSchedule(enabled: true, hour: 6, minute: 15, slot: 1),
        ]),
        [TankLinkUuids.schedOpSetList, 1, 1, 6, 15, 1],
      );
    });
  });

  test('parseFillHistory reads fills newest first', () {
    // 2026-11-18 06:00:00 pump-local, as seconds since 1970.
    final started =
        DateTime.utc(2026, 11, 18, 6).millisecondsSinceEpoch ~/ 1000;
    final list = parseFillHistory([
      2,
      ...u32(started),
      ...u32(1080),
      1,
      TankLinkUuids.causeSchedule,
      TankLinkUuids.causeTankFull,
      0,
      ...u32(0),
      ...u32(300),
      0,
      TankLinkUuids.causeUnknown,
      TankLinkUuids.causePower,
      0,
    ])!;
    expect(list, hasLength(2));
    expect(list.first.startedAt, DateTime(2026, 11, 18, 6));
    expect(list.first.ranSec, 1080);
    expect(list.first.slot, 1);
    expect(list.first.startedBy, TankLinkUuids.causeSchedule);
    expect(list.first.stoppedBy, TankLinkUuids.causeTankFull);
    expect(list.last.startedAt, isNull);
    expect(list.last.stoppedBy, TankLinkUuids.causePower);
  });

  test('parseBatteryLog reads days per sensor', () {
    final logs = parseBatteryLog([
      2,
      0, 2, 0x10, 0x52, 70, 95, 0x11, 0x52, 68, 94, // sensor 0, 2 days
      3, 0, // sensor 3, nothing logged yet
    ])!;
    expect(logs.keys, [0, 3]);
    expect(logs[0]!.map((d) => d.day), [0x5210, 0x5211]);
    expect(logs[0]!.map((d) => d.minPct), [70, 68]);
    expect(logs[0]!.last.maxPct, 94);
    expect(logs[3], isEmpty);
    expect(parseBatteryLog([1, 0, 2, 0x10]), isNull, reason: 'truncated');
  });

  test('encodeTankName keeps printable ASCII only', () {
    expect(encodeTankName('  Roof tank ✓ '), 'Roof tank'.codeUnits);
  });
}
