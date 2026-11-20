/// Water and power use worked out from the fill history. Pure, so it is
/// unit tested (test/water_use_test.dart).
///
/// The pump only knows how long it ran. Litres come from the pump's flow
/// (litres a minute) and energy from its power (watts), both set by the user
/// on the phone; cost is energy times the price per kWh.
library;

import 'dart:math' as math;

import '../ble/models.dart';

/// What the phone knows about one pump, saved per pump on the phone.
class UsageSettings {
  const UsageSettings({
    this.flowLpm,
    this.pumpWatts = defaultWatts,
    this.pricePerKwh,
    this.currency = defaultCurrency,
  });

  /// About 1 HP, a common home pump. Shown as an estimate until changed.
  static const double defaultWatts = 750;

  /// Rupees until the user picks another symbol.
  static const String defaultCurrency = '\u20b9';

  /// Litres a minute, or null when not set.
  final double? flowLpm;
  final double pumpWatts;

  /// Price of one kWh, or null when not set.
  final double? pricePerKwh;

  /// Shown before money amounts. ₹ by default; may be set to empty.
  final String currency;

  bool get hasFlow => (flowLpm ?? 0) > 0;
  bool get hasPrice => (pricePerKwh ?? 0) > 0;

  UsageSettings copyWith({
    double? Function()? flowLpm,
    double? pumpWatts,
    double? Function()? pricePerKwh,
    String? currency,
  }) => UsageSettings(
    flowLpm: flowLpm != null ? flowLpm() : this.flowLpm,
    pumpWatts: pumpWatts ?? this.pumpWatts,
    pricePerKwh: pricePerKwh != null ? pricePerKwh() : this.pricePerKwh,
    currency: currency ?? this.currency,
  );

  Map<String, Object?> toJson() => {
    'flow_lpm': flowLpm,
    'watts': pumpWatts,
    'price_kwh': pricePerKwh,
    'currency': currency,
  };

  static UsageSettings fromJson(Map<String, dynamic> j) {
    double? num_(Object? v) => v is num && v > 0 ? v.toDouble() : null;
    return UsageSettings(
      flowLpm: num_(j['flow_lpm']),
      pumpWatts: num_(j['watts']) ?? defaultWatts,
      pricePerKwh: num_(j['price_kwh']),
      currency: (j['currency'] as String? ?? defaultCurrency).trim(),
    );
  }

  double litres(int runSec) => hasFlow ? runSec / 60 * flowLpm! : 0;
  double kwh(int runSec) => runSec / 3600 * pumpWatts / 1000;
  double cost(int runSec) => hasPrice ? kwh(runSec) * pricePerKwh! : 0;
}

/// What a chart shows.
enum UseMetric { water, time, energy, cost }

extension UseMetricValue on UseMetric {
  /// The value of [runSec] of pumping in this metric (time is in minutes).
  double of(int runSec, UsageSettings s) => switch (this) {
    UseMetric.water => s.litres(runSec),
    UseMetric.time => runSec / 60,
    UseMetric.energy => s.kwh(runSec),
    UseMetric.cost => s.cost(runSec),
  };

  bool available(UsageSettings s) => switch (this) {
    UseMetric.water => s.hasFlow,
    UseMetric.cost => s.hasPrice,
    _ => true,
  };
}

/// One calendar day (phone-local, which is pump-local too).
class DayUse {
  const DayUse({required this.day, required this.runSec, required this.fills});

  final DateTime day;
  final int runSec;
  final int fills;
}

/// Pumping over the last [days] days, ending today.
class UsageReport {
  const UsageReport({
    required this.days,
    required this.runSecBySlot,
    required this.startsByHour,
    required this.firstDay,
  });

  /// Oldest first; one entry per day, zero for days without a fill.
  final List<DayUse> days;

  /// Run time per tank slot.
  final Map<int, int> runSecBySlot;

  /// Fill starts per hour of day, 24 entries.
  final List<int> startsByHour;

  /// Day of the oldest fill in the window, or null with none. Averages count
  /// from here, so a new phone doesn't show a low average for days it never
  /// saw.
  final DateTime? firstDay;

  int get totalRunSec => days.fold(0, (a, d) => a + d.runSec);
  int get totalFills => days.fold(0, (a, d) => a + d.fills);
  bool get isEmpty => totalFills == 0;

  /// Run time over the last [n] days, today included.
  int runSecLast(int n) => days
      .skip(days.length - n.clamp(0, days.length))
      .fold(0, (a, d) => a + d.runSec);

  /// Days counted for averages: from the first fill to today.
  int get daysCovered {
    final first = firstDay;
    if (first == null) return 0;
    return days.last.day.difference(first).inDays + 1;
  }

