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

/// Why a fill stopped, as a short phrase.
String stopReasonLabel(int cause) => switch (cause) {
  TankLinkUuids.causeApp => 'Stopped in the app',
  TankLinkUuids.causeButton => 'Stopped with the button',
  TankLinkUuids.causeTankFull => 'Tank full',
  TankLinkUuids.causeAutoOff => 'Auto-off',
  TankLinkUuids.causePower => 'Power cut or restart',
  TankLinkUuids.causeSystem => 'Stopped for an update or setup',
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
