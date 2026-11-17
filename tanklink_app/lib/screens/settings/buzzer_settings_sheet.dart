import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ble/pump_session.dart';

class BuzzerSettingsSheet extends StatelessWidget {
  const BuzzerSettingsSheet({super.key});

  static const _tones = [
    (0, 'Click', 'Short tick'),
    (1, 'Soft', 'Very short'),
    (2, 'Sharp', 'Long beep'),
    (3, 'Double', 'Two ticks'),
  ];

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final scheme = Theme.of(context).colorScheme;
    final enabled = session.buzzerEnabled;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Buzzer',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Buzzer on'),
              subtitle: Text(
                enabled ? 'Sounds enabled on the pump' : 'All beeps muted',
              ),
              value: enabled,
              onChanged: (v) => session.setBuzzerSettings(enabled: v),
            ),
            const Divider(height: 24),
            IgnorePointer(
              ignoring: !enabled,
              child: Opacity(
                opacity: enabled ? 1 : 0.45,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('On button press'),
                      subtitle: const Text('Short press on the pump'),
                      value: session.buzzOnButton,
                      onChanged: (v) => session.setBuzzerSettings(onButton: v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('On pump on/off'),
                      subtitle: const Text(
                        'When started or stopped from the app',
                      ),
                      value: session.buzzOnPump,
                      onChanged: (v) => session.setBuzzerSettings(onPump: v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('On auto-off'),
                      subtitle: const Text('When the timer stops the pump'),
                      value: session.buzzOnAutoOff,
                      onChanged: (v) => session.setBuzzerSettings(onAutoOff: v),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Tone',
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 8),
                    for (final t in _tones)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Material(
                          color: session.buzzerTone == t.$1
                              ? scheme.primaryContainer.withValues(alpha: 0.55)
                              : scheme.surfaceContainerHighest.withValues(
                                  alpha: 0.45,
                                ),
                          borderRadius: BorderRadius.circular(14),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () async {
                              await session.setBuzzerSettings(tone: t.$1);
                              await session.testBuzzer();
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          t.$2,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 16,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          t.$3,
                                          style: TextStyle(
                                            color: scheme.onSurfaceVariant,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  // Selection via background only — no check icon wrap.
                                  Container(
                                    width: 10,
                                    height: 10,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: session.buzzerTone == t.$1
                                          ? scheme.primary
                                          : scheme.outlineVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 4),
                    OutlinedButton.icon(
                      onPressed: () => session.testBuzzer(),
                      icon: const Icon(Icons.notifications_active_outlined),
                      label: const Text('Test buzzer'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
