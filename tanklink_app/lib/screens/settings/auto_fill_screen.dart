import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../ble/protocol.dart';
import '../../ble/pump_session.dart';
import '../../ble/tanklink_uuids.dart';
import '../../util/format.dart';
import '../../util/snack.dart';
import '../../util/haptics.dart';

/// Auto-fill: which tanks fill themselves, when they may, and what it is
/// doing right now.
class AutoFillScreen extends StatelessWidget {
  const AutoFillScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final info = session.autoFill;
    return Scaffold(
      appBar: AppBar(title: const Text('Auto-fill')),
      body: !session.ready || info == null
          ? const Center(child: Text('Connect to the pump to change auto-fill'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _StatusCard(session: session, info: info),
                if (session.multiTank) ...[
                  const SizedBox(height: 12),
                  _LeverWarning(session: session),
                ],
                const SizedBox(height: 20),
                const _SectionTitle('Tank'),
                if (session.multiTank)
                  Text(
                    'One tank per pump. It only fills while that tank is '
                    'selected.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                for (final t in session.tanks)
                  _TankRow(session: session, slot: t.index),
                const SizedBox(height: 20),
                const _SectionTitle('Allowed times'),
                _TimesSection(session: session, info: info),
                const SizedBox(height: 20),
                const _SectionTitle('Wait between fills'),
                _GapSection(session: session, info: info),
                const SizedBox(height: 20),
                const _HowItWorks(),
              ],
            ),
    );
  }
}

