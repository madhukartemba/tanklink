/// Short labels shared by several screens.
library;

/// "Off", "45 min", "1 hour", "2 hours", "1h 30m".
String formatAutoOff(int minutes) {
  if (minutes <= 0) return 'Off';
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (m == 0) return h == 1 ? '1 hour' : '$h hours';
  return '${h}h ${m}m';
}
