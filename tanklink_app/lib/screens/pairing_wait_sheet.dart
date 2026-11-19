import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../ble/protocol.dart';
import '../ble/pump_session.dart';

/// Shows how to put [name] in pairing mode and waits for it.
///
/// Returns true when the pump is ready to add (seen in its advertising, or,
/// for firmware that doesn't say, when the user taps Try again), false when
/// the user cancels.
Future<bool> showPairingWaitSheet(
  BuildContext context, {
  required String remoteId,
  required String name,
  required bool canDetect,
}) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) =>
        _PairingWaitSheet(remoteId: remoteId, name: name, canDetect: canDetect),
  );
  return ok ?? false;
}

class _PairingWaitSheet extends StatefulWidget {
  const _PairingWaitSheet({
    required this.remoteId,
    required this.name,
    required this.canDetect,
  });

  final String remoteId;
  final String name;

  /// The pump's firmware says in its advertising whether it can be added.
  final bool canDetect;

  @override
  State<_PairingWaitSheet> createState() => _PairingWaitSheetState();
}

class _PairingWaitSheetState extends State<_PairingWaitSheet> {
  PumpSession? _session;
  bool _done = false;
  DateTime _lastScanStart = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    if (widget.canDetect) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _session = context.read<PumpSession>()..addListener(_onSession);
        _scan();
      });
    }
  }

  @override
  void dispose() {
    _session?.removeListener(_onSession);
    // Swiped away: stop the long scan too.
    if (!_done) unawaited(_session?.stopScan());
    super.dispose();
  }

  void _scan() {
    _lastScanStart = DateTime.now();
    unawaited(
      _session?.startScan(
        timeout: const Duration(minutes: 2),
        continuous: true,
      ),
    );
  }

  void _onSession() {
    final s = _session;
    if (s == null || _done || !mounted) return;
    final r = s.scanResults
        .where((r) => r.device.remoteId.str == widget.remoteId)
        .firstOrNull;
    if (r != null &&
        pumpAdvState(r.advertisementData.manufacturerData) ==
            PumpAdvState.ready) {
      // Not from inside the notification: pop on the next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _finish(true);
      });
      return;
    }
    // Keep looking for as long as the sheet is open. Android allows only a
    // few scan starts a minute, so don't restart in a tight loop.
    if (!s.scanning &&
        DateTime.now().difference(_lastScanStart) >
            const Duration(seconds: 30)) {
      _scan();
    }
  }

  void _finish(bool ok) {
    if (_done) return;
    _done = true;
    unawaited(_session?.stopScan());
    Navigator.of(context).pop(ok);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Put ${widget.name} in pairing mode', style: text.titleLarge),
          const SizedBox(height: 16),
          const _Step(
            n: 1,
            text:
                'Hold the pump’s button until its light turns blue, about '
                '5 seconds. Then let go.',
          ),
          const SizedBox(height: 12),
          const _Step(
            n: 2,
            text:
                'Or, on a phone that already has this pump: '
                'Settings → Add another phone.',
          ),
          const SizedBox(height: 12),
          Text(
            'Don’t keep holding the button: when the light turns red, the '
            'pump is reset.',
            style: text.bodySmall?.copyWith(color: scheme.error),
          ),
          const SizedBox(height: 20),
          if (widget.canDetect)
            Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Waiting for the pump… It’s added as soon as it’s ready.',
                    style: text.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            )
          else
            Text(
              'When the light is blue, tap Try again.',
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => _finish(false),
                child: const Text('Cancel'),
              ),
              if (!widget.canDetect) ...[
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => _finish(true),
                  child: const Text('Try again'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.text});

  final int n;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 12,
          backgroundColor: scheme.primaryContainer,
          child: Text(
            '$n',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: scheme.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(text)),
      ],
    );
  }
}
