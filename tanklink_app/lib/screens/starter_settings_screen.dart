import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ble/pump_session.dart';
import '../ble/tanklink_uuids.dart';

class StarterSettingsScreen extends StatefulWidget {
  const StarterSettingsScreen({super.key});

  @override
  State<StarterSettingsScreen> createState() => _StarterSettingsScreenState();
}

class _StarterSettingsScreenState extends State<StarterSettingsScreen> {
  late int _draftType;
  late int _draftPulseMs;
  bool _hydrated = false;
  bool _saving = false;

  void _hydrate(PumpSession session) {
    if (_hydrated) return;
    _draftType = session.starterType;
    _draftPulseMs = session.relayPulseMs.clamp(
      TankLinkUuids.relayPulseMsMin,
      TankLinkUuids.relayPulseMsMax,
    );
    _hydrated = true;
  }

  Future<void> _confirm() async {
    final session = context.read<PumpSession>();
    final dirty = _draftType != session.starterType ||
        _draftPulseMs != session.relayPulseMs;
    if (!dirty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _saving = true);
    try {
      await session.setStarterConfig(
        type: _draftType,
        pulseMs: _draftPulseMs,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _draftType == TankLinkUuids.starterTwoButton
                ? 'Saved · Start and Stop · $_draftPulseMs ms'
                : 'Saved · starter not configured',
          ),
        ),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Couldn’t save starter: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final session = context.watch<PumpSession>();
    _hydrate(session);
    final dirty = _draftType != session.starterType ||
        _draftPulseMs != session.relayPulseMs;
    final twoButton = _draftType == TankLinkUuids.starterTwoButton;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Starter'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          Text(
            'How the app turns the pump motor on and off. Pick the option that '
            'matches your panel, then confirm.',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
          ),
          const SizedBox(height: 16),
          _StarterOption(
            selected: _draftType == TankLinkUuids.starterNone,
            title: 'Not configured',
            subtitle: 'App on/off only',
            onTap: _saving
                ? null
                : () => setState(() => _draftType = TankLinkUuids.starterNone),
          ),
          _StarterOption(
            selected: twoButton,
            title: 'Two-button starter',
            subtitle: 'Presses the Start and Stop buttons',
            onTap: _saving
                ? null
                : () => setState(
                      () => _draftType = TankLinkUuids.starterTwoButton,
                    ),
          ),
          if (twoButton) ...[
            const SizedBox(height: 12),
            Text(
              'Press length',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'How long each button press lasts. Increase it if the motor does '
              'not switch on; decrease it if a short press is enough.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    min: TankLinkUuids.relayPulseMsMin.toDouble(),
                    max: TankLinkUuids.relayPulseMsMax.toDouble(),
                    divisions: (TankLinkUuids.relayPulseMsMax -
                            TankLinkUuids.relayPulseMsMin) ~/
                        50,
                    value: _draftPulseMs.toDouble(),
                    label: '$_draftPulseMs ms',
                    onChanged: _saving
                        ? null
                        : (v) => setState(
                              () => _draftPulseMs = (v / 50).round() * 50,
                            ),
                  ),
                ),
                SizedBox(
                  width: 72,
                  child: Text(
                    '$_draftPulseMs ms',
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('50 ms',
                      style: TextStyle(
                          color: scheme.onSurfaceVariant, fontSize: 12)),
                  Text('2 s',
                      style: TextStyle(
                          color: scheme.onSurfaceVariant, fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Wiring help',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 6),
            Text(
              'On a common motor panel, Start is open until pressed and Stop is '
              'closed until pressed. A holding contact keeps the motor running '
              'after Start is let go. The app only presses those two buttons for you.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 12),
            _WiringCard(
              title: 'Start connection',
              body: 'Use a switch that is open when the app is not pressing it.\n\n'
                  'Wire it across the same two terminals as the panel’s Start button.\n\n'
                  'When the app presses Start, the switch closes, just like pushing '
                  'the button. The panel’s holding contact keeps the motor running '
                  'after the press ends.',
            ),
            const SizedBox(height: 10),
            _WiringCard(
              title: 'Stop connection',
              body: 'Use a switch that is closed when the app is not pressing it. '
                  'Some two-way switches work this way; a switch that is only open '
                  'when idle will not work for Stop.\n\n'
                  'Wire it in series with the panel’s Stop button, so it can open '
                  'the same circuit.\n\n'
                  'When the app is not pressing Stop, the switch stays closed and the '
                  'motor can run. When the app presses Stop, the switch opens, just '
                  'like pushing the button.\n\n'
                  'Do not wire it in a way that is open when idle, or the motor could '
                  'never keep running. Do not wire it in parallel with the Stop button.',
            ),
            const SizedBox(height: 10),
            _WiringCard(
              title: 'How it works',
              body: 'Turn on → the app presses Start.\n'
                  'Turn off → the app presses Stop.\n'
                  'When the pump restarts → it presses Stop first, for safety.\n'
                  'During an update or setup → the pump stops and will not start.\n\n'
                  'The pump pins for these connections are not set up in this version yet. '
                  'Choosing this option saves it on the pump for later.',
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.errorContainer.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                'Working with motor power is dangerous. Turn off the power before '
                'wiring. Only connect the low-voltage control side, and never run '
                'the motor’s power through the TankLink board.',
                style: TextStyle(
                  color: scheme.onErrorContainer,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: FilledButton(
          onPressed: _saving ? null : _confirm,
          child: _saving
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(dirty ? 'Confirm & save' : 'Done'),
        ),
      ),
    );
  }
}

class _StarterOption extends StatelessWidget {
  const _StarterOption({
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? scheme.primaryContainer.withValues(alpha: 0.55)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color: selected ? scheme.primary : scheme.outlineVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WiringCard extends StatelessWidget {
  const _WiringCard({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
