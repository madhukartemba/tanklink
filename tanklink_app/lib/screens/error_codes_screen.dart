import 'package:flutter/material.dart';

/// Keep in sync with docs/ERROR_CODES.md when adding light codes.
class ErrorCodesScreen extends StatelessWidget {
  const ErrorCodesScreen({super.key});

  static const _tankCodes = <({int code, String name, String detail})>[
    (
      code: 1,
      name: 'Not set up',
      detail:
          'The tank was pressed but is not connected to a pump yet. '
          'Start setup on the pump, then hold the tank button for about 3 seconds.',
    ),
    (
      code: 2,
      name: 'Radio problem',
      detail: 'The tank’s radio did not start. Check its wiring and power.',
    ),
    (
      code: 3,
      name: 'Pump not answering',
      detail:
          'The tank sent a message but the pump did not reply. '
          'Check the distance and power, and make sure this tank is still set up with this pump.',
    ),
    (
      code: 4,
      name: 'Setup cancelled',
      detail: 'You pressed the button once during setup to cancel.',
    ),
    (
      code: 5,
      name: 'Setup timed out',
      detail:
          'The pump did not confirm setup in time. Start setup again and hold the button.',
    ),
  ];

  static const _pumpCodes = <({int code, String name, String detail})>[
    (
      code: 1,
      name: 'Tank full',
      detail:
          'The pump will not start because the tank is full. '
          'It also stops if the tank becomes full while it is running.',
    ),
    (
      code: 2,
      name: 'Radio problem',
      detail: 'The pump’s radio did not start. Check its wiring and power.',
    ),
    (
      code: 3,
      name: 'Tank out of range',
      detail:
          'The pump has not heard from the tank for a while. '
          'Check the tank’s power and distance. This clears when the tank is heard again.',
    ),
    (
      code: 4,
      name: 'Busy',
      detail: 'The pump cannot start during an update or setup. Try again in a moment.',
    ),
    (
      code: 5,
      name: 'Not set up',
      detail:
          'The start button was pressed, but this pump is not connected to a phone yet. '
          'Set it up in the app first.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Warnings and lights')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Text(
            'Tank light',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'The light blinks slowly in groups of long blinks, with a pause between groups. '
            'One short press gives a single blink. Setup shows a slow glow. '
            'A successful send gives one soft flash.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          for (final e in _tankCodes) _CodeCard(entry: e, scheme: scheme),
          const SizedBox(height: 20),
          Text(
            'Pump light',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'Red blinks, with the number of blinks showing the warning. '
            'The app also shows the latest warning on the home screen.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          for (final e in _pumpCodes) _CodeCard(entry: e, scheme: scheme),
          const SizedBox(height: 20),
          Text(
            'Reset the pump',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'Hold the Start and Stop buttons on the pump for about 5 seconds to start setup (blue light). '
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
          Text(
            'Setup tip',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'Hold the tank button until the light glows steadily, then keep holding until it starts to glow and fade. '
            'Press once to cancel. A short press gives one soft flash if it works, '
            'or code 3 blinks if the pump does not answer.',
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
          ),
        ],
      ),
    );
  }
}

class _CodeCard extends StatelessWidget {
  const _CodeCard({required this.entry, required this.scheme});

  final ({int code, String name, String detail}) entry;
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
