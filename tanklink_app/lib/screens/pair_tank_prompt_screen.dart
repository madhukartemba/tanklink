import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ble/pump_session.dart';

/// Shown after claiming a pump that has no tank bound yet.
class PairTankPromptScreen extends StatefulWidget {
  const PairTankPromptScreen({super.key});

  @override
  State<PairTankPromptScreen> createState() => _PairTankPromptScreenState();
}

class _PairTankPromptScreenState extends State<PairTankPromptScreen> {
  bool _starting = false;
  String? _error;

  Future<void> _startPair() async {
    final session = context.read<PumpSession>();
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      await session.startTankPair();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => _ListeningDialog(session: session),
      );
      if (!mounted) return;
      if (session.tankBound) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e');
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final session = context.watch<PumpSession>();
    final pumpName = session.selected?.displayTitle ?? 'this pump';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Add tank sensor'),
        automaticallyImplyLeading: false,
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.sensors, size: 56, color: scheme.primary),
            const SizedBox(height: 20),
            Text(
              'Pair a tank sensor?',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 10),
            Text(
              '$pumpName has no tank sensor yet. Pair one now so the pump can '
              'see tank full / empty and stop safely when the tank is full.',
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
            ),
            const SizedBox(height: 16),
            Text(
              'You will hold the tank button for about 3 seconds while the LED '
              'ramps up, then wait for a breathing flash until pairing finishes.',
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ],
            const Spacer(),
            FilledButton(
              onPressed: _starting ? null : _startPair,
              child: Text(_starting ? 'Starting…' : 'Pair tank sensor'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _starting
                  ? null
                  : () => Navigator.of(context).popUntil((r) => r.isFirst),
              child: const Text('Skip for now'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ListeningDialog extends StatelessWidget {
  const _ListeningDialog({required this.session});

  final PumpSession session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        if (session.tankBound && !session.tankPairing) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) Navigator.of(context).pop();
          });
        }
        return AlertDialog(
          title: Text(session.tankBound ? 'Tank paired' : 'Listening…'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'On the tank sensor, press and hold until the LED is fully bright '
                'and starts breathing. Press once to cancel on the tank.',
              ),
              const SizedBox(height: 16),
              if (session.tankPairing) const LinearProgressIndicator(),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(session.tankBound ? 'Done' : 'Close'),
            ),
          ],
        );
      },
    );
  }
}
