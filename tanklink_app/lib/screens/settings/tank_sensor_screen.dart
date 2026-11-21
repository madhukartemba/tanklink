import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../util/nav.dart';
import '../../ble/pump_session.dart';
import '../../util/format.dart';
import '../../util/error_text.dart';
import '../../ble/tanklink_uuids.dart';
import 'update_tiles.dart';

String _err(Object e) =>
    e.toString().replaceFirst(RegExp(r'^(StateError|Bad state): '), '');

void _snack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

String _tankName(PumpSession session, TankSlot slot) =>
    slot.name.isEmpty ? session.tankNameFor(slot.index) : slot.name;

String _modeLabel(int mode) => switch (mode) {
  TankLinkUuids.sensorModeEmpty => 'Almost-empty float',
  TankLinkUuids.sensorModeTwo => 'Two tanks',
  _ => 'Full float only',
};

/// Open the pump's LoRa pair window and wait for a tank sensor.
Future<void> pairTankSensor(BuildContext context) async {
  final session = context.read<PumpSession>();
  if (!session.canAddSensor) {
    _snack(
      context,
      'Remove a sensor first. A pump takes up to '
      '${TankLinkUuids.sensorMax}.',
    );
    return;
  }
  final before = {for (final s in session.sensors) s.idHex};
  try {
    await session.startTankPair();
  } catch (e) {
    if (context.mounted) _snack(context, 'Tank pair failed: ${_err(e)}');
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _TankPairDialog(session: session, before: before),
  );
  // Closed while still listening: that was Cancel, so stop the pump too.
  if (session.tankPairing) await session.stopTankPair();
}

/// Every tank sensor on this pump, the tanks they watch, and which tank the
/// pump fills.
class TankSensorScreen extends StatelessWidget {
  const TankSensorScreen({super.key});

  Future<void> _select(BuildContext context, TankSlot slot) async {
    try {
      await context.read<PumpSession>().selectTank(slot.index);
    } catch (e) {
      if (context.mounted) _snack(context, _err(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final sensors = session.sensors;

    return Scaffold(
      appBar: AppBar(title: const Text('Tank sensors')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          if (session.multiTank) ...[
            Text('Fill which tank', style: text.titleMedium),
            const SizedBox(height: 2),
            Text(
              'Set the valve or lever to the same tank. Only this tank stops '
              'the pump when full.',
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
            ),
            RadioGroup<int>(
              groupValue: session.activeSlot,
              onChanged: (v) {
                final slot = v == null ? null : session.slotAt(v);
                if (slot != null) _select(context, slot);
              },
              child: Column(
                children: [
                  for (final slot in session.tanks)
                    RadioListTile<int>(
                      contentPadding: EdgeInsets.zero,
                      value: slot.index,
                      enabled:
                          !session.pumpOn || slot.index == session.activeSlot,
                      title: Text(_tankName(session, slot)),
                      subtitle: Text(_slotLine(session, slot)),
                    ),
                ],
              ),
            ),
            if (session.pumpOn)
              Text(
                'Stop the pump before switching tanks.',
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
              ),
            const Divider(height: 28),
          ],
          Text('Sensors', style: text.titleMedium),
          if (sensors.isEmpty)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                session.tankPairing ? 'Waiting for a tank…' : 'None paired',
              ),
              subtitle: const Text(
                'A sensor lets the pump stop when the tank is full.',
              ),
            ),
          for (final sensor in sensors)
            _SensorTile(session: session, sensor: sensor),
          const SizedBox(height: 12),
          if (session.canAddSensor)
            FilledButton.icon(
              onPressed: session.tankPairing
                  ? null
                  : () => pairTankSensor(context),
              icon: const Icon(Icons.add_rounded),
              label: Text(
                session.tankPairing
                    ? 'Listening…'
                    : sensors.isEmpty
                    ? 'Pair tank sensor'
                    : 'Add tank sensor',
              ),
            )
          else
            Text(
              'This pump has ${TankLinkUuids.sensorMax} sensors, the most it '
              'takes. Remove one to add another.',
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
            ),
        ],
      ),
    );
  }

  static String _slotLine(PumpSession session, TankSlot slot) {
    final sensor = session.sensorForSlot(slot);
    if (sensor == null) return 'No sensor';
    final state = !session.sensorOnline(sensor)
        ? 'Out of range'
        : session.slotIsFull(slot)
        ? 'Full'
        : 'Not full';
    return '$state · sensor #${sensor.shortId}';
  }
}

class _SensorTile extends StatelessWidget {
  const _SensorTile({required this.session, required this.sensor});

