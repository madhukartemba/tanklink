import 'package:flutter_test/flutter_test.dart';
import 'package:tanklink/ble/fill_archive.dart';
import 'package:tanklink/ble/models.dart';
import 'package:tanklink/util/water_use.dart';

FillRecord fill(DateTime at, int ranSec, {int slot = 0}) => FillRecord(
  startedAt: at,
  ranSec: ranSec,
  slot: slot,
  startedBy: 1,
  stoppedBy: 4,
);

void main() {
  final now = DateTime(2026, 11, 20, 18, 0);

  test('buildUsage groups fills by start day, oldest first', () {
    final r = buildUsage(
      [
        fill(DateTime(2026, 11, 20, 7), 600),
        fill(DateTime(2026, 11, 20, 19), 300, slot: 1),
        fill(DateTime(2026, 11, 18, 7), 900),
        fill(DateTime(2026, 10, 1, 7), 900), // outside 7 days
        FillRecord(
          startedAt: null,
          ranSec: 99,
          slot: 0,
          startedBy: 0,
          stoppedBy: 0,
        ),
      ],
      now: now,
      days: 7,
    );
    expect(r.days.length, 7);
    expect(r.days.last.day, DateTime(2026, 11, 20));
    expect(r.days.first.day, DateTime(2026, 11, 14));
    expect(r.days.last.runSec, 900);
    expect(r.days.last.fills, 2);
    expect(r.days[4].runSec, 900); // 18 Nov
    expect(r.totalRunSec, 1800);
    expect(r.runSecBySlot, {0: 1500, 1: 300});
    expect(r.startsByHour[7], 2);
    expect(r.startsByHour[19], 1);
    // Averages count from the first fill seen (18 Nov), not the whole week.
    expect(r.daysCovered, 3);
    expect(r.avgRunSecPerDay, 600);
    expect(r.runSecLast(1), 900);
  });

  test('buildUsage keeps calendar days across a DST change', () {
    final r = buildUsage([], now: DateTime(2026, 3, 30, 12), days: 5);
    expect(r.days.map((d) => d.day.day), [26, 27, 28, 29, 30]);
    expect(r.isEmpty, isTrue);
    expect(r.avgRunSecPerDay, 0);
  });

  test('UsageSettings turns run time into litres, energy and cost', () {
    const s = UsageSettings(flowLpm: 40, pumpWatts: 750, pricePerKwh: 8);
    expect(s.litres(1800), 1200); // 30 min at 40 L/min
    expect(s.kwh(3600), closeTo(0.75, 1e-9));
    expect(s.cost(3600), closeTo(6, 1e-9));
    expect(UseMetric.time.of(90, s), 1.5);
    const none = UsageSettings();
    expect(none.hasFlow, isFalse);
    expect(none.litres(1800), 0);
    expect(UseMetric.water.available(none), isFalse);
    expect(UseMetric.energy.available(none), isTrue);
  });

  test('UsageSettings round-trips and drops bad numbers', () {
    const s = UsageSettings(
      flowLpm: 35.5,
      pumpWatts: 1100,
      pricePerKwh: 7.2,
      currency: '₹',
    );
    final back = UsageSettings.fromJson(s.toJson());
    expect(back.flowLpm, 35.5);
    expect(back.pumpWatts, 1100);
    expect(back.pricePerKwh, 7.2);
    expect(back.currency, '₹');
    final bad = UsageSettings.fromJson({'flow_lpm': -3, 'watts': 'x'});
    expect(bad.flowLpm, isNull);
    expect(bad.pumpWatts, UsageSettings.defaultWatts);
  });

  test('formatting', () {
    expect(formatLitres(12400.4), '12,400 L');
    expect(formatLitres(850), '850 L');
    expect(formatMinutes(45), '45 min');
    expect(formatMinutes(190), '3 h 10 min');
    expect(formatMoney(6, '₹'), '₹6.00');
    expect(formatMoney(240.4, ''), '240');
    expect(formatKwh(0.75), '0.8 kWh');
  });

  test('FillArchive.mergeLists dedupes, sorts newest first, drops untimed', () {
    final a = fill(DateTime(2026, 11, 1, 7), 600);
    final b = fill(DateTime(2026, 11, 2, 7), 600);
    final c = fill(DateTime(2026, 11, 3, 7), 600);
    final untimed = FillRecord(
      startedAt: null,
      ranSec: 5,
      slot: 0,
      startedBy: 0,
      stoppedBy: 0,
    );
    final merged = FillArchive.mergeLists([b, a], [c, b, untimed]);
    expect(merged.map((f) => f.startedAt!.day), [3, 2, 1]);
  });
}
