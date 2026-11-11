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
                ? 'Saved · two-button · $_draftPulseMs ms'
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
            'How TankLink drives the pump motor starter. Pick the profile that '
            'matches your panel, then confirm.',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
          ),
          const SizedBox(height: 16),
          _StarterOption(
            selected: _draftType == TankLinkUuids.starterNone,
            title: 'Not configured',
            subtitle: 'App on/off only — no relay pulses',
            onTap: _saving
                ? null
                : () => setState(() => _draftType = TankLinkUuids.starterNone),
          ),
          _StarterOption(
            selected: twoButton,
            title: 'Two-button starter',
            subtitle: 'Momentary Start + Stop via two relays',
            onTap: _saving
                ? null
                : () => setState(
                      () => _draftType = TankLinkUuids.starterTwoButton,
                    ),
          ),
          if (twoButton) ...[
            const SizedBox(height: 12),
            Text(
              'Pulse length',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'How long Start/Stop relays stay closed. Increase if the '
              'contactor doesn’t pick up; decrease if a short press is enough.',
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
              'Wiring',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 6),
            Text(
              'On a typical direct-on-line panel, Start is normally open '
              '(open until pressed) and Stop is normally closed (closed until '
              'pressed), with a holding contact across Start. TankLink only '
              'mimics those two buttons.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 12),
            _WiringCard(
              title: 'Relay A — START',
              body: 'Use a dry-contact pair that is normally open '
                  '(open when the relay is off).\n\n'
                  'Wire those contacts in parallel with the panel’s Start '
                  'pushbutton (across the same two Start terminals).\n\n'
                  'Closing Relay A is the same as pressing Start. The '
                  'existing holding contact still seals the contactor in '
                  'after the pulse ends.',
            ),
            const SizedBox(height: 10),
            _WiringCard(
              title: 'Relay B — STOP',
              body: 'Use a dry-contact pair that is normally closed '
                  '(closed when the relay is off). Many changeover relays '
                  'provide this; a module with only normally-open contacts '
                  'will not work for Stop.\n\n'
                  'Wire those normally-closed contacts in series with the '
                  'panel’s Stop pushbutton (same control loop that feeds '
                  'the coil).\n\n'
                  'At rest the relay is off, the contacts stay closed, and '
                  'the circuit can run. Turning Relay B on opens those '
                  'contacts — same as pressing Stop.\n\n'
                  'Do not put normally-open contacts of Relay B in series: '
                  'at rest they would be open and the starter could never '
                  'seal in. Do not wire Relay B across / parallel to the '
                  'Stop button — that cannot open a normally-closed Stop '
                  'path.',
            ),
            const SizedBox(height: 10),
            _WiringCard(
              title: 'Control behaviour',
              body: 'On → short pulse on Relay A (Start).\n'
                  'Off → short pulse on Relay B (Stop).\n'
                  'Boot / reboot → Stop is pulsed first for safety.\n'
                  'Firmware update, pairing, and unpair also force Stop and '
                  'block Start.\n\n'
                  'Relay pins are not assigned on this firmware build yet '
                  '(placeholders). Choosing this profile stores the type in '
                  'the pump so it matches when the board pins are wired.',
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.errorContainer.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                'Mains / motor control is hazardous. Isolate power before '
                'wiring. Keep TankLink on the low-voltage control side with '
                'dry contacts only — never switch the motor mains through '
                'the TankLink board.',
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
