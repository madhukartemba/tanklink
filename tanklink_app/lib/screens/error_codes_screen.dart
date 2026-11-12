import 'package:flutter/material.dart';

/// Mirrors docs/ERROR_CODES.md — keep in sync when adding tank LED codes.
class ErrorCodesScreen extends StatelessWidget {
  const ErrorCodesScreen({super.key});

  static const _tankCodes = <({int code, String name, String detail})>[
    (
      code: 1,
      name: 'Not paired',
      detail:
          'Short press while the tank is not paired. Open Pair tank sensor on the pump, then hold the tank button ~3 seconds.',
    ),
    (
      code: 2,
      name: 'LoRa missing',
      detail: 'The radio did not start. Check RA-02 wiring and 3V3 power.',
    ),
    (
      code: 3,
      name: 'No ACK',
      detail:
          'Tank is paired but the pump did not acknowledge. Check range, power, and that this tank is still bound to that pump.',
    ),
    (
      code: 4,
      name: 'Pairing cancelled',
      detail: 'You pressed the button once during pairing mode to cancel.',
    ),
    (
      code: 5,
      name: 'Pairing timed out',
      detail:
          'No successful pair ACK within the pairing window (~60s). Start Pair tank sensor again and retry the hold.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Error codes')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Text(
            'Tank sensor LED',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'The LED blinks the code number twice (smooth pulses), with a pause between groups.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          for (final e in _tankCodes) ...[
            Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  child: Text(
                    '${e.code}',
                    style: TextStyle(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                title: Text(e.name),
                subtitle: Text(e.detail),
                isThreeLine: true,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            'Pairing tip',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'Hold the tank button to ramp the LED, then keep holding until breathing flash starts. '
            'Press once to cancel. Short press after pairing sends status; hold still works during the short awake window.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
