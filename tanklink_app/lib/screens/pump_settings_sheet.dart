import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../ble/pump_session.dart';
import '../ble/tanklink_uuids.dart';
import '../update/firmware_update_flow.dart';
import '../update/pump_firmware_update.dart';
import '../widgets/ping_pong_indicator.dart';
import 'error_codes_screen.dart';
import 'starter_settings_screen.dart';

Future<void> showPumpSettingsSheet(BuildContext context) {
  // Refresh release metadata when opening settings.
  context.read<PumpFirmwareUpdate>().checkForUpdates(force: true);
  context.read<PumpFirmwareUpdate>().clearSnooze();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _PumpSettingsSheet(),
  );
}

Future<void> showRenamePumpDialog(BuildContext context, SavedPump pump) async {
  final controller = TextEditingController(text: pump.name);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Rename · #${pump.serial}'),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
          labelText: 'Name',
          hintText: 'Kitchen, Roof, Bore…',
        ),
        onSubmitted: (v) => Navigator.pop(ctx, v),
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
  if (name != null && context.mounted) {
    await context.read<PumpSession>().renamePump(pump, name);
  }
}

String _formatAutoOff(int minutes) {
  if (minutes <= 0) return 'Off';
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (m == 0) return h == 1 ? '1 hour' : '$h hours';
  return '${h}h ${m}m';
}

String _buzzerSummary(PumpSession session) {
  if (!session.buzzerEnabled) return 'Off';
  const tones = ['Click', 'Soft', 'Sharp', 'Double'];
  final tone = tones[session.buzzerTone.clamp(0, 3)];
  return 'On · $tone';
}

String _starterSummary(PumpSession session) {
  switch (session.starterType) {
    case TankLinkUuids.starterTwoButton:
      return 'Two-button · ${session.relayPulseMs} ms';
    default:
      return 'Not configured';
  }
}

class _PumpSettingsSheet extends StatefulWidget {
  const _PumpSettingsSheet();

  @override
  State<_PumpSettingsSheet> createState() => _PumpSettingsSheetState();
}

class _PumpSettingsSheetState extends State<_PumpSettingsSheet> {
  static const int _minMinutes = 1;
  static const int _maxMinutes = 240;

  late int _draftMinutes;
  late bool _autoEnabled;
  bool _hydrated = false;

  void _hydrateFromSession(PumpSession session) {
    if (_hydrated) return;
    final v = session.autoOffMin.clamp(0, _maxMinutes);
    _autoEnabled = v > 0;
    _draftMinutes = v > 0 ? v : 30;
    _hydrated = true;
  }

  Future<void> _commitAuto(int minutes) async {
    if (!mounted) return;
    final session = context.read<PumpSession>();
    if (!(session.authed && session.connected)) return;
    // Fire-and-forget so +/- / slider don't disable/rebuild on release.
    await session.setAutoOffMinutes(minutes);
  }

  Future<void> _setAutoEnabled(bool on) async {
    setState(() {
      _autoEnabled = on;
      if (on && _draftMinutes < _minMinutes) {
        _draftMinutes = 30;
      }
    });
    await _commitAuto(on ? _draftMinutes : 0);
  }

