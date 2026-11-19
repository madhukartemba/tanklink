import 'package:flutter_test/flutter_test.dart';
import 'package:tanklink/ble/battery_trend.dart';
import 'package:tanklink/ble/models.dart';

List<BatteryDay> lows(List<int> pct, {int from = 20000}) => [
  for (var i = 0; i < pct.length; i++)
    BatteryDay(day: from + i, minPct: pct[i], maxPct: 100),
];

void main() {
  test('too few days: unknown', () {
    expect(BatteryOutlook.from(lows([80, 79])).trend, BatteryTrend.unknown);
    expect(BatteryOutlook.from(const []).trend, BatteryTrend.unknown);
  });

  test('flat lows: solar keeping up', () {
    expect(
      BatteryOutlook.from(lows([80, 81, 80, 79, 80])).trend,
      BatteryTrend.steady,
    );
  });

  test('rising lows: charging', () {
    expect(
      BatteryOutlook.from(lows([60, 64, 68, 72])).trend,
      BatteryTrend.charging,
    );
  });

  test('falling lows: days left to empty', () {
    // 2 % a day from 45 %: (45 - 5) / 2 = 20 days.
    final o = BatteryOutlook.from(lows([51, 49, 47, 45]));
    expect(o.trend, BatteryTrend.draining);
    expect(o.daysLeft, 20);
    expect(o.leftLabel, 'About 3 weeks left');
  });

  test('labels', () {
    expect(
      const BatteryOutlook(BatteryTrend.draining, daysLeft: 5).leftLabel,
      'About 5 days left',
    );
    expect(
      const BatteryOutlook(BatteryTrend.draining, daysLeft: 90).leftLabel,
      'Months left',
    );
    expect(const BatteryOutlook(BatteryTrend.steady).leftLabel, isNull);
  });
}
