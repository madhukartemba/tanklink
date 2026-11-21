// Byte-layout tests for lib/ble/protocol.dart. Each payload is built here
// the way the firmware builds it (see docs/PROTOCOL.md), so a change on
// either side that breaks the contract fails here.

import 'package:flutter_test/flutter_test.dart';
import 'package:tanklink/ble/models.dart';
import 'package:tanklink/ble/protocol.dart';
import 'package:tanklink/update/github_release_util.dart';
import 'package:tanklink/ble/tanklink_uuids.dart';
import 'package:tanklink/util/water_use.dart';

List<int> u32(int v) => [
  v & 0xff,
  (v >> 8) & 0xff,
  (v >> 16) & 0xff,
  (v >> 24) & 0xff,
];

void main() {
  alertTests();
  releaseNotesTests();
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
        ...[0x7c, 0x01], // flow 38.0 L/min
        ...[0xee, 0x02], // 750 W
        ...[0x20, 0x03], // 8.00 per kWh
        0xE2, 0x82, 0xB9, 0, // ₹
        1, // install updates by itself at night (minor 5)
        ...'Kitchen'.codeUnits,
        ...List.filled(17, 0), // the pump's name (minor 8)
      ];
      final s = PumpSettings.parse(read)!;
      expect(s.autoUpdate, isTrue);
      expect(s.name, 'Kitchen');
      expect(s.usage.flowLpm, 38);
      expect(s.usage.pumpWatts, 750);
      expect(s.usage.pricePerKwh, 8);
      expect(s.usage.currency, '₹');
      expect(s.runSeconds, 30);
      expect(s.buzzerFlags, 0x0f);
      expect(s.buzzerTone, 2);
      expect(s.ledBrightness, 70);
      expect(s.starterType, 1);
      expect(s.relayPulseMs, 1000);
      expect(s.encode(), [0x0f, 2, 70, 1, 0xe8, 0x03, 1]);
    });

    test('returns null when too short', () {
      expect(PumpSettings.parse(List.filled(10, 0)), isNull);
      expect(PumpSettings.parse(List.filled(49, 0)), isNull);
    });

    test('unset flow and price read as null', () {
      final s = PumpSettings.parse([
        ...List.filled(15, 0),
        0, 0, 0xee, 0x02, 0, 0, // flow unset, 750 W, price unset
        0, 0, 0, 0,
        0, // auto_update
        ...List.filled(24, 0), // no name yet
      ])!;
      expect(s.usage.flowLpm, isNull);
      expect(s.usage.pricePerKwh, isNull);
      expect(s.usage.pumpWatts, 750);
      expect(s.usage.currency, '');
      expect(s.name, isEmpty);
    });
  });

  test(
    'encodeUsage packs flow, power, price and a whole-character currency',
    () {
      expect(
        encodeUsage(
          const UsageSettings(
            flowLpm: 38.04,
            pumpWatts: 750,
            pricePerKwh: 8,
            currency: '₹',
          ),
        ),
        [
          TankLinkUuids.cmdUsage,
          0x7c,
          0x01,
          0xee,
          0x02,
          0x20,
          0x03,
          0xE2,
          0x82,
          0xB9,
          0,
        ],
      );
      // Unset values are 0; "Rs. " fits 4 bytes, "₹₹" (6 bytes) keeps one ₹.
      expect(encodeUsage(const UsageSettings(currency: 'Rs. ')).sublist(1), [
        0,
        0,
        0xee,
        0x02,
        0,
        0,
        0x52,
        0x73,
        0x2e,
        0x20,
      ]);
      expect(encodeUsage(const UsageSettings(currency: '₹₹')).sublist(7), [
        0xE2,
        0x82,
        0xB9,
        0,
      ]);
    },
  );

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
      expect(t.clockLostPower, isFalse);
    });

    test('reads the clock-lost-power flag (byte 54) and needs it', () {
      final b = status();
      b[TankLinkUuids.tankStatusPumpFlagsAt] =
          TankLinkUuids.tankStatusClockLost;
      expect(TankStatus.parse(b)!.clockLostPower, isTrue);
      expect(TankStatus.parse(b.sublist(0, 58)), isNull);
    });

    test('reads the pump boot id (bytes 55-58)', () {
      final b = status();
      b.setRange(
        TankLinkUuids.tankStatusBootIdAt,
        TankLinkUuids.tankStatusBootIdAt + 4,
        u32(0xA1B2C3D4),
      );
      expect(TankStatus.parse(b)!.pumpBootId, 0xA1B2C3D4);
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
      0, // auto-fill mask
    ])!;
    expect(list.activeSlot, 2);
    expect(list.slots.map((s) => s.name), ['Roof', 'Sump', 'Garden']);
    expect(list.slots.map((s) => s.sensor), [0, 1, 0]);
    expect(list.slots.map((s) => s.node), [0, 0, 3]);
    expect(list.slots.map((s) => s.autoOffMin), [30, 0, 45]);
  });

  test('TankList reads the auto-fill mask after the entries', () {
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
    // The mask byte is part of the layout: without it the payload is bad.
    expect(TankList.parse([0, 1, ...entry(0, 'Roof')]), isNull);
  });

  test('TankList: a pump with no sensor has one sensorless slot', () {
    final list = TankList.parse([
      0, 1, //
      0, 0, TankLinkUuids.sensorNone, 30, ...'Tank'.codeUnits,
      ...List.filled(12, 0),
      0, // auto-fill mask
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
      final off = DateTime(2026, 11, 17, 14, 5, 9).timeZoneOffset.inMinutes;
      final utcOffset = [off & 0xff, (off >> 8) & 0xff];
      expect(ScheduleState.encodeClock(DateTime(2026, 11, 17, 14, 5, 9)), [
        TankLinkUuids.schedOpSetClock,
        0xEA,
        0x07,
        11,
        17,
        14,
        5,
        9,
        ...utcOffset,
      ]);
      expect(
        ScheduleState.encodeList([
          FillSchedule(enabled: true, hour: 6, minute: 15, slot: 1),
        ]),
        [TankLinkUuids.schedOpSetList, 1, 1, 6, 15, 1],
      );
    });
  });

  test('HistoryPage reads a page of fills newest first', () {
    // 2026-11-18 06:00:00 pump-local, as seconds since 1970.
    final started =
        DateTime.utc(2026, 11, 18, 6).millisecondsSinceEpoch ~/ 1000;
    final page = HistoryPage.parse([
      150, 40, 2, // 150 fills in all, this page starts at fill 40
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
    expect(page.total, 150);
    expect(page.start, 40);
    final list = page.fills;
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

  group('Wifi', () {
    test('keystream and password match the firmware', () {
      // Same vector as the Wifi SET handler in pump_node/main/gatt_svr.c.
      final token = List<int>.generate(16, (i) => i);
      final nonce = List<int>.generate(16, (i) => 16 + i);
      final ks = WifiCommands.keystream(token, nonce);
      expect(ks.length, 64);
      expect(
        ks
            .sublist(0, 32)
            .map((v) => v.toRadixString(16).padLeft(2, '0'))
            .join(),
        '8292bd2d2b6038ee2f1392f2e50e422c8462d640c2acb467915ac222264ebb66',
      );
      final w = WifiCommands.set('Home', 'hunter2pass', token, nonce);
      expect(w.sublist(0, 6), [TankLinkUuids.wifiOpSet, 4, 72, 111, 109, 101]);
      expect(w[6], 11);
      expect(
        w.sublist(7).map((v) => v.toRadixString(16).padLeft(2, '0')).join(),
        'eae7d3594e120a9e4e60e1',
      );
    });

    test('parses status and a scan page', () {
      // state rssi ip(4) ssid_len ssid, then update_state check_result
      // available(3) overnight(3) last_check_age_min(u16) available_size(u32).
      List<int> status({
        int state = 2,
        List<int> update = const [
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0xFF,
          0xFF,
          0,
          0,
          0,
          0,
        ],
      }) => [state, 0xC4, 192, 168, 1, 50, 4, 72, 111, 109, 101, ...update];

      final st = WifiStatus.parse(status())!;
      expect(st.state, WifiState.connected);
      expect(st.rssi, -60);
      expect(st.ip, '192.168.1.50');
      expect(st.ssid, 'Home');
      expect(st.update, PumpUpdateState.none);
      expect(st.availableVersion, isNull);
      expect(st.lastCheckAgeMin, isNull); // 0xFFFF = never
      expect(st.availableSize, 0);
      expect(
        WifiStatus.parse([0, 0, 0, 0, 0, 0, 0, ...List.filled(14, 0)])!.ip,
        isNull,
      );
      // Without the update block it isn't a status this app understands.
      expect(
        WifiStatus.parse([2, 0xC4, 192, 168, 1, 50, 4, 72, 111, 109, 101]),
        isNull,
      );
      expect(WifiStatus.parse([1, 0]), isNull);

      final up = WifiStatus.parse(
        status(
          update: [
            1, 1, // available, last check ok
            0, 21, 0, // available 0.21.0
            0, 20, 1, // installed by itself: 0.20.1
            0x2c, 0x01, // last checked 300 min ago
            0x00, 0x00, 0x17, 0x00, // 1,507,328 bytes
          ],
        ),
      )!;
      expect(up.update, PumpUpdateState.available);
      expect(up.check, PumpCheckResult.ok);
      expect(up.availableVersion, '0.21.0');
      expect(up.overnightVersion, '0.20.1');
      expect(up.lastCheckAgeMin, 300);
      expect(up.availableSize, 1507328);

      final page = WifiScanPage.parse([
        0,
        2,
        2,
        4,
        72,
        111,
        109,
        101,
        0xC4,
        1,
        3,
        67,
        111,
        114,
        0xB0,
        2,
      ])!;
      expect(page.scanning, isFalse);
      expect(page.total, 2);
      expect(page.networks.first.ssid, 'Home');
      expect(page.networks.first.rssi, -60);
      expect(page.networks.last.supported, isFalse);
    });
  });
}

void alertTests() {
  group('Alerts', () {
    test('the tag matches the firmware', () {
      // Same vectors as make_tag in pump_node/main/pump_alert.c, from
      // HMAC-SHA256(key 00..0f, device 84c7bbfbe5fe || seq type arg).
      final key = List<int>.generate(16, (i) => i);
      final id = [0x84, 0xc7, 0xbb, 0xfb, 0xe5, 0xfe];
      String hexOf(List<int> b) =>
          b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
      expect(hexOf(alertTag(key, id, 7, 1, 0)), '3e12569f');
      expect(hexOf(alertTag(key, id, 255, 5, 3)), '9768362b');
    });

    test(
      'an alert in the advertisement is read, without the bit it is not',
      () {
        final a = pumpAdvAlert({
          0xFFFF: [0x06, 9, 2, 1, 1, 2, 3, 4],
        })!;
        expect([a.seq, a.type, a.arg], [9, 2, 1]);
        expect(
          pumpAdvAlert({
            0xFFFF: [0x02, 0, 0, 0, 0, 0, 0, 0],
          }),
          isNull,
        );
        expect(
          pumpAdvAlert({
            0xFFFF: [0x01],
          }),
          isNull,
        );
      },
    );

    test('the alert log is read newest first', () {
      final log = parseAlertLog([2, 12, 1, 0, 5, 0, 11, 5, 2, 0x2c, 0x01]);
      expect(log.length, 2);
      expect(
        [log[0].seq, log[0].type, log[0].arg, log[0].ageMin],
        [12, 1, 0, 5],
      );
      expect(
        [log[1].seq, log[1].type, log[1].arg, log[1].ageMin],
        [11, 5, 2, 300],
      );
      expect(parseAlertLog([]), isEmpty);
    });
  });
}

void releaseNotesTests() {
  test('the "What\'s new" list is the Changes bullets only', () {
    expect(
      releaseChanges(
        '## Changes\n\n- First thing.\n- Second thing.\n\n'
        'Goes with app 1.12.0. Update both.\n\n## Other\n- not this\n',
      ),
      ['First thing.', 'Second thing.'],
    );
    expect(releaseChanges('no headings here'), isEmpty);
    expect(releaseChanges('## Notes\n- x'), isEmpty);
  });
}