  /// Average run time per day over the covered days.
  double get avgRunSecPerDay =>
      daysCovered == 0 ? 0 : totalRunSec / daysCovered;
}

DateTime _dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

/// Group [fills] by the day they started. Fills without a time (the pump's
/// clock was unknown) are skipped.
UsageReport buildUsage(
  List<FillRecord> fills, {
  required DateTime now,
  int days = 30,
}) {
  final today = _dayOf(now);
  // Calendar days, not 24 h steps, so a DST change can't skip or repeat one.
  final start = DateTime(today.year, today.month, today.day - (days - 1));
  final run = List<int>.filled(days, 0);
  final count = List<int>.filled(days, 0);
  final bySlot = <int, int>{};
  final byHour = List<int>.filled(24, 0);
  DateTime? first;
  for (final f in fills) {
    final at = f.startedAt;
    if (at == null) continue;
    final day = _dayOf(at);
    if (day.isBefore(start) || day.isAfter(today)) continue;
    final i = DateTime.utc(
      day.year,
      day.month,
      day.day,
    ).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
    run[i] += f.ranSec;
    count[i]++;
    bySlot[f.slot] = (bySlot[f.slot] ?? 0) + f.ranSec;
    byHour[at.hour]++;
    if (first == null || day.isBefore(first)) first = day;
  }
  return UsageReport(
    days: [
      for (var i = 0; i < days; i++)
        DayUse(
          day: DateTime(start.year, start.month, start.day + i),
          runSec: run[i],
          fills: count[i],
        ),
    ],
    runSecBySlot: bySlot,
    startsByHour: byHour,
    firstDay: first,
  );
}

/// "850 L", "12,400 L".
String formatLitres(double l) {
  final n = l.round();
  final s = n.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return '$s L';
}

String formatMoney(double v, String currency) {
  final s = v >= 100 ? v.round().toString() : v.toStringAsFixed(2);
  return currency.isEmpty ? s : '$currency$s';
}

String formatKwh(double v) =>
    '${v >= 10 ? v.round() : double.parse(v.toStringAsFixed(1))} kWh';

/// "45 min", "3 h 10 min".
String formatMinutes(double minutes) {
  final m = minutes.round();
  if (m < 60) return '$m min';
  final h = m ~/ 60;
  final r = m % 60;
  return r == 0 ? '$h h' : '$h h $r min';
}

/// A metric's value as display text.
String formatMetric(UseMetric m, double v, UsageSettings s) => switch (m) {
  UseMetric.water => formatLitres(v),
  UseMetric.time => formatMinutes(v),
  UseMetric.energy => formatKwh(v),
  UseMetric.cost => formatMoney(v, s.currency),
};

/// Made-up fills for the debug "Sample data" switch: a morning fill most
/// days and an evening one some days, over [days] days, spread over [slots].
/// The same every time, newest first.
List<FillRecord> sampleFills({
  required DateTime now,
  required List<int> slots,
  int days = 90,
}) {
  final rnd = math.Random(7);
  final tanks = slots.isEmpty ? const [0] : slots;
  final out = <FillRecord>[];
  for (var d = days - 1; d >= 0; d--) {
    final day = DateTime(now.year, now.month, now.day - d);
    final weekend = day.weekday >= DateTime.saturday;
    if (rnd.nextDouble() < 0.88) {
      final at = day.add(
        Duration(hours: 5 + rnd.nextInt(3), minutes: rnd.nextInt(60)),
      );
      if (!at.isAfter(now)) {
        out.add(
          FillRecord(
            startedAt: at,
            ranSec: 900 + rnd.nextInt(weekend ? 900 : 600),
            slot: tanks.first,
            startedBy: rnd.nextBool() ? 8 : 3, // auto-fill or schedule
            stoppedBy: rnd.nextDouble() < 0.94
                ? 4
                : 5, // full, sometimes auto-off
          ),
        );
      }
    }
    if (rnd.nextDouble() < (weekend ? 0.7 : 0.4)) {
      final at = day.add(
        Duration(hours: 18 + rnd.nextInt(3), minutes: rnd.nextInt(60)),
      );
      if (!at.isAfter(now)) {
        out.add(
          FillRecord(
            startedAt: at,
            ranSec: 400 + rnd.nextInt(700),
            slot: tanks[rnd.nextInt(tanks.length)],
            startedBy: 1, // app
            stoppedBy: 4,
          ),
        );
      }
    }
  }
  out.sort((a, b) => b.startedAt!.compareTo(a.startedAt!));
  return out;
}

/// Flow and price to show with sample data when the user hasn't set them.
const sampleUsageSettings = UsageSettings(flowLpm: 40, pricePerKwh: 8);
