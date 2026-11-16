import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ble/pump_session.dart';
import '../ble/tanklink_uuids.dart';

class SchedulesScreen extends StatefulWidget {
  const SchedulesScreen({super.key});

  @override
  State<SchedulesScreen> createState() => _SchedulesScreenState();
}

class _SchedulesScreenState extends State<SchedulesScreen> {
  var _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final session = context.read<PumpSession>();
      if (session.authed && session.schedulesSupported) {
        session.syncPumpClock();
      }
    });
  }

  Future<void> _save(List<FillSchedule> next) async {
    setState(() => _busy = true);
    try {
      await context.read<PumpSession>().replaceFillSchedules(next);
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().replaceFirst('StateError: ', '');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickTime({FillSchedule? existing, int? index}) async {
    final session = context.read<PumpSession>();
    final initial = existing == null
        ? const TimeOfDay(hour: 6, minute: 0)
        : TimeOfDay(hour: existing.hour, minute: existing.minute);
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null || !mounted) return;
    var slot = existing?.slot ?? session.activeSlot;
    if (session.twoTankMode) {
      final chosen = await showDialog<int>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('Which tank?'),
          children: [
            for (final tank in session.tanks)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, tank.index),
                child: Text(
                  tank.name.isEmpty ? session.tankNameFor(tank.index) : tank.name,
                ),
              ),
          ],
        ),
      );
      if (chosen == null || !mounted) return;
      slot = chosen;
    }
    final next = [...session.schedules];
    final entry = FillSchedule(
      enabled: existing?.enabled ?? true,
      hour: picked.hour,
      minute: picked.minute,
      slot: slot,
    );
    if (index == null) {
      next.add(entry);
    } else {
      next[index] = entry;
    }
    await _save(next);
  }

  String _clockLine(PumpSession session) {
    if (!session.schedulesSupported) {
      return 'This pump firmware does not support schedules yet.';
    }
    if (!session.pumpClockValid) {
      return 'Connect to set the pump clock';
    }
    final t = TimeOfDay(
      hour: session.pumpClockHour,
      minute: session.pumpClockMinute,
    );
    return 'Phone time sent · pump clock ${t.format(context)}';
  }

  String _stopLine(PumpSession session) {
    if (session.autoOffMin <= 0) {
      final base =
          'Auto-off is off. A scheduled fill stops when the tank is full or you stop the pump.';
      if (!session.twoTankMode) return base;
      return '$base Set the lever to that tank before the time. A fill does not switch tanks if the pump is already running.';
    }
    final m = session.autoOffMin;
    final label = m < 60
        ? '$m min'
        : '${m ~/ 60}h${m % 60 == 0 ? '' : ' ${m % 60}m'}';
    final base = 'Runs every day at these times. Stops when the tank is full or after $label.';
    if (!session.twoTankMode) return base;
    return '$base Set the lever to that tank before the time. A fill does not switch tanks if the pump is already running.';
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final scheme = Theme.of(context).colorScheme;
    final ready = session.authed && session.connected;
    final canAdd = ready &&
        session.schedulesSupported &&
        session.schedules.length < TankLinkUuids.schedMax &&
        !_busy;

    return Scaffold(
      appBar: AppBar(title: const Text('Schedules')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          Text(
            _clockLine(session),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            _stopLine(session),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.35,
                ),
          ),
          const SizedBox(height: 16),
          if (!session.schedulesSupported)
            const SizedBox.shrink()
          else if (session.schedules.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Text(
                'No fill times yet. Add a time and the pump will start at that time every day.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            )
          else
            for (var i = 0; i < session.schedules.length; i++)
              _ScheduleTile(
                schedule: session.schedules[i],
                tankName: session.twoTankMode
                    ? session.tankNameFor(session.schedules[i].slot)
                    : null,
                enabled: ready && !_busy,
                onToggle: (on) {
                  final next = [...session.schedules];
                  next[i] = next[i].copyWith(enabled: on);
                  _save(next);
                },
                onEdit: () => _pickTime(existing: session.schedules[i], index: i),
                onDelete: () {
                  final next = [...session.schedules]..removeAt(i);
                  _save(next);
                },
              ),
          const SizedBox(height: 12),
          if (session.schedulesSupported)
            FilledButton.icon(
              onPressed: canAdd ? () => _pickTime() : null,
              icon: const Icon(Icons.add_rounded),
              label: Text(
                session.schedules.length >= TankLinkUuids.schedMax
                    ? 'Four times is the limit'
                    : 'Add fill time',
              ),
            ),
        ],
      ),
    );
  }
}

class _ScheduleTile extends StatelessWidget {
  const _ScheduleTile({
    required this.schedule,
    required this.enabled,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    this.tankName,
  });

  final FillSchedule schedule;
  final String? tankName;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final label = TimeOfDay(
      hour: schedule.hour,
      minute: schedule.minute,
    ).format(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: enabled,
      onTap: enabled ? onEdit : null,
      title: Text(
        label,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
      ),
      subtitle: Text(
        tankName == null
            ? (schedule.enabled ? 'Every day' : 'Paused')
            : '$tankName · ${schedule.enabled ? 'Every day' : 'Paused'}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: schedule.enabled,
            onChanged: enabled ? onToggle : null,
          ),
          IconButton(
            tooltip: 'Remove',
            onPressed: enabled ? onDelete : null,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
    );
  }
}
