import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../ble/protocol.dart';
import '../../ble/pump_session.dart';
import '../../ble/tanklink_uuids.dart';
import '../../util/format.dart';
import '../../util/snack.dart';
import '../../util/haptics.dart';

/// Names of the pump's buzzer sounds, by TankLinkUuids.buzzSound*.
const buzzSoundNames = [
  ('Click', 'Short click'),
  ('Tick', 'Very short, the quietest'),
  ('Long', 'One long beep'),
  ('Double', 'Two short beeps'),
  ('Triple', 'Three short beeps'),
  ('Rising', 'Two short, then long'),
  ('Falling', 'Long, then short'),
  ('Chirp', 'Four fast ticks'),
  ('Alarm', 'Six urgent beeps'),
];

/// Short summary for the settings list.
String buzzerSummary(BuzzerConfig? b) {
  if (b == null) return 'Loading…';
  if (!b.enabled) return 'Off';
  final n = [
    for (var e = 0; e < TankLinkUuids.buzzEventCount; e++)
      if (b.on(e)) e,
  ].length;
  final quiet = b.quiet
      ? ' · quiet ${formatClock(b.quietStart)}–${formatClock(b.quietEnd)}'
      : '';
  return 'On · $n of ${TankLinkUuids.buzzEventCount} sounds$quiet';
}

/// (event, title, when it sounds), grouped.
const _groups = [
  (
    'At the pump',
    [
      (
        TankLinkUuids.buzzEventButton,
        'Button',
        'A press, and the beep at 1 second when the pump can start',
      ),
      (
        TankLinkUuids.buzzEventDenied,
        'Start refused',
        'The pump can\'t start: tank full, not added to a phone, an update',
      ),
    ],
  ),
  (
    'Pump',
    [
      (TankLinkUuids.buzzEventPumpStart, 'Started from the app', null),
      (
        TankLinkUuids.buzzEventPumpStop,
        'Stopped from the app',
        'Also when pairing or an update stops it',
      ),
      (TankLinkUuids.buzzEventSchedule, 'Schedule starts a fill', null),
      (
        TankLinkUuids.buzzEventAutoFill,
        'Auto-fill',
        'Starts a fill, or stops one when its allowed time ends',
      ),
      (
        TankLinkUuids.buzzEventTankFull,
        'Tank full',
        'The tank filled and the pump stopped',
      ),
      (
        TankLinkUuids.buzzEventAutoOff,
        'Auto-off',
        'The timer stopped the pump',
      ),
    ],
  ),
  (
    'Warnings',
    [
      (
        TankLinkUuids.buzzEventAlert,
        'Alerts',
        'Power cut, tank offline, battery low, sensor removed',
      ),
    ],
  ),
  (
    'Other',
    [
      (
        TankLinkUuids.buzzEventPairing,
        'Pairing',
        'Pairing opens, or a phone or tank sensor is added',
      ),
      (
        TankLinkUuids.buzzEventPhone,
        'Phone connects',
        'Each time a phone signs in to the pump',
      ),
      (TankLinkUuids.buzzEventPowerUp, 'Power on', 'When the pump starts up'),
    ],
  ),
];

class BuzzerScreen extends StatelessWidget {
  const BuzzerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final b = session.buzzer;
    return Scaffold(
      appBar: AppBar(title: const Text('Buzzer')),
      body: !session.ready || b == null
          ? const Center(
              child: Text('Connect to the pump to change the buzzer'),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Buzzer',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    b.enabled ? 'Sounds on the pump' : 'Every sound is off',
                  ),
                  value: b.enabled,
                  onChanged: Haptics.toggle(
                    (v) => runOrSnack(
                      context,
                      () => session.setBuzzer(b.copyWith(enabled: v)),
                    ),
                  ),
                ),
                IgnorePointer(
                  ignoring: !b.enabled,
                  child: Opacity(
                    opacity: b.enabled ? 1 : 0.45,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (title, events) in _groups) ...[
                          const SizedBox(height: 12),
                          _SectionTitle(title),
                          for (final (event, name, hint) in events)
                            _EventRow(
                              config: b,
                              event: event,
                              title: name,
                              hint: hint,
                            ),
                        ],
                        const SizedBox(height: 12),
                        const _SectionTitle('Quiet hours'),
                        _QuietHours(config: b),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.titleSmall?.copyWith(
      color: Theme.of(context).colorScheme.primary,
      fontWeight: FontWeight.w600,
    ),
  );
}