  final PumpSession session;
  final TankSensor sensor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final online = session.sensorOnline(sensor);
    final tanks = session.slotsOf(sensor).map((t) => _tankName(session, t));
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        online ? Icons.sensors : Icons.signal_wifi_off_rounded,
        color: online ? scheme.primary : scheme.error,
      ),
      title: Text('Sensor #${sensor.shortId}'),
      subtitle: Text(
        [
          tanks.join(', '),
          if (online)
            'Battery ${sensor.batteryPct}%'
                '${session.sensorBatteryLow(sensor) ? " (low)" : ""}'
          else
            'Out of range',
          ?TankLinkErrors.tankTitle(sensor.fault),
          session.sensorAgeLabel(sensor),
        ].where((s) => s.isNotEmpty).join(' · '),
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TankSensorDetailScreen(idHex: sensor.idHex),
        ),
      ),
    );
  }
}

/// One sensor: its status, float mode, tanks, firmware, and unpair.
class TankSensorDetailScreen extends StatelessWidget {
  const TankSensorDetailScreen({super.key, required this.idHex});

  final String idHex;

  Future<void> _setMode(
    BuildContext context,
    TankSensor sensor,
    int mode,
  ) async {
    final session = context.read<PumpSession>();
    if (mode == sensor.mode) return;
    if (sensor.mode == TankLinkUuids.sensorModeTwo &&
        mode != TankLinkUuids.sensorModeTwo) {
      final second = session
          .slotsOf(sensor)
          .where((t) => t.sensor == 1)
          .firstOrNull;
      if (second != null) {
        if (session.pumpOn && second.index == session.activeSlot) {
          _snack(context, 'Stop the pump before removing this tank');
          return;
        }
        final ok = await _confirmRemoveTanks(
          context,
          session,
          title: 'Leave two-tank mode?',
          tanks: [second],
          action: 'Remove tank',
        );
        if (ok != true || !context.mounted) return;
      }
    }
    try {
      await session.setSensorMode(sensor, mode);
    } catch (e) {
      if (context.mounted) _snack(context, 'Could not change mode: ${_err(e)}');
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
      if (context.mounted) _snack(context, _err(e));
    }
  }

  Future<void> _unpair(BuildContext context, TankSensor sensor) async {
    final session = context.read<PumpSession>();
    if (session.sensorFeedsRunningFill(sensor)) {
      _snack(context, 'Stop the pump before removing this sensor');
      return;
    }
    final last = session.sensors.length == 1;
    final ok = await _confirmRemoveTanks(
      context,
      session,
      title: 'Unpair sensor #${sensor.shortId}?',
      // The last sensor's first tank stays, as a tank without a sensor.
      tanks: [
        for (final t in session.slotsOf(sensor))
          if (!(last && t.sensor == 0)) t,
      ],
      action: 'Unpair',
      lead: 'The pump will ignore this sensor until you pair it again.',
    );
    if (ok != true || !context.mounted) return;
    try {
      await session.unpairSensor(sensor);
      if (context.mounted) popSelf(context);
    } catch (e) {
      if (context.mounted) _snack(context, 'Unpair failed: ${_err(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final sensor = session.sensors.where((s) => s.idHex == idHex).firstOrNull;
    if (sensor == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Tank sensor')),
        body: const Center(child: Text('This sensor is no longer paired.')),
      );
    }
    final online = session.sensorOnline(sensor);
    final tanks = session.slotsOf(sensor);
    final rssi = sensor.rssiDbm;

    return Scaffold(
      appBar: AppBar(title: Text('Sensor #${sensor.shortId}')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              online ? Icons.sensors : Icons.signal_wifi_off_rounded,
              color: online ? scheme.primary : scheme.error,
            ),
            title: Text(online ? 'In range' : 'Out of range'),
            subtitle: Text(
              [
                'Last heard ${session.sensorAgeLabel(sensor)}',
                if (online)
                  'Signal ${session.sensorSignalLabel(sensor)} ($rssi dBm)',
              ].join(' · '),
            ),
          ),
          _BatteryTile(session: session, sensor: sensor),
          if (TankLinkErrors.tankTitle(sensor.fault) != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.error_outline_rounded, color: scheme.error),
              title: Text(TankLinkErrors.tankTitle(sensor.fault)!),
              subtitle: Text(TankLinkErrors.tankDetail(sensor.fault) ?? ''),
            ),
          if (!online)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Can’t reach this sensor. Check its power and how far away it is.',
                style: TextStyle(color: scheme.error, height: 1.35),
              ),
            ),
          const Divider(height: 28),
          Text('Tanks', style: text.titleMedium),
          for (final slot in tanks)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_tankName(session, slot)),
              subtitle: Text(
                [
                  sensor.mode == TankLinkUuids.sensorModeTwo
                      ? (slot.sensor == 0 ? 'Float 1' : 'Float 2')
                      : 'Full float',
                  if (online) session.slotIsFull(slot) ? 'Full' : 'Not full',
                  if (slot.index == session.activeSlot && session.multiTank)
                    'Selected',
                ].join(' · '),
              ),
              trailing: IconButton(
                tooltip: 'Rename',
                onPressed: () => _rename(context, slot),
                icon: const Icon(Icons.edit_outlined),
              ),
            ),
          const Divider(height: 28),
          Text('Second float', style: text.titleMedium),
          const SizedBox(height: 4),
          RadioGroup<int>(
            groupValue: sensor.mode,
            onChanged: (v) {
              if (v != null) _setMode(context, sensor, v);
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
          const Divider(height: 28),
          TankFirmwareTile(ready: session.ready, sensor: sensor),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            onPressed: () => _unpair(context, sensor),
            child: const Text('Unpair this sensor'),
          ),
        ],
      ),
    );
  }
}