/// Turn auto-fill on or off for [slot]. Only one tank per pump may use it, so
/// turning it on for a second tank asks before moving it.
Future<void> setAutoFillFor(
  BuildContext context,
  PumpSession session,
  int slot,
  bool on,
) async {
  final other = session.autoFillTank;
  if (on && other != null && other.index != slot) {
    final from = session.tankNameFor(other.index);
    final to = session.tankNameFor(slot);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Move auto-fill to $to?'),
        content: Text(
          'Only one tank per pump can use auto-fill. It will be turned off '
          'for $from.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Move'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
  }
  await runOrSnack(context, () => session.setAutoFill(slot, on));
}

/// Write auto-fill's pump-wide settings, changing only what is given.
Future<void> _save(
  BuildContext context,
  AutoFillInfo info, {
  bool? limitTimes,
  bool? stopAtEnd,
  int? gapMin,
  List<DayWindow>? windows,
}) => runOrSnack(
  context,
  () => context.read<PumpSession>().setAutoFillConfig(
    limitTimes: limitTimes ?? info.limitTimes,
    stopAtEnd: stopAtEnd ?? info.stopAtEnd,
    gapMin: gapMin ?? info.gapMin,
    windows: windows ?? info.windows,
  ),
);

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.session, required this.info});

  final PumpSession session;
  final AutoFillInfo info;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tank = session.tankNameFor(info.slot);
    final low = session.hasEmptyFloat(info.slot)
        ? 'the almost-empty float'
        : 'the full float';
    final wait = info.waitMin;
    final (
      IconData icon,
      Color color,
      String title,
      String body,
    ) = switch (info.state) {
      TankLinkUuids.afStateOff => (
        Icons.water_drop_outlined,
        scheme.onSurfaceVariant,
        'Auto-fill is off',
        'Turn it on for a tank below.',
      ),
      TankLinkUuids.afStateOffline => (
        Icons.sensors_off_rounded,
        scheme.error,
        '$tank sensor is offline',
        'Auto-fill waits until the sensor is heard again.',
      ),
      TankLinkUuids.afStateWatching => (
        Icons.visibility_outlined,
        scheme.primary,
        'Watching $tank',
        'Starts when the water drops below $low.',
      ),
      TankLinkUuids.afStateWaitArm => (
        Icons.hourglass_empty_rounded,
        scheme.tertiary,
        '$tank is already low',
        'It fills after the tank is next seen above $low. '
            'Tap Fill now to start as soon as it is allowed.',
      ),
      TankLinkUuids.afStateWaitTime => (
        Icons.schedule_rounded,
        scheme.tertiary,
        'Waiting for an allowed time',
        wait == null
            ? 'No allowed time is on, so it will not start.'
            : '$tank is low. It can start in ${formatWait(wait)}.',
      ),
      TankLinkUuids.afStateNoClock => (
        Icons.history_toggle_off_rounded,
        scheme.error,
        'The pump does not know the time',
        'Allowed times need the clock. The app sets it when it connects.',
      ),
      TankLinkUuids.afStateCooldown => (
        Icons.timelapse_rounded,
        scheme.tertiary,
        'Waiting between fills',
        '$tank is low. It can start in '
            '${formatWait(wait!)}.',
      ),
      TankLinkUuids.afStatePaused => (
        Icons.pause_circle_outline_rounded,
        scheme.error,
        'Paused',
        'The last auto-fill stopped before the tank was full (auto-off, '
            'or stopped by hand). It carries on once the tank is full '
            'again, or tap Resume.',
      ),
      TankLinkUuids.afStateFilling => (
        Icons.water_rounded,
        scheme.primary,
        'Filling $tank',
        info.limitTimes && info.stopAtEnd
            ? 'Stops when it is full, at auto-off, or when the allowed '
                  'time ends.'
            : 'Stops when it is full or at auto-off.',
      ),
      TankLinkUuids.afStateBusy => (
        Icons.sync_rounded,
        scheme.tertiary,
        'Waiting for pairing or an update',
        '$tank is low. It starts when that is over.',
      ),
      TankLinkUuids.afStatePumpOn => (
        Icons.water_rounded,
        scheme.tertiary,
        'The pump is already running',
        'Another fill is running. Auto-fill waits until it stops.',
      ),
      TankLinkUuids.afStateNotSelected => (
        Icons.alt_route_rounded,
        scheme.tertiary,
        'Waiting for $tank to be selected',
        'Auto-fill only fills $tank while it is the selected tank. Select it '
            'when the valve or lever is set to it.',
      ),
      _ => throw StateError('auto-fill state ${info.state}'),
    };
    final String? action = switch (info.state) {
      TankLinkUuids.afStateWaitArm => 'Fill now',
      TankLinkUuids.afStatePaused => 'Resume',
      TankLinkUuids.afStateNotSelected => 'Select $tank',
      _ => null,
    };
    final notSelected = info.state == TankLinkUuids.afStateNotSelected;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(body, style: TextStyle(color: scheme.onSurfaceVariant)),
          if (action != null) ...[
            const SizedBox(height: 10),
            FilledButton.tonal(
              onPressed: notSelected && session.pumpOn
                  ? null
                  : () => runOrSnack(
                      context,
                      notSelected
                          ? () => session.selectTank(info.slot)
                          : session.armAutoFill,
                    ),
              child: Text(action),
            ),
          ],
        ],
      ),
    );
  }
}

class _LeverWarning extends StatelessWidget {
  const _LeverWarning({required this.session});

  final PumpSession session;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, color: scheme.error),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Auto-fill only runs while the auto-fill tank is selected. '
                  'Select the tank the valve or lever is set to, or the water '
                  'may go into another tank.',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Valve or lever is set to',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final t in session.tanks)
                ChoiceChip(
                  label: Text(session.tankNameFor(t.index)),
                  selected: t.index == session.activeSlot,
                  onSelected: Haptics.pick(
                    session.pumpOn && t.index != session.activeSlot
                        ? null
                        : (_) {
                            if (t.index == session.activeSlot) return;
                            runOrSnack(
                              context,
                              () => session.selectTank(t.index),
                            );
                          },
                  ),
                ),
            ],
          ),
          if (session.pumpOn) ...[
            const SizedBox(height: 4),
            Text(
              'Stop the pump to change it.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }
}

class _TankRow extends StatelessWidget {
  const _TankRow({required this.session, required this.slot});

  final PumpSession session;
  final int slot;

  @override
  Widget build(BuildContext context) {
    final t = session.slotAt(slot)!;
    final can = session.canAutoFill(slot);
    final String subtitle;
    if (!can) {
      subtitle = 'Needs a tank sensor';
    } else if (session.hasEmptyFloat(slot)) {
      subtitle = 'Fills when below the almost-empty float';
    } else {
      subtitle = 'Tops up when below the full float';
    }
    final name = t.name.isEmpty ? session.tankNameFor(slot) : t.name;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(name),
      subtitle: Text(
        session.multiTank && can && t.autoFill && slot != session.activeSlot
            ? '$subtitle, once it is selected'
            : subtitle,
      ),
      value: t.autoFill,
      onChanged: Haptics.toggle(
        !can ? null : (v) => setAutoFillFor(context, session, slot, v),
      ),
    );
  }
}

