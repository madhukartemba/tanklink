import 'package:flutter/material.dart';

/// Mirrors docs/ERROR_CODES.md — keep in sync when adding LED codes.
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

  static const _pumpCodes = <({int code, String name, String detail})>[
    (
      code: 1,
      name: 'Tank full',
      detail:
          'Start denied because the tank reports full. The pump also stops if a full packet arrives while running.',
    ),
    (
      code: 2,
      name: 'LoRa missing',
      detail: 'RA-02 did not initialize at boot. Check radio wiring and power.',
    ),
    (
      code: 3,
      name: 'Tank offline',
      detail:
          'Bound tank missed its heartbeat. Check tank power, antenna, and range. Clears when a packet returns.',
    ),
    (
      code: 4,
      name: 'Blocked',
      detail: 'Start denied during firmware update or BLE pairing lockout.',
    ),
    (
      code: 5,
      name: 'Not paired',
      detail:
          'Local Start was held while this pump has no phone owner. Claim it from the app first.',
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
            'Long hard blinks (not soft pulses), twice, with a pause between groups. Boot, TX, success, and pairing use soft pulses.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          for (final e in _tankCodes) _CodeCard(entry: e, scheme: scheme),
          const SizedBox(height: 20),
          Text(
            'Pump NeoPixel',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'Same pattern: N long hard red blinks, pause, repeat. The app also shows the last pump code on the home screen.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          for (final e in _pumpCodes) _CodeCard(entry: e, scheme: scheme),
          const SizedBox(height: 20),
          Text(
            'Factory reset',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'Hold Start+Stop ~5 s for BLE pairing (blue), then keep holding ~10 s more (red progress). '
            'Or use Settings → Factory reset and type RESET. Clears pairing, tank bind, and settings, then reboots.',
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
          ),
          const SizedBox(height: 16),
          Text(
            'Almost-empty float',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'Optional. Tank firmware leaves it disabled by default so an unwired pin does not always show Empty. '
            'Enable CONFIG_TANK_ENABLE_EMPTY_FLOAT only if you wire the empty float.',
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
          ),
          const SizedBox(height: 16),
          Text(
            'Pairing tip',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'Hold the tank button to ramp the LED, then keep holding until breathing flash starts. '
            'Press once to cancel. Short press after pairing sends status; hold still works during the short awake window.',
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
