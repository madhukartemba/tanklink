/// Battery trend of a solar tank sensor, from the pump's daily battery log.
///
/// Pure, so it is unit tested. The daily **low** is used: on solar it is the
/// reading before the panel starts charging again, so a falling low means
/// the panel is not keeping up.
library;

import 'models.dart';

enum BatteryTrend {
  /// Not enough days logged yet.
  unknown,

  /// The daily low is rising: solar charges more than the sensor uses.
  charging,

  /// The daily low holds: solar keeps up.
  steady,

  /// The daily low is falling: see [BatteryOutlook.daysLeft].
  draining,
}

class BatteryOutlook {
  const BatteryOutlook(this.trend, {this.daysLeft});

  final BatteryTrend trend;

  /// Days until the daily low reaches [BatteryOutlook.emptyPct], when draining.
  final int? daysLeft;

  /// Below this the sensor stops sending reliably.
  static const emptyPct = 5;

  /// Days of log needed before guessing a trend.
  static const minDays = 3;

  /// Slope (percent per day) that counts as flat.
  static const flatPerDay = 0.5;

  /// "About 3 weeks left", or null when there is no estimate.
  String? get leftLabel {
    final d = daysLeft;
    if (d == null) return null;
    if (d <= 1) return 'About a day left';
    if (d < 14) return 'About $d days left';
    if (d < 60) return 'About ${(d / 7).round()} weeks left';
    return 'Months left';
  }

  /// Least-squares slope of the daily lows over the logged days.
  static BatteryOutlook from(List<BatteryDay> days) {
    final span = days.isEmpty ? 0 : days.last.day - days.first.day;
    if (days.length < minDays || span < minDays - 1) {
      return const BatteryOutlook(BatteryTrend.unknown);
    }
    final n = days.length;
    final mx = days.fold<double>(0, (a, d) => a + d.day) / n;
    final my = days.fold<double>(0, (a, d) => a + d.minPct) / n;
    var num = 0.0;
    var den = 0.0;
    for (final d in days) {
      num += (d.day - mx) * (d.minPct - my);
      den += (d.day - mx) * (d.day - mx);
    }
    final slope = den == 0 ? 0.0 : num / den;
    if (slope > flatPerDay) return const BatteryOutlook(BatteryTrend.charging);
    if (slope >= -flatPerDay) return const BatteryOutlook(BatteryTrend.steady);
    final left = (days.last.minPct - emptyPct) / -slope;
    return BatteryOutlook(
      BatteryTrend.draining,
      daysLeft: left < 0 ? 0 : left.round(),
    );
  }
}
