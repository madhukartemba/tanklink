import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../ble/pump_session.dart';
import '../ble/tanklink_uuids.dart';
import '../update/app_self_update.dart';
import '../update/firmware_update.dart';
import '../util/format.dart';
import 'error_codes_screen.dart';
import 'fill_history_screen.dart';
import 'usage_screen.dart';
import 'schedules_screen.dart';
import 'starter_settings_screen.dart';
import 'settings/tank_sensor_screen.dart';
import 'settings/add_phone_dialog.dart';
import 'settings/update_tiles.dart';
import 'settings/buzzer_settings_sheet.dart';
import 'settings/led_brightness_tile.dart';
import 'settings/auto_off_section.dart';
import 'settings/factory_reset_dialog.dart';
import 'report_problem_screen.dart';
import '../util/error_text.dart';

Future<void> showPumpSettingsSheet(BuildContext context) {
  // Refresh release metadata when opening settings, unless it was checked
  // in the last few minutes (opening settings often must not use up
  // GitHub's hourly limit).
  context.read<PumpFirmwareUpdate>().checkForUpdates();
  context.read<PumpFirmwareUpdate>().clearSnooze();
  context.read<TankFirmwareUpdate>().checkForUpdates();
  context.read<TankFirmwareUpdate>().clearSnooze();
  context.read<AppSelfUpdate>().checkForUpdates();
  context.read<AppSelfUpdate>().clearSnooze();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
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

String _buzzerSummary(PumpSession session) {
  if (!session.buzzerEnabled) return 'Off';
  const tones = ['Click', 'Soft', 'Sharp', 'Double'];
  final tone = tones[session.buzzerTone.clamp(0, 3)];
  return 'On · $tone';
}

String _starterSummary(PumpSession session) {
  switch (session.starterType) {
    case TankLinkUuids.starterTwoButton:
      return 'Start and Stop · ${session.relayPulseMs} ms';
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
  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final pump = session.selected;
    final scheme = Theme.of(context).colorScheme;
    if (pump == null) {
      return const SizedBox(height: 120, child: Center(child: Text('No pump')));
    }

    final ready = session.ready;
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
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              ready ? 'Connected' : 'Offline',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            const AppUpdateTile(),
            // Firmware updates also work when the protocol versions differ.
            FirmwareTile(ready: session.authed && session.connected),
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
                        useSafeArea: true,
                        showDragHandle: true,
                        builder: (_) => const BuzzerSettingsSheet(),
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
            LedBrightnessTile(ready: ready),
            const SizedBox(height: 8),
            AutoOffSection(ready: ready),
            const Divider(height: 28),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule_rounded),
              title: const Text('Schedules'),
              subtitle: Text(
                !ready
                    ? 'Connect to change'
                    : session.schedules.isEmpty
                    ? 'No daily fill times'
                    : '${session.schedules.where((s) => s.enabled).length} active · every day',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              enabled: ready,
              onTap: !ready
                  ? null
                  : () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SchedulesScreen(),
                        ),
                      );
                    },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.history_rounded),
              title: const Text('Fill history'),
              subtitle: Text(
                !ready
                    ? 'Connect to see past fills'
                    : session.fills.isEmpty
                    ? 'No fills yet'
                    : 'Last: ${formatRunTime(session.fills.first.ranSec)} · '
                          '${stopReasonLabel(session.fills.first.stoppedBy)}',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              enabled: ready,
              onTap: !ready
                  ? null
                  : () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const FillHistoryScreen(),
                        ),
                      );
                    },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.insights_rounded),
              title: const Text('Water and power'),
              subtitle: const Text('Litres, pump time and cost each day'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const UsageScreen()),
                );
              },
            ),
            const Divider(height: 28),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.numbers_rounded),
              title: const Text('Warnings and lights'),
              subtitle: const Text('What the blinks and colors mean'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ErrorCodesScreen(),
                  ),
                );
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('Report a problem'),
              subtitle: const Text('Send what went wrong to the developer'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => openReportScreen(context),
            ),
            if (kDebugMode && ready)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.science_outlined),
                title: const Text('Simulate an error'),
                subtitle: const Text('Debug build only'),
                onTap: () => _simulateErrorDialog(context, session),
              ),
            if (kDebugMode)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.science_outlined),
                title: const Text('Usage charts with sample data'),
                subtitle: const Text('Debug build only'),
                onTap: () {
                  session.simulateUsage(true);
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const UsageScreen(),
                    ),
                  );
                },
              ),
            if (ready && session.pumpLastError != 0)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.clear_all_rounded, color: scheme.error),
                title: const Text('Clear pump error'),
                subtitle: const Text('Remove the warning from the home screen'),
                onTap: () async {
                  await session.clearPumpError();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Pump error cleared')),
                    );
                  }
                },
              ),
            const Divider(height: 28),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.sensors),
              title: const Text('Tank sensors'),
              subtitle: Text(
                !ready
                    ? 'Connect to manage tank sensors'
                    : tankSensorsSummary(session),
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              enabled: ready,
              onTap: !ready
                  ? null
                  : () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const TankSensorScreen(),
                        ),
                      );
                    },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.phone_android_rounded),
              title: const Text('Add another phone'),
              subtitle: Text(
                !ready
                    ? 'Connect to the pump first'
                    : session.canControlPairing
                    ? 'Turn on pairing mode so another phone can add this pump'
                    : 'Update the pump to do this from the app. Or hold its '
                          'button until the light turns blue.',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              enabled: ready && session.canControlPairing,
              onTap: ready && session.canControlPairing
                  ? () => showAddPhoneDialog(context, session)
                  : null,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.phonelink_erase_rounded),
              title: const Text('Sign out other phones'),
              subtitle: Text(
                ready
                    ? 'For a lost or old phone. The others must add the pump again.'
                    : 'Connect to the pump first',
              ),
              enabled: ready,
              onTap: !ready
                  ? null
                  : () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Sign out other phones?'),
                          content: const Text(
                            'Every other phone loses this pump. This phone '
                            'stays signed in.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('Sign out'),
                            ),
                          ],
                        ),
                      );
                      if (ok != true || !context.mounted) return;
                      final messenger = ScaffoldMessenger.of(context);
                      try {
                        await session.forgetOtherPhones();
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text('Other phones signed out'),
                          ),
                        );
                      } catch (e) {
                        messenger.showSnackBar(
                          SnackBar(content: Text('Couldn’t sign them out: $e')),
                        );
                      }
                    },
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
              style: TextButton.styleFrom(foregroundColor: scheme.error),
              onPressed: () async {
                // Only this phone forgets the pump (and its key). Nothing is
                // sent: the pump keeps this phone's key until another phone
                // uses Sign out other phones. Other phones stay signed in.
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text('Remove ${pump.name} from this phone?'),
                    content: const Text(
                      'Other phones that have this pump keep it. To add it '
                      'back later, use Add pump.',
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
                if (ok != true || !context.mounted) return;
                await session.forgetPump(pump);
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Remove from this phone'),
            ),
            if (ready) ...[
              const Divider(height: 28),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: scheme.error),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => const FactoryResetDialog(),
                  );
                  if (ok == true && context.mounted) {
                    try {
                      await session.factoryResetOnDevice();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Factory reset sent — pump will reboot.',
                            ),
                          ),
                        );
                        Navigator.pop(context);
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Factory reset failed: $e')),
                        );
                      }
                    }
                  }
                },
                child: const Text('Factory reset pump…'),
              ),
              Text(
                'Or hold the pump button for about 5 seconds, then keep holding about 10 seconds more.',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Debug builds only: pick a pump or tank code to show as if the board sent it.
Future<void> _simulateErrorDialog(
  BuildContext context,
  PumpSession session,
) async {
  Widget pick(String label, VoidCallback onTap) => ListTile(
    dense: true,
    title: Text(label),
    onTap: () {
      onTap();
      Navigator.of(context).pop();
    },
  );
  await showDialog<void>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Simulate an error'),
      children: [
        pick('Stop simulating', () => session.simulateErrors()),
        const Divider(),
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 4, 24, 4),
          child: Text('Pump'),
        ),
        for (final w in TankLinkErrors.pump)
          pick(
            '${w.code} · ${w.name}',
            () => session.simulateErrors(
              pump: w.code,
              tank: session.simTankFault,
            ),
          ),
        const Divider(),
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 4, 24, 4),
          child: Text('Tank sensor'),
        ),
        for (final w in TankLinkErrors.tank)
          pick(
            '${w.code} · ${w.name}',
            () => session.simulateErrors(
              pump: session.simPumpError,
              tank: w.code,
            ),
          ),
        const Divider(),
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 4, 24, 4),
          child: Text('Tank battery (last 7 days)'),
        ),
        for (final b in _batteryScenarios)
          pick(b.$1, () => session.simulateBattery(lows: b.$2, pct: b.$2.last)),
        pick('Real battery again', () => session.simulateBattery()),
      ],
    ),
  );
}

/// Name and daily lows (oldest first). The last low is also the current %.
const _batteryScenarios = <(String, List<int>)>[
  ('Charging from solar', [40, 45, 50, 55, 60, 65, 70]),
  ('Solar keeping up', [80, 81, 79, 80, 81, 80, 80]),
  ('Slowly draining (weeks left)', [90, 88, 86, 84, 82, 80, 78]),
  ('Draining fast (warning)', [60, 54, 48, 42, 36, 30, 24]),
  ('Battery low', [32, 28, 24, 20, 16, 12, 8]),
  ('Too few days for a trend', [70, 70]),
];
