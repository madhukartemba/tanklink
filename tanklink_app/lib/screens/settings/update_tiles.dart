import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../ble/pump_session.dart';
import '../../update/app_self_update.dart';
import '../../update/app_update_flow.dart';
import '../../update/firmware_update_flow.dart';
import '../../update/firmware_update.dart';
import '../../update/tank_firmware_update_flow.dart';

/// Firmware of one tank sensor, with an update button when one is available.
class TankFirmwareTile extends StatelessWidget {
  const TankFirmwareTile({
    super.key,
    required this.ready,
    required this.sensor,
  });

  final bool ready;
  final TankSensor sensor;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final fw = context.watch<TankFirmwareUpdate>();
    final device = sensor.firmware.isEmpty ? '—' : sensor.firmware;
    final available =
        ready &&
        session.sensorOnline(sensor) &&
        sensor.otaReady &&
        fw.updateAvailableFor(sensor.firmware);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Badge(
          isLabelVisible: available,
          smallSize: 10,
          child: const Icon(Icons.sensors),
        ),
        title: const Text('Tank firmware'),
        subtitle: Text(
          !sensor.otaReady
              ? '$device · pair again to allow updates'
              : available
              ? '$device → ${fw.latestVersion}'
              : device,
        ),
        trailing: available
            ? FilledButton.tonal(
                onPressed: () => showTankFirmwareConfirmSheet(context, sensor),
                child: Text('Update to ${fw.latestVersion}'),
              )
            : IconButton(
                tooltip: 'Check for tank updates',
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
    );
  }
}

class AppUpdateTile extends StatelessWidget {
  const AppUpdateTile({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppSelfUpdate>();
    if (!app.enabled) {
      return const SizedBox.shrink();
    }
    final current = app.installedVersion ?? '—';
    final available = app.updateAvailable();
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Badge(
            isLabelVisible: available,
            smallSize: 10,
            child: const Icon(Icons.smartphone_outlined),
          ),
          title: const Text('TankLink app'),
          subtitle: Text(
            available ? '$current → ${app.latestVersion}' : current,
          ),
          trailing: available
              ? FilledButton.tonal(
                  onPressed: () => showAppUpdateConfirmSheet(context),
                  child: Text('Update to ${app.latestVersion}'),
                )
              : IconButton(
                  tooltip: 'Check for app updates',
                  onPressed: () => app.checkForUpdates(force: true),
                  icon: app.phase == FwUpdatePhase.checking
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded),
                ),
        ),
        if (app.errorMessage != null && !available)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              app.errorMessage!,
              style: TextStyle(color: scheme.error, fontSize: 13),
            ),
          ),
        const Divider(height: 24),
      ],
    );
  }
}

class FirmwareTile extends StatelessWidget {
  const FirmwareTile({super.key, required this.ready});

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