class _TimesSection extends StatelessWidget {
  const _TimesSection({required this.session, required this.info});

  final PumpSession session;
  final AutoFillInfo info;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final anyOn = info.windows.any((w) => w.enabled);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Only at set times'),
          subtitle: Text(
            info.limitTimes
                ? 'Starts only within the times below'
                : 'Starts any time the tank runs low',
          ),
          value: info.limitTimes,
          onChanged: Haptics.toggle((v) => _save(context, info, limitTimes: v)),
        ),
        if (info.limitTimes) ...[
          for (var i = 0; i < info.windows.length; i++)
            _WindowTile(info: info, index: i),
          if (info.windows.length < TankLinkUuids.autoFillWindowMax)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () async {
                  final w = await _editWindow(
                    context,
                    const DayWindow(start: 6 * 60, end: 9 * 60),
                    isNew: true,
                  );
                  if (w != null && context.mounted) {
                    await _save(context, info, windows: [...info.windows, w]);
                  }
                },
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add a time'),
              ),
            ),
          if (!anyOn)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'No time is on, so auto-fill will not start.',
                style: TextStyle(color: scheme.error),
              ),
            ),
          if (!session.pumpClockValid)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'The pump does not know the time yet, so it waits.',
                style: TextStyle(color: scheme.error),
              ),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Stop when the time ends'),
            subtitle: Text(
              info.stopAtEnd
                  ? 'An auto-fill stops at the end of its time and carries '
                        'on in the next one'
                  : 'An auto-fill that started in time runs until the tank '
                        'is full',
            ),
            value: info.stopAtEnd,
            onChanged: Haptics.toggle(
              (v) => _save(context, info, stopAtEnd: v),
            ),
          ),
        ],
      ],
    );
  }
}

class _WindowTile extends StatelessWidget {
  const _WindowTile({required this.info, required this.index});

  final AutoFillInfo info;
  final int index;

  @override
  Widget build(BuildContext context) {
    final w = info.windows[index];
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      child: ListTile(
        title: Text(
          windowLabel(w.start, w.end),
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: w.enabled ? null : scheme.onSurfaceVariant,
          ),
        ),
        subtitle: Text(daysLabel(w.days)),
        onTap: () async {
          final edited = await _editWindow(context, w);
          if (!context.mounted || edited == null) return;
          final next = [...info.windows];
          if (identical(edited, _deleted)) {
            next.removeAt(index);
          } else {
            next[index] = edited;
          }
          await _save(context, info, windows: next);
        },
        trailing: Switch(
          value: w.enabled,
          onChanged: Haptics.toggle((v) {
            final next = [...info.windows];
            next[index] = w.copyWith(enabled: v);
            _save(context, info, windows: next);
          }),
        ),
      ),
    );
  }
}

/// Returned by [_editWindow] when the window is to be removed.
const _deleted = DayWindow(start: 0, end: 0, days: 0);

