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
            'Other pump lights',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          for (final (look, means) in _pumpLights)
            _LightRow(look: look, means: means, scheme: scheme),
          const SizedBox(height: 20),
          Text(
            'Other tank lights',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          for (final (look, means) in _tankLights)
            _LightRow(look: look, means: means, scheme: scheme),
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

/// What the pump's LED strip shows besides numbered codes (status_led.cpp).
const _pumpLights = [
  ('Amber, breathing slowly', 'No phone has added this pump yet.'),
  ('Blue, sweeping side to side', 'Ready for a phone to add it (pairing).'),
  ('Orange, sweeping side to side', 'Listening for a tank sensor to pair.'),
  ('Soft white glow in the middle', 'Standby. The selected tank is not full.'),
  ('Soft teal glow in the middle', 'Standby. The selected tank is full.'),
  ('Blue wave', 'The pump is running.'),
  (
    'Filling from the middle while you hold the button',
    'Blue: let go to start setup. Red: keep holding to reset the pump.',
  ),
  ('Filling from one end', 'A firmware update is being received.'),
  ('Solid green', 'Update checked. The pump restarts.'),
  (
    'Solid red for 2 seconds',
    'The update stopped or failed. The old firmware stays.',
  ),
];

/// What the tank's single LED shows besides numbered codes (tank_led.c).
const _tankLights = [
  ('Two soft pulses', 'The tank just started.'),
  ('One soft flash', 'The pump answered.'),
  ('Slow breathing (about 2.4 s a breath)', 'Pairing with the pump.'),
  ('Faster breathing (about 1.4 s a breath)', 'Receiving a firmware update.'),
];

class _LightRow extends StatelessWidget {
  const _LightRow({
    required this.look,
    required this.means,
    required this.scheme,
  });

  final String look;
  final String means;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(look, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(
            means,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.3),
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
