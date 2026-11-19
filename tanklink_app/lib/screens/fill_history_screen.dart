import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../ble/pump_session.dart';
import '../ble/tanklink_uuids.dart';
import '../util/fill_insight.dart';
import '../util/format.dart';

/// The pump's last fills: when, which tank, how long, and why it stopped.
class FillHistoryScreen extends StatelessWidget {
  const FillHistoryScreen({super.key});

  static String _when(BuildContext context, DateTime? at) {
    if (at == null) return 'Time unknown';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(at.year, at.month, at.day);
    final time = TimeOfDay.fromDateTime(at).format(context);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today $time';
    if (diff == 1) return 'Yesterday $time';
    return '${day.day}/${day.month} $time';
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final scheme = Theme.of(context).colorScheme;
    final fills = session.fills;
    final slow = findSlowFill(fills);

    return Scaffold(
      appBar: AppBar(title: const Text('Fill history')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          if (slow != null) ...[
            Card.filled(
              color: scheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '${session.tankNameFor(slow.fill.slot)} took '
                  '${formatRunTime(slow.fill.ranSec)} to fill. It usually takes '
                  '${formatRunTime(slow.usualSec)}. Check the pump, the pipes, '
                  'and for leaks.',
                  style: TextStyle(
                    color: scheme.onErrorContainer,
                    height: 1.35,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (fills.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Text(
                'No fills yet. Each fill shows up here once the pump stops.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          for (final f in fills)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                f.stoppedBy == TankLinkUuids.causeTankFull
                    ? Icons.water_drop
                    : f.stoppedBy == TankLinkUuids.causePower
                    ? Icons.power_off_rounded
                    : Icons.stop_circle_outlined,
                color: f == slow?.fill ? scheme.error : scheme.primary,
              ),
              title: Text(
                '${session.multiTank ? '${session.tankNameFor(f.slot)} · ' : ''}'
                '${formatRunTime(f.ranSec)}',
              ),
              subtitle: Text(
                [
                  _when(context, f.startedAt),
                  stopReasonLabel(f.stoppedBy),
                  ?startReasonLabel(f.startedBy),
                ].join(' · '),
              ),
            ),
          if (fills.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'The pump keeps the last 20 fills.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}
