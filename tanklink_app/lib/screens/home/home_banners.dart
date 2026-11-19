import 'package:material_ui/material_ui.dart';

import '../../ble/pump_session.dart';
import '../../ble/tanklink_uuids.dart';
import '../../diag/report_builder.dart';
import '../report_problem_screen.dart';

/// Small "Report" link at the bottom of an error banner.
class _ReportLink extends StatelessWidget {
  const _ReportLink({required this.color, required this.onPressed});

  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: TextButton.icon(
          style: TextButton.styleFrom(
            foregroundColor: color,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
          onPressed: onPressed,
          icon: const Icon(Icons.bug_report_outlined, size: 18),
          label: const Text('Report'),
        ),
      ),
    );
  }
}

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
                  _ReportLink(
                    color: scheme.onTertiaryContainer,
                    onPressed: () => openReportScreen(
                      context,
                      ReportProblem(
                        kind: 'interrupt',
                        code: event.reason,
                        title: _title,
                        detail: _detail(context),
                        seenAt: event.backAt,
                      ),
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
    final title = session.pumpErrorTitle;
    if (title == null) return const SizedBox.shrink();
    final code = session.pumpLastError;
    return _CodeBanner(
      title: title,
      detail: session.pumpErrorDetail,
      code: code,
      onClear: session.clearPumpError,
      problem: ReportProblem(
        kind: 'pump-err',
        code: code,
        title: 'Pump error $code: $title',
        detail: session.pumpErrorDetail,
      ),
    );
  }
}

class TankFaultBanner extends StatelessWidget {
  const TankFaultBanner({super.key, required this.session});

  final PumpSession session;

  @override
  Widget build(BuildContext context) {
    final title = session.tankFaultTitle;
    if (title == null) return const SizedBox.shrink();
    final code = session.tankFault;
    return _CodeBanner(
      title: title,
      detail: session.tankFaultDetail,
      code: code,
      problem: ReportProblem(
        kind: 'tank-err',
        code: code,
        title: 'Tank sensor code $code: $title',
        detail: session.tankFaultDetail,
      ),
    );
  }
}

class _CodeBanner extends StatelessWidget {
  const _CodeBanner({
    required this.title,
    required this.detail,
    required this.code,
    required this.problem,
    this.onClear,
  });

  final String title;
  final String? detail;
  final int code;
  final ReportProblem problem;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final fg = scheme.onErrorContainer;
    // Title, code and X share one row of this height so they line up.
    const rowHeight = 32.0;
    return Material(
      color: scheme.errorContainer.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, 8, onClear != null ? 4 : 14, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: rowHeight,
              child: Icon(Icons.error_outline_rounded, color: fg),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: rowHeight,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.titleSmall?.copyWith(
                              color: fg,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: fg.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            'Code $code',
                            style: text.labelSmall?.copyWith(
                              color: fg,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (onClear != null)
                          IconButton(
                            tooltip: 'Clear error',
                            onPressed: onClear,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 40,
                              height: rowHeight,
                            ),
                            iconSize: 20,
                            icon: Icon(Icons.close_rounded, color: fg),
                          ),
                      ],
                    ),
                  ),
                  if (detail != null)
                    Padding(
                      padding: EdgeInsets.only(right: onClear != null ? 10 : 0),
                      child: Text(
                        detail!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color: fg.withValues(alpha: 0.9),
                          height: 1.3,
                        ),
                      ),
                    ),
                  _ReportLink(
                    color: fg,
                    onPressed: () => openReportScreen(context, problem),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ConnectFailedBanner extends StatelessWidget {
  const ConnectFailedBanner({super.key, required this.session});

  final PumpSession session;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = session.status;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        child: Row(
          children: [
            Icon(
              Icons.bluetooth_disabled_rounded,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                status,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            _ReportLink(
              color: scheme.primary,
              onPressed: () => openReportScreen(
                context,
                ReportProblem(
                  kind: 'connect',
                  title: 'Connection problem: $status',
                  seenAt: DateTime.now(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