class _EventRow extends StatelessWidget {
  const _EventRow({
    required this.config,
    required this.event,
    required this.title,
    required this.hint,
  });

  final BuzzerConfig config;
  final int event;
  final String title;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final session = context.read<PumpSession>();
    final scheme = Theme.of(context).colorScheme;
    final on = config.on(event);
    final sound = buzzSoundNames[config.soundFor(event)].$1;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(
        hint == null ? 'Sound: $sound' : '$hint\nSound: $sound',
        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
      ),
      isThreeLine: hint != null,
      onTap: () => _pickSound(context, session, event, title),
      trailing: Switch(
        value: on,
        onChanged: Haptics.toggle(
          (v) => runOrSnack(
            context,
            () => session.setBuzzer(config.withEvent(event, v)),
          ),
        ),
      ),
    );
  }
}

/// Choose the sound for [event]; each tap plays it on the pump.
Future<void> _pickSound(
  BuildContext context,
  PumpSession session,
  int event,
  String title,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => Consumer<PumpSession>(
      builder: (ctx, s, _) {
        final cur = s.buzzer;
        if (cur == null) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 32),
            child: Text('Connect to the pump to change sounds'),
          );
        }
        final scheme = Theme.of(ctx).colorScheme;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Sound for $title',
                style: Theme.of(ctx).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'Tap a sound to hear it on the pump.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              for (var i = 0; i < buzzSoundNames.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Material(
                    color: cur.soundFor(event) == i
                        ? scheme.primaryContainer.withValues(alpha: 0.6)
                        : scheme.surfaceContainerHighest.withValues(
                            alpha: 0.45,
                          ),
                    borderRadius: BorderRadius.circular(14),
                    child: ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      title: Text(
                        buzzSoundNames[i].$1,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(buzzSoundNames[i].$2),
                      trailing: Icon(
                        cur.soundFor(event) == i
                            ? Icons.check_circle_rounded
                            : Icons.play_circle_outline_rounded,
                        color: cur.soundFor(event) == i
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                      onTap: () => runOrSnack(ctx, () async {
                        await s.testSound(i);
                        if (cur.soundFor(event) != i) {
                          await s.setBuzzer(cur.withSound(event, i));
                        }
                      }),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
}

class _QuietHours extends StatelessWidget {
  const _QuietHours({required this.config});

  final BuzzerConfig config;

  @override
  Widget build(BuildContext context) {
    final session = context.read<PumpSession>();
    final scheme = Theme.of(context).colorScheme;
    final b = config;

    Future<void> pick(bool start) async {
      final cur = start ? b.quietStart : b.quietEnd;
      final t = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(hour: cur ~/ 60, minute: cur % 60),
      );
      if (t == null || !context.mounted) return;
      final m = t.hour * 60 + t.minute;
      final other = start ? b.quietEnd : b.quietStart;
      if (m == other) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Start and end must differ')),
        );
        return;
      }
      await runOrSnack(
        context,
        () => session.setBuzzer(
          start ? b.copyWith(quietStart: m) : b.copyWith(quietEnd: m),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Quiet hours'),
          subtitle: Text(
            b.quiet
                ? 'No sounds ${windowLabel(b.quietStart, b.quietEnd)}'
                : 'Off',
          ),
          value: b.quiet,
          onChanged: Haptics.toggle(
            (v) => runOrSnack(
              context,
              () => session.setBuzzer(b.copyWith(quiet: v)),
            ),
          ),
        ),
        if (b.quiet) ...[
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => pick(true),
                  child: Text('From ${formatClock(b.quietStart)}'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => pick(false),
                  child: Text('To ${formatClock(b.quietEnd)}'),
                ),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Button still sounds'),
            subtitle: const Text(
              'Someone at the pump hears the button and "start refused"',
            ),
            value: b.quietButton,
            onChanged: Haptics.toggle(
              (v) => runOrSnack(
                context,
                () => session.setBuzzer(b.copyWith(quietButton: v)),
              ),
            ),
          ),
          Text(
            session.pumpClockValid
                ? 'Uses the pump\'s clock.'
                : 'The pump does not know the time yet, so sounds still '
                      'play. The app sets it when it connects.',
            style: TextStyle(
              color: session.pumpClockValid
                  ? scheme.onSurfaceVariant
                  : scheme.error,
              fontSize: 13,
            ),
          ),
        ],
      ],
    );
  }
}
