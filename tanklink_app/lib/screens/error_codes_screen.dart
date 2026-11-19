import 'package:material_ui/material_ui.dart';

import '../util/error_text.dart';

/// Keep in sync with docs/ERROR_CODES.md when adding light codes.
class ErrorCodesScreen extends StatelessWidget {
  const ErrorCodesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Warnings and lights')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Text('Tank light', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Count the short flashes. There is a long pause, then the same count again. '
            'A tap opens an update window. Hold the button for 3 seconds and setup starts '
            'while you are still holding it. A successful send gives one soft flash.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          for (final e in TankLinkErrors.tank)
            _CodeCard(entry: e, scheme: scheme),
          const SizedBox(height: 20),
          Text('Pump light', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Count the short red flashes. The same count plays twice, with a long pause between. '
            'The app shows the same warning on the home screen.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          for (final e in TankLinkErrors.pump)
            _CodeCard(entry: e, scheme: scheme),
          const SizedBox(height: 20),
          Text(
            'Reset the pump',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'Hold the button on the pump for about 5 seconds to start setup (blue light). '
            'Keep holding for about 10 more seconds to reset it (red light fills up). '
            'Or go to Settings, then Factory reset, and type RESET.',
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
          ),
          const SizedBox(height: 16),
          Text(
            'Almost-empty sensor',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'This is optional. Turn it on or off in Settings, under Tank sensor. '
            'When it is off, the pump only uses the full sensor. '
            'When it is on, both sensors connected and high means full. '
            'Full sensor low with the almost-empty sensor high means half full. '
            'Both low means almost empty.',
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
          ),
          const SizedBox(height: 16),
          Text('Setup tip', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Hold the tank button for 3 seconds. The light brightens as you hold, then glows and fades '
            'while setup runs — you do not have to let go first. Press once to cancel. '
            'A short press gives one soft flash if the pump answers, or code 3 flashes if it does not.',
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
          ),
        ],
      ),
    );
  }
}

class _CodeCard extends StatelessWidget {
  const _CodeCard({required this.entry, required this.scheme});

  final WarnText entry;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Text(
            '${entry.code}',
            style: TextStyle(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        title: Text(entry.name),
        subtitle: Text(entry.detail),
        isThreeLine: true,
      ),
    );
  }
}
