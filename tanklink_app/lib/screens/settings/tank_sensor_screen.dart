import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../ble/pump_session.dart';
import '../../ble/tanklink_uuids.dart';
import 'update_tiles.dart';

class TankSensorScreen extends StatelessWidget {
  const TankSensorScreen({super.key});

  Future<void> _setMode(BuildContext context, int mode) async {
    final session = context.read<PumpSession>();
    if (mode == session.sensorMode) return;
    if (session.sensorMode == TankLinkUuids.sensorModeTwo &&
        mode != TankLinkUuids.sensorModeTwo) {
      if (session.pumpOn) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Stop the pump before changing mode')),
        );
        return;
      }
      final second = session.tankNameFor(1);
      final doomed = session.schedules.where((s) => s.slot == 1).toList();
      final times = doomed.isEmpty
          ? 'No schedules use $second.'
          : doomed
                .map(
                  (s) =>
                      TimeOfDay(hour: s.hour, minute: s.minute).format(context),
                )
                .join(', ');
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Leave two-tank mode?'),
          content: Text(
            '$second will be removed. Schedules for that tank are deleted. '
            '${session.tankNameFor(0)} and its schedules stay.\n\n$times',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove tank'),
            ),
          ],
        ),
      );
      if (ok != true || !context.mounted) return;
    }
    try {
      await session.setSensorMode(mode);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not change mode: $e')));
    }
  }

  Future<void> _rename(BuildContext context, TankSlot slot) async {
    final session = context.read<PumpSession>();
    final controller = TextEditingController(text: slot.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename tank'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: TankLinkUuids.tankNameLen - 1,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !context.mounted) return;
    try {
      await session.renameTank(slot.index, name);
    } catch (e) {
      if (!context.mounted) return;
      final msg = e.toString().replaceFirst('StateError: ', '');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final scheme = Theme.of(context).colorScheme;
    const ready = true;
    return Scaffold(
      appBar: AppBar(title: const Text('Tank sensor')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          Text('Float mode', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          RadioGroup<int>(
            groupValue: session.sensorMode,
            onChanged: (v) {
              if (v != null) _setMode(context, v);
            },
            child: const Column(
              children: [
                RadioListTile<int>(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Off'),
                  subtitle: Text('Only the first float. It means full.'),
                  value: TankLinkUuids.sensorModeOff,
                ),
                RadioListTile<int>(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Almost empty'),
                  subtitle: Text(
                    'Second float means the tank is almost empty.',
                  ),
                  value: TankLinkUuids.sensorModeEmpty,
                ),
                RadioListTile<int>(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Two tanks'),
                  subtitle: Text(
                    'Each float is the full sensor for its own tank.',
                  ),
                  value: TankLinkUuids.sensorModeTwo,
                ),
              ],
            ),
          ),
          if (session.twoTankMode) ...[
            const SizedBox(height: 8),
            Text('Tanks', style: Theme.of(context).textTheme.titleMedium),
            for (final slot in session.tanks)
              ListTile(
                contentPadding: EdgeInsets.zero,
                enabled: !session.pumpOn || slot.index == session.activeSlot,
                title: Text(
                  slot.name.isEmpty
                      ? session.tankNameFor(slot.index)
                      : slot.name,
                ),
                subtitle: Text(
                  !session.tankOnline
                      ? 'Offline'
                      : session.slotIsFull(slot)
                      ? 'Full'
                      : 'Not full',
                ),
                selected: slot.index == session.activeSlot,
                onTap: session.pumpOn && slot.index != session.activeSlot
                    ? null
                    : () async {
                        try {
                          await session.selectTank(slot.index);
                        } catch (e) {
                          if (!context.mounted) return;
                          final msg = e.toString().replaceFirst(
                            'StateError: ',
                            '',
                          );
                          ScaffoldMessenger.of(context)
                              .showSnackBar(SnackBar(content: Text(msg)));
                        }
                      },
                trailing: IconButton(
                  tooltip: 'Rename',
                  onPressed: () => _rename(context, slot),
                  icon: const Icon(Icons.edit_outlined),
                ),
              ),
            if (session.pumpOn)
              Text(
                'Stop the pump before switching tanks.',
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
              ),
          ],
          const Divider(height: 28),
          if (session.tankBound) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                session.tankOnline
                    ? Icons.sensors
                    : Icons.signal_wifi_off_rounded,
                color: session.tankOnline ? scheme.primary : scheme.error,
              ),
              title: Text(
                session.tankOnline
                    ? 'Paired · #${session.tankShortId}'
                    : 'Out of range · #${session.tankShortId}',
              ),
              subtitle: Text(
                [
                  if (session.tankOnline)
                    'Level ${session.tankLevelLabel}'
                  else
                    'Last heard ${session.tankAgeLabel}',
                  if (session.tankOnline) session.tankAgeLabel,
                  if (session.tankOnline) 'Signal ${session.tankSignalLabel}',
                  'Battery ${session.tankBatteryPct}%'
                      '${session.tankBatteryLow ? " (low)" : ""}',
                ].join(' · '),
              ),
            ),
            const TankFirmwareTile(ready: ready),
            if (!session.tankOnline)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Can’t reach the tank. Check its power and how far away it is.',
                  style: TextStyle(color: scheme.error, height: 1.35),
                ),
              ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: scheme.error),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Unpair tank sensor?'),
                    content: const Text(
                      'The pump will stop accepting this tank until you pair again.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Unpair'),
                      ),
                    ],
                  ),
                );
                if (ok == true && context.mounted) {
                  try {
                    await session.unpairTank();
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Unpair tank failed: $e')),
                      );
                    }
                  }
                }
              },
              child: const Text('Unpair tank sensor'),
            ),
          ] else ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                session.tankPairing ? 'Waiting for tank…' : 'Not paired',
              ),
              subtitle: const Text(
                'Hold the tank button 3 seconds while pairing is open.',
              ),
            ),
            FilledButton.icon(
              onPressed: session.tankPairing
                  ? null
                  : () async {
                      try {
                        await session.startTankPair();
                        if (!context.mounted) return;
                        await showDialog<void>(
                          context: context,
                          barrierDismissible: false,
                          builder: (ctx) => _TankPairDialog(session: session),
                        );
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Tank pair failed: $e')),
                          );
                        }
                      }
                    },
              icon: const Icon(Icons.sensors),
              label: Text(
                session.tankPairing ? 'Listening…' : 'Pair tank sensor',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TankPairDialog extends StatelessWidget {
  const _TankPairDialog({required this.session});

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
          title: Text(session.tankBound ? 'Tank paired' : 'Pairing tank…'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'On the tank sensor, press and hold the button for about 3 seconds.',
              ),
              const SizedBox(height: 16),
              if (session.tankPairing)
                const LinearProgressIndicator()
              else if (session.tankBound)
                Text(
                  'Connected · #${session.tankIdHex.length >= 4 ? session.tankIdHex.substring(session.tankIdHex.length - 4).toUpperCase() : "----"}',
                )
              else
                const Text('Window closed — try again.'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(session.tankBound ? 'Done' : 'Cancel'),
            ),
          ],
        );
      },
    );
  }
}
