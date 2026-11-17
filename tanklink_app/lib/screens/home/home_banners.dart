import 'package:flutter/material.dart';

import '../../ble/pump_session.dart';
import '../../ble/tanklink_uuids.dart';

/// Info notice: a fill was cut short. The pump does not restart on its own.
class FillInterruptedBanner extends StatelessWidget {
  const FillInterruptedBanner({
    super.key,
    required this.event,
    required this.onDismiss,
  });

  final FillInterruption event;
  final Future<void> Function() onDismiss;

  String get _title {
    switch (event.reason) {
      case TankLinkUuids.interruptBrownout:
        return 'Fill stopped by a power dip';
      case TankLinkUuids.interruptRestarted:
        return 'Fill stopped by a pump restart';
      case TankLinkUuids.interruptPowerLost:
      default:
        return 'Fill stopped by a power cut';
    }
  }

  String _when(BuildContext context, DateTime t) {
    final time = TimeOfDay.fromDateTime(t).format(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return time;
    if (diff == 1) return 'yesterday $time';
    return '${t.day}/${t.month} $time';
  }

  String _detail(BuildContext context) {
    final mins = (event.ranSec / 60).round();
    final ran = event.ranSec < 60
        ? 'The pump ran for under a minute'
        : 'The pump ran for about $mins min';
    final parts = <String>[];
    final stopped = event.lastSeenRunningAt;
    parts.add(
      stopped != null
          ? '$ran and stopped around ${_when(context, stopped)}.'
          : '$ran.',
    );
    final back = event.backAt;
    if (back != null) {
      parts.add('Power came back at ${_when(context, back)}.');
    }
    if (event.reason == TankLinkUuids.interruptBrownout) {
      parts.add('Its supply dropped too low, maybe when the motor started.');
    }
    parts.add('It did not restart on its own.');
    return parts.join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.tertiaryContainer.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.power_off_rounded, color: scheme.onTertiaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: scheme.onTertiaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _detail(context),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onTertiaryContainer.withValues(alpha: 0.9),
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              onPressed: () => onDismiss(),
              icon: Icon(
                Icons.close_rounded,
                color: scheme.onTertiaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The pump and app speak different protocol majors. Control is off; the
/// firmware update banner above still works.
class ProtocolMismatchBanner extends StatelessWidget {
  const ProtocolMismatchBanner({super.key, required this.session});

  final PumpSession session;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Material(
      color: scheme.errorContainer.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.system_update_rounded, color: scheme.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                session.pumpNeedsNewerApp
                    ? 'This pump runs newer firmware than this app understands. Update the app to control it.'
                    : 'This pump runs older firmware. Update the pump to control it.',
                style: text.bodyMedium?.copyWith(
                  color: scheme.onErrorContainer,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PumpErrorBanner extends StatelessWidget {
  const PumpErrorBanner({super.key, required this.session});

  final PumpSession session;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = session.pumpErrorTitle;
    final detail = session.pumpErrorDetail;
    if (title == null) return const SizedBox.shrink();
    return Material(
      color: scheme.errorContainer.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: scheme.onErrorContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onErrorContainer.withValues(alpha: 0.9),
                        height: 1.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Text(
              '${session.pumpLastError}',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: scheme.onErrorContainer,
                fontWeight: FontWeight.w800,
              ),
            ),
            IconButton(
              tooltip: 'Clear error',
              visualDensity: VisualDensity.compact,
              onPressed: () => session.clearPumpError(),
              icon: Icon(Icons.close_rounded, color: scheme.onErrorContainer),
            ),
          ],
        ),
      ),
    );
  }
}
