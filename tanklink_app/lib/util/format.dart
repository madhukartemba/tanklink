/// Short labels shared by several screens.
library;

import '../ble/battery_trend.dart';
import '../ble/tanklink_uuids.dart';

/// "Off", "45 min", "1 hour", "2 hours", "1h 30m".
String formatAutoOff(int minutes) {
  if (minutes <= 0) return 'Off';
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (m == 0) return h == 1 ? '1 hour' : '$h hours';
  return '${h}h ${m}m';
}

/// "45 s", "18 min", "1h 05m".
String formatRunTime(int seconds) {
  if (seconds < 60) return '$seconds s';
  final m = (seconds / 60).round();
  if (m < 60) return '$m min';
  return '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
}

/// The pump's starter setting, as a short phrase.
String starterLabel(int type, int pulseMs) => switch (type) {
  TankLinkUuids.starterTwoButton => 'Start and Stop · $pulseMs ms',
  TankLinkUuids.starterSinglePhase => 'Single-phase MCB',
  _ => 'Not configured',
};

/// Why a fill stopped, as a short phrase.
String stopReasonLabel(int cause) => switch (cause) {
  TankLinkUuids.causeApp => 'Stopped in the app',
  TankLinkUuids.causeButton => 'Stopped with the button',
  TankLinkUuids.causeTankFull => 'Tank full',
  TankLinkUuids.causeAutoOff => 'Auto-off',
  TankLinkUuids.causePower => 'Power cut or restart',
  TankLinkUuids.causeSystem => 'Stopped for an update or setup',
  TankLinkUuids.causeAutoFillTime => 'Allowed time ended',
  _ => 'Stopped',
};

/// Who started a fill, as a short phrase, or null if unknown.
String? startReasonLabel(int cause) => switch (cause) {
  TankLinkUuids.causeApp => 'Started in the app',
  TankLinkUuids.causeButton => 'Started with the button',
  TankLinkUuids.causeSchedule => 'Schedule',
  TankLinkUuids.causeAutoFill => 'Auto-fill: tank was low',
  _ => null,
};

/// Short battery line for a solar tank sensor (fits under the percentage).
String batteryHint(
  int pct, {
  required bool low,
  required BatteryOutlook outlook,
}) {
  if (low) return 'Low · needs sun';
  return switch (outlook.trend) {
    BatteryTrend.charging => 'Charging from solar',
    BatteryTrend.steady => 'Solar keeping up',
    BatteryTrend.draining => outlook.leftLabel ?? 'Slowly draining',
    BatteryTrend.unknown => pct >= 60 ? 'Good' : 'Fine for now',
  };
}

/// Solar is losing ground fast enough to warn about.
bool solarFallingBehind(BatteryOutlook outlook) =>
    outlook.trend == BatteryTrend.draining && (outlook.daysLeft ?? 999) < 14;

const _dayShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Short name of [weekday0] (0 = Monday).
String dayShort(int weekday0) => _dayShort[weekday0];

/// Days of a time window (bit 0 = Monday): "Every day", "Mon–Fri",
/// "Sat, Sun" or a list.
String daysLabel(int days) {
  final d = days & 0x7f;
  if (d == 0x7f) return 'Every day';
  if (d == 0x1f) return 'Mon–Fri';
  if (d == 0x60) return 'Sat, Sun';
  if (d == 0) return 'No days';
  return [
    for (var i = 0; i < 7; i++)
      if ((d >> i) & 1 == 1) _dayShort[i],
  ].join(', ');
}

/// Minutes after midnight as "06:30".
String formatClock(int minuteOfDay) {
  final h = (minuteOfDay ~/ 60).toString().padLeft(2, '0');
  final m = (minuteOfDay % 60).toString().padLeft(2, '0');
  return '$h:$m';
}

/// A time window as "22:00 – 06:00 (next day)".
String windowLabel(int start, int end) =>
    '${formatClock(start)} – ${formatClock(end)}'
    '${end < start ? ' (next day)' : ''}';

/// A wait in minutes: "5 min", "2 h 10 min", "3 days".
String formatWait(int minutes) {
  if (minutes < 60) return '$minutes min';
  if (minutes < 48 * 60) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '$h h' : '$h h $m min';
  }
  return '${(minutes / 1440).round()} days';
}