/// Confirm a change that deletes [tanks] and their schedules.
Future<bool?> _confirmRemoveTanks(
  BuildContext context,
  PumpSession session, {
  required String title,
  required List<TankSlot> tanks,
  required String action,
  String? lead,
}) {
  final indexes = {for (final t in tanks) t.index};
  final doomed = session.schedules.where((s) => indexes.contains(s.slot));
  final names = tanks.map((t) => _tankName(session, t)).join(', ');
  final lines = [
    ?lead,
    if (tanks.isNotEmpty)
      '$names will be removed, with ${doomed.isEmpty ? 'no schedules' : 'its schedules'}.',
    if (doomed.isNotEmpty)
      doomed
          .map((s) => TimeOfDay(hour: s.hour, minute: s.minute).format(context))
          .join(', '),
  ];
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(lines.join('\n\n')),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action),
        ),
      ],
    ),
  );
}

class _TankPairDialog extends StatelessWidget {
  const _TankPairDialog({required this.session, required this.before});

  final PumpSession session;

  /// Sensor ids paired before the window opened.
  final Set<String> before;

  TankSensor? get _added =>
      session.sensors.where((s) => !before.contains(s.idHex)).firstOrNull;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final added = _added;
        if (added != null && !session.tankPairing) {
          // Every rebuild schedules this; only the first may close the dialog.
          WidgetsBinding.instance.addPostFrameCallback((_) => popSelf(context));
        }
        return AlertDialog(
          title: Text(added != null ? 'Sensor paired' : 'Pairing tank…'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'On the tank sensor, hold the button for about 3 seconds.',
              ),
              const SizedBox(height: 16),
              if (session.tankPairing)
                const LinearProgressIndicator()
              else if (added != null)
                Text('Connected · #${added.shortId}')
              else
                const Text('Pairing closed.'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => popSelf(context),
              child: Text(
                added != null
                    ? 'Done'
                    : session.tankPairing
                    ? 'Cancel'
                    : 'Close',
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Settings row text for the sensors entry.
String tankSensorsSummary(PumpSession session) {
  final sensors = session.sensors;
  if (sensors.isEmpty) return 'Not paired';
  if (sensors.length == 1 && !session.multiTank) {
    return _modeLabel(sensors.first.mode);
  }
  final away = sensors.where((s) => !session.sensorOnline(s)).length;
  final count = sensors.length == 1 ? '1 sensor' : '${sensors.length} sensors';
  final tanks = '${session.tanks.length} tanks';
  return [
    count,
    tanks,
    if (away > 0) '$away out of range',
    if (session.multiTank) 'filling ${session.activeTankName}',
  ].join(' · ');
}

/// Battery level, and the solar trend from the pump's daily log.
class _BatteryTile extends StatelessWidget {
  const _BatteryTile({required this.session, required this.sensor});

  final PumpSession session;
  final TankSensor sensor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final online = session.sensorOnline(sensor);
    final low = session.sensorBatteryLow(sensor);
    final outlook = session.batteryOutlook(sensor);
    final days = session.batteryLogs[sensor.index] ?? const [];
    final String detail;
    if (outlook.trend == BatteryTrend.unknown) {
      detail = 'The trend shows after a few days of readings.';
    } else {
      final first = days.first.minPct;
      final last = days.last.minPct;
      detail =
          'Lowest each day, last ${days.length} days: $first% → $last%. '
          'It charges from the solar panel.';
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        low ? Icons.battery_alert_rounded : Icons.battery_std_rounded,
        color: low || solarFallingBehind(outlook)
            ? scheme.error
            : scheme.primary,
      ),
      title: Text(
        !online
            ? 'Battery · last ${sensor.batteryPct}%'
            : 'Battery ${sensor.batteryPct}% · '
                  '${batteryHint(sensor.batteryPct, low: low, outlook: outlook)}',
      ),
      subtitle: Text(detail),
    );
  }
}
