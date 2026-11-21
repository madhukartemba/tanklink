import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../ble/pump_session.dart';
import '../../diag/app_log.dart';
import '../../util/nav.dart';

/// Opens the pump's pairing mode so another phone can add it, and shows
/// what to do on that phone until pairing ends or the user stops it.
Future<void> showAddPhoneDialog(BuildContext context, PumpSession session) {
  if (session.pumpOn) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Stop the pump first. Pairing mode switches it off.'),
      ),
    );
    return Future.value();
  }
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AddPhoneDialog(session: session),
  );
}

enum _Stage { opening, open, ended, failed }

class _AddPhoneDialog extends StatefulWidget {
  const _AddPhoneDialog({required this.session});

  final PumpSession session;

  @override
  State<_AddPhoneDialog> createState() => _AddPhoneDialogState();
}

class _AddPhoneDialogState extends State<_AddPhoneDialog> {
  _Stage _stage = _Stage.opening;
  Timer? _poll;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      await widget.session.openPhonePairing();
    } catch (e) {
      AppLog.w('pump', 'Open pairing failed: $e');
      if (mounted) setState(() => _stage = _Stage.failed);
      return;
    }
    if (!mounted) return;
    setState(() => _stage = _Stage.open);
    // The pump closes the window by itself after about a minute, after a
    // phone is added, or on a button press: notice that.
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _check());
  }

  Future<void> _check() async {
    if (_polling || _stage != _Stage.open) return;
    _polling = true;
    try {
      final open = await widget.session.readPairingOpen();
      if (!open && mounted) {
        _poll?.cancel();
        setState(() => _stage = _Stage.ended);
      }
    } catch (_) {
      // A missed read is fine; try again on the next tick.
    } finally {
      _polling = false;
    }
  }

  Future<void> _stop() async {
    _poll?.cancel();
    if (_stage == _Stage.open) await widget.session.closePhonePairing();
    if (mounted) popSelf(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pumpName = widget.session.selected?.name ?? 'this pump';
    final Widget body;
    switch (_stage) {
      case _Stage.opening:
        body = const Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(width: 12),
            Expanded(child: Text('Turning on pairing mode…')),
          ],
        );
      case _Stage.open:
        body = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'On the other phone, open TankLink, tap + and pick $pumpName.',
            ),
            const SizedBox(height: 12),
            Text(
              'Pairing mode stays on for about a minute. The pump can’t '
              'start meanwhile.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Waiting for the other phone…',
                    style: TextStyle(color: scheme.primary),
                  ),
                ),
              ],
            ),
          ],
        );
      case _Stage.ended:
        body = const Text(
          'Pairing mode is off. If the other phone now shows the pump, it’s '
          'added. If not, start pairing again.',
        );
      case _Stage.failed:
        body = const Text(
          'Couldn’t turn on pairing mode. Check the pump isn’t running or '
          'updating, then try again.',
        );
    }
    return AlertDialog(
      title: const Text('Add another phone'),
      content: body,
      actions: [
        if (_stage == _Stage.open || _stage == _Stage.opening)
          TextButton(onPressed: _stop, child: const Text('Stop pairing'))
        else
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
      ],
    );
  }
}