  Future<void> _applyDraft(int minutes) async {
    final m = minutes.clamp(_minMinutes, _maxMinutes);
    setState(() {
      _autoEnabled = true;
      _draftMinutes = m;
    });
    await _commitAuto(m);
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final pump = session.selected;
    final scheme = Theme.of(context).colorScheme;
    if (pump == null) {
      return const SizedBox(height: 120, child: Center(child: Text('No pump')));
    }

    _hydrateFromSession(session);

    final ready = session.authed && session.connected;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              pump.displayTitle,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              ready ? 'Connected' : 'Offline',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            _FirmwareTile(ready: ready),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.badge_outlined),
              title: const Text('Serial'),
              subtitle: Text('#${pump.serial}'),
              trailing: IconButton(
                tooltip: 'Copy',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: pump.serial));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Serial copied')),
                    );
                  }
                },
                icon: const Icon(Icons.copy_rounded),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename'),
              subtitle: Text(pump.name),
              onTap: () => showRenamePumpDialog(context, pump),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.volume_up_outlined),
              title: const Text('Buzzer'),
              subtitle: Text(
                ready ? _buzzerSummary(session) : 'Connect to change',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              enabled: ready,
              onTap: !ready
                  ? null
                  : () {
                      showModalBottomSheet<void>(
                        context: context,
                        isScrollControlled: true,
                        showDragHandle: true,
                        builder: (_) => const _BuzzerSettingsSheet(),
                      );
                    },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.electrical_services_outlined),
              title: const Text('Starter'),
              subtitle: Text(
                ready ? _starterSummary(session) : 'Connect to change',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              enabled: ready,
              onTap: !ready
                  ? null
                  : () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const StarterSettingsScreen(),
                        ),
                      );
                    },
            ),
            const SizedBox(height: 4),
            _LedBrightnessTile(ready: ready),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.timer_outlined, color: scheme.onSurfaceVariant),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Auto-off',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        !ready
                            ? 'Connect to change'
                            : _autoEnabled
                                ? 'Stops after ${_formatAutoOff(_draftMinutes)}'
                                : 'Disabled',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _autoEnabled,
                  onChanged: !ready ? null : _setAutoEnabled,
                ),
              ],
            ),
            if (ready && _autoEnabled) ...[
              const SizedBox(height: 8),
              // Indent to match title text (icon 24 + gap 16).
              Padding(
                padding: const EdgeInsets.only(left: 40),
                child: Column(
                  children: [
                    Row(
                      children: [
                        IconButton.filledTonal(
                          tooltip: '−1 min',
                          onPressed: () => _applyDraft(_draftMinutes - 1),
                          icon: const Icon(Icons.remove),
                        ),
                        Expanded(
                          child: Text(
                            _formatAutoOff(_draftMinutes),
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        IconButton.filledTonal(
                          tooltip: '+1 min',
                          onPressed: () => _applyDraft(_draftMinutes + 1),
                          icon: const Icon(Icons.add),
                        ),
                      ],
                    ),
                    Slider(
                      min: _minMinutes.toDouble(),
                      max: _maxMinutes.toDouble(),
                      divisions: _maxMinutes - _minMinutes,
                      value: _draftMinutes
                          .clamp(_minMinutes, _maxMinutes)
                          .toDouble(),
                      label: _formatAutoOff(_draftMinutes),
                      onChanged: (v) {
                        setState(() => _draftMinutes = v.round());
                      },
                      onChangeEnd: (v) => _commitAuto(v.round()),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('1 min',
                              style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 12)),
                          Text('4 h',
                              style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const Divider(height: 28),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.numbers_rounded),
              title: const Text('Error codes'),
              subtitle: const Text('Tank LED blink meanings'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ErrorCodesScreen(),
                  ),
                );
              },
            ),
            const Divider(height: 28),
            Text('Tank sensor', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (ready) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(session.tankBound
                    ? 'Paired · ${session.tankIdHex.length >= 4 ? session.tankIdHex.substring(session.tankIdHex.length - 4).toUpperCase() : "----"}'
                    : (session.tankPairing ? 'Waiting for tank…' : 'Not paired')),
                subtitle: Text(session.tankBound
                    ? 'FW ${session.tankFw.isEmpty ? "—" : session.tankFw}'
                        ' · bat ${session.tankBatteryPct}%'
                        '${session.tankFull ? " · FULL" : ""}'
                        '${session.tankEmpty ? " · EMPTY" : ""}'
                    : 'Hold the tank button 3 seconds while pairing is open.'),
              ),
              if (!session.tankBound || session.tankPairing)
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
                              builder: (ctx) =>
                                  _TankPairDialog(session: session),
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
                  label: Text(session.tankPairing
                      ? 'Listening…'
                      : 'Pair tank sensor'),
                ),
              if (session.tankBound)
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
                    if (ok == true) {
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
            ] else
              Text(
                'Connect to the pump to pair a tank sensor.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            const Divider(height: 28),
            if (ready)
              OutlinedButton.icon(
                onPressed: () => session.disconnectAndStay(),
                icon: const Icon(Icons.link_off_rounded),
                label: const Text('Disconnect'),
              ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text('Remove ${pump.name}?'),
                    content: const Text(
                      'Removes it from this phone. '
                      'Use “Unpair on pump” if you also want the device open for a new claim.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Remove'),
                      ),
                    ],
                  ),
                );
                if (ok == true && context.mounted) {
                  await session.forgetPump(pump);
                  if (context.mounted) Navigator.pop(context);
                }
              },
              child: const Text('Remove from phone'),
            ),
            if (ready)
              TextButton(
                style: TextButton.styleFrom(foregroundColor: scheme.error),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Unpair on pump?'),
                      content: const Text(
                        'Clears the owner on the device and removes it here. '
                        'Anyone nearby can claim it while pairing is open.',
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
                      await session.unpairOnDevice();
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Unpair failed: $e')),
                        );
                      }
                    }
                    if (context.mounted) Navigator.pop(context);
                  }
                },
                child: const Text('Unpair on pump'),
              ),
          ],
        ),
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
                const PingPongIndicator()
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