/// Edit [initial] in a dialog: the new window, [_deleted], or null (cancel).
Future<DayWindow?> _editWindow(
  BuildContext context,
  DayWindow initial, {
  bool isNew = false,
}) {
  var w = initial;
  return showDialog<DayWindow>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        Future<void> pick(bool start) async {
          final cur = start ? w.start : w.end;
          final t = await showTimePicker(
            context: ctx,
            initialTime: TimeOfDay(hour: cur ~/ 60, minute: cur % 60),
          );
          if (t == null) return;
          final m = t.hour * 60 + t.minute;
          setState(() => w = start ? w.copyWith(start: m) : w.copyWith(end: m));
        }

        final scheme = Theme.of(ctx).colorScheme;
        final String? problem = w.days & DayWindow.allDays == 0
            ? 'Pick at least one day'
            : w.start == w.end
            ? 'Start and end must differ'
            : null;
        return AlertDialog(
          title: Text(isNew ? 'Add a time' : 'Allowed time'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => pick(true),
                      child: Text('From ${formatClock(w.start)}'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => pick(false),
                      child: Text('To ${formatClock(w.end)}'),
                    ),
                  ),
                ],
              ),
              if (w.crossesMidnight)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Runs past midnight, to ${formatClock(w.end)} the next day.',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final (label, days) in const [
                    ('Every day', 0x7f),
                    ('Mon–Fri', 0x1f),
                    ('Sat, Sun', 0x60),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: w.days == days,
                      onSelected: Haptics.pick(
                        (_) => setState(() => w = w.copyWith(days: days)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (var d = 0; d < 7; d++)
                    FilterChip(
                      label: Text(dayShort(d)),
                      selected: w.onDay(d),
                      showCheckmark: false,
                      onSelected: Haptics.pick(
                        (on) => setState(
                          () => w = w.copyWith(
                            days: on ? w.days | (1 << d) : w.days & ~(1 << d),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              if (problem != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(problem, style: TextStyle(color: scheme.error)),
                ),
            ],
          ),
          actions: [
            if (!isNew)
              TextButton(
                onPressed: () => Navigator.pop(ctx, _deleted),
                child: Text('Remove', style: TextStyle(color: scheme.error)),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: problem == null ? () => Navigator.pop(ctx, w) : null,
              child: const Text('Save'),
            ),
          ],
        );
      },
    ),
  );
}

class _GapSection extends StatefulWidget {
  const _GapSection({required this.session, required this.info});

  final PumpSession session;
  final AutoFillInfo info;

  @override
  State<_GapSection> createState() => _GapSectionState();
}

class _GapSectionState extends State<_GapSection> {
  int? _draft; // while dragging

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final gap = _draft ?? widget.info.gapMin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'At least ${formatWait(gap)} after any stop',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),
        Text(
          widget.session.tanks.any(
                (t) =>
                    widget.session.canAutoFill(t.index) &&
                    !widget.session.hasEmptyFloat(t.index),
              )
              ? 'With only a full float, a longer wait lets more water be '
                    'used before each top-up.'
              : 'Keeps a float at the water line from starting the pump '
                    'again and again.',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
        Slider(
          min: TankLinkUuids.autoFillGapMin.toDouble(),
          max: TankLinkUuids.autoFillGapMax.toDouble(),
          divisions:
              (TankLinkUuids.autoFillGapMax - TankLinkUuids.autoFillGapMin) ~/
              5,
          value: gap.toDouble(),
          label: formatWait(gap),
          onChanged: Haptics.slide((v) => setState(() => _draft = v.round())),
          onChangeEnd: (v) async {
            await _save(context, widget.info, gapMin: v.round());
            if (mounted) setState(() => _draft = null);
          },
        ),
      ],
    );
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontSize: 13,
      height: 1.4,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('How it works'),
        Text(
          '• Each fill stops when the tank is full, or at the tank\'s '
          'auto-off.\n'
          '• If an auto-fill stops any other way (auto-off, the app, the '
          'button), auto-fill pauses until the tank is full again, so a dry '
          'source can\'t keep starting the pump.\n'
          '• After a power cut the pump does not start by itself: it waits '
          'for the tank to be seen above its float, or for Fill now.\n'
          '• The sensor must be online. Nothing starts during pairing or an '
          'update.',
          style: style,
        ),
      ],
    );
  }
}