class _LedBrightnessTile extends StatefulWidget {
  const _LedBrightnessTile({required this.ready});

  final bool ready;

  @override
  State<_LedBrightnessTile> createState() => _LedBrightnessTileState();
}

class _LedBrightnessTileState extends State<_LedBrightnessTile> {
  late int _draft;
  bool _hydrated = false;

  void _hydrate(PumpSession session) {
    if (_hydrated) return;
    _draft = session.ledBrightness.clamp(1, 100);
    _hydrated = true;
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final scheme = Theme.of(context).colorScheme;
    _hydrate(session);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.light_mode_outlined, color: scheme.onSurfaceVariant),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'LED brightness',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                  Text(
                    !widget.ready
                        ? 'Connect to change'
                        : '$_draft%',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (widget.ready) ...[
          // Indent to match title text (icon 24 + gap 16).
          Padding(
            padding: const EdgeInsets.only(left: 40),
            child: Slider(
              min: 1,
              max: 100,
              divisions: 99,
              value: _draft.toDouble(),
              label: '$_draft%',
              onChanged: (v) => setState(() => _draft = v.round()),
              onChangeEnd: (v) => session.setLedBrightness(v.round()),
            ),
          ),
        ],
      ],
    );
  }
}

class _BuzzerSettingsSheet extends StatelessWidget {
  const _BuzzerSettingsSheet();

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
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
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
                      onChanged: (v) =>
                          session.setBuzzerSettings(onButton: v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('On pump on/off'),
                      subtitle:
                          const Text('When started or stopped from the app'),
                      value: session.buzzOnPump,
                      onChanged: (v) => session.setBuzzerSettings(onPump: v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('On auto-off'),
                      subtitle:
                          const Text('When the timer stops the pump'),
                      value: session.buzzOnAutoOff,
                      onChanged: (v) =>
                          session.setBuzzerSettings(onAutoOff: v),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Tone',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 8),
                    for (final t in _tones)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Material(
                          color: session.buzzerTone == t.$1
                              ? scheme.primaryContainer.withValues(alpha: 0.55)
                              : scheme.surfaceContainerHighest
                                  .withValues(alpha: 0.45),
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

class _FirmwareTile extends StatelessWidget {
  const _FirmwareTile({required this.ready});

  final bool ready;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final fw = context.watch<PumpFirmwareUpdate>();
    final scheme = Theme.of(context).colorScheme;
    final device = session.firmware.isEmpty ? '—' : session.firmware;
    final available = ready && fw.updateAvailableFor(session.firmware);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Badge(
            isLabelVisible: available,
            smallSize: 10,
            child: const Icon(Icons.memory_rounded),
          ),
          title: const Text('Firmware'),
          subtitle: Text(
            available
                ? '$device → ${fw.latestVersion}'
                : ready
                    ? device
                    : 'Connect to check',
          ),
          trailing: available
              ? FilledButton.tonal(
                  onPressed: () => showFirmwareConfirmSheet(context),
                  child: Text('Update to ${fw.latestVersion}'),
                )
              : IconButton(
                  tooltip: 'Check for updates',
                  onPressed: () => fw.checkForUpdates(force: true),
                  icon: fw.phase == FwUpdatePhase.checking
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded),
                ),
        ),
        if (fw.errorMessage != null && !available)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              fw.errorMessage!,
              style: TextStyle(color: scheme.error, fontSize: 13),
            ),
          ),
        if (ready)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => pickAndInstallFirmware(context),
              icon: const Icon(Icons.folder_open_rounded, size: 18),
              label: const Text('Install from file…'),
              style: TextButton.styleFrom(
                foregroundColor: scheme.onSurfaceVariant,
              ),
            ),
          ),
        const SizedBox(height: 4),
      ],
    );
  }
}
