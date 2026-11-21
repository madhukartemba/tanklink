import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../util/nav.dart';
import '../ble/pump_session.dart';
import 'app_self_update.dart';
import 'app_update_flow.dart';
import 'firmware_update_flow.dart';
import 'firmware_update.dart';
import 'tank_firmware_update_flow.dart';

/// Vertical gap between stacked home update cards (after header).
const double kHomeUpdateBannerSectionTop = 12;
const double kHomeUpdateBannerGap = 8;

/// Shared layout for app / pump / tank update prompts on the home screen.
class HomeUpdateBannerCard extends StatelessWidget {
  const HomeUpdateBannerCard({
    super.key,
    required this.tint,
    required this.backgroundAlpha,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onUpdate,
    required this.onDismiss,
    this.tonalUpdateButton = false,
  });

  final Color tint;
  final double backgroundAlpha;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onUpdate;
  final VoidCallback onDismiss;
  final bool tonalUpdateButton;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final updateButton = tonalUpdateButton
        ? FilledButton.tonal(onPressed: onUpdate, child: const Text('Update'))
        : FilledButton(onPressed: onUpdate, child: const Text('Update'));

    return Material(
      color: tint.withValues(alpha: backgroundAlpha),
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, color: tint),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w700, color: tint),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            updateButton,
            IconButton(
              tooltip: 'Dismiss',
              onPressed: onDismiss,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

/// One pending update, as shown on the home screen.
class _UpdateItem {
  const _UpdateItem({
    required this.name,
    required this.tint,
    required this.backgroundAlpha,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.latest,
    required this.onUpdate,
    required this.onDismiss,
    this.tonal = false,
  });

  /// Short name for the summary row: "Pump", "Tank", "App".
  final String name;
  final Color tint;
  final double backgroundAlpha;
  final IconData icon;
  final String title;
  final String subtitle;
  final String latest;
  final VoidCallback onUpdate;
  final VoidCallback onDismiss;
  final bool tonal;

  /// [short]: in the Updates sheet, which already says what these are.
  Widget card({VoidCallback? before, bool short = false}) =>
      HomeUpdateBannerCard(
        tint: tint,
        backgroundAlpha: backgroundAlpha,
        icon: icon,
        title: short ? name : title,
        subtitle: subtitle,
        tonalUpdateButton: tonal,
        onUpdate: () {
          before?.call();
          onUpdate();
        },
        onDismiss: onDismiss,
      );
}

/// Pending updates in install order: pump first (a new app may need the new
/// pump), then tanks, then the app. [actions] is the home screen's context,
/// which the update flows open from even after a sheet has closed.
List<_UpdateItem> _pendingUpdates(BuildContext context, BuildContext actions) {
  final scheme = Theme.of(context).colorScheme;
  final session = context.watch<PumpSession>();
  final items = <_UpdateItem>[];

  final pumpFw = context.watch<PumpFirmwareUpdate>();
  // Not while the pump is updating: "update available" would be wrong, and the
  // home screen already shows the update's progress.
  if (session.authed &&
      session.connected &&
      !session.pumpUpdating &&
      pumpFw.showHomeBanner(session.firmware)) {
    final current = session.firmware.isEmpty ? '—' : session.firmware;
    final latest = pumpFw.latestVersion ?? '';
    items.add(
      _UpdateItem(
        name: 'Pump',
        tint: scheme.primary,
        backgroundAlpha: 0.14,
        icon: Icons.system_update_alt_rounded,
        title: 'Pump update available',
        subtitle: '$current → $latest',
        latest: latest,
        onUpdate: () => showFirmwareConfirmSheet(actions),
        onDismiss: () => pumpFw.snoozeLatest(),
      ),
    );
  }

  // The pump found an update itself (daily check over its Wi-Fi): show it even
  // when this phone hasn't looked at GitHub.
  final pumpFound = session.wifiStatus;
  if (session.authed &&
      session.connected &&
      !session.pumpUpdating &&
      pumpFound?.update == PumpUpdateState.available &&
      pumpFound?.availableVersion != null &&
      !pumpFw.showHomeBanner(session.firmware)) {
    final current = session.firmware.isEmpty ? '—' : session.firmware;
    final latest = pumpFound!.availableVersion!;
    items.add(
      _UpdateItem(
        name: 'Pump',
        tint: scheme.primary,
        backgroundAlpha: 0.14,
        icon: Icons.system_update_alt_rounded,
        title: 'Pump update available',
        subtitle: '$current → $latest',
        latest: latest,
        onUpdate: () => showFirmwareConfirmSheet(actions),
        onDismiss: () => pumpFw.snoozeLatest(),
      ),
    );
  }

  final tankFw = context.watch<TankFirmwareUpdate>();
  if (session.ready) {
    // The first sensor in range that can take the update; the rest follow
    // from Settings → Tank sensors (each needs its own button press).
    final sensor = session.sensors
        .where(
          (s) =>
              session.sensorOnline(s) &&
              s.otaReady &&
              tankFw.showHomeBanner(s.firmware),
        )
        .firstOrNull;
    if (sensor != null) {
      final current = sensor.firmware.isEmpty ? '—' : sensor.firmware;
      final latest = tankFw.latestVersion ?? '';
      items.add(
        _UpdateItem(
          name: session.sensors.length > 1
              ? 'Sensor #${sensor.shortId}'
              : 'Tank',
          tint: scheme.tertiary,
          backgroundAlpha: 0.16,
          icon: Icons.sensors,
          title: session.sensors.length > 1
              ? 'Sensor #${sensor.shortId} update available'
              : 'Tank update available',
          subtitle: '$current → $latest',
          latest: latest,
          tonal: true,
          onUpdate: () => showTankFirmwareConfirmSheet(actions, sensor),
          onDismiss: () => tankFw.snoozeLatest(),
        ),
      );
    }
  }

  final app = context.watch<AppSelfUpdate>();
  if (app.enabled && app.updateAvailable()) {
    final current = app.installedVersion ?? '—';
    final latest = app.latestVersion ?? '';
    items.add(
      _UpdateItem(
        name: 'App',
        tint: scheme.primary,
        backgroundAlpha: 0.14,
        icon: Icons.smartphone_outlined,
        title: 'App update available',
        subtitle: '$current → $latest',
        latest: latest,
        onUpdate: () => showAppUpdateConfirmSheet(actions),
        onDismiss: () => app.snoozeLatest(),
      ),
    );
  }
  return items;
}

/// The home screen's update prompts. One update shows as its own card; two
/// or more fold into one row that opens a sheet with each of them, so the
/// tank card keeps its room.
class HomeUpdateBannerSection extends StatelessWidget {
  const HomeUpdateBannerSection({super.key});

  @override
  Widget build(BuildContext context) {
    final items = _pendingUpdates(context, context);
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: kHomeUpdateBannerSectionTop),
      child: items.length == 1
          ? items.single.card()
          : _UpdatesSummaryRow(
              items: items,
              onTap: () => _showUpdatesSheet(context),
            ),
    );
  }

  void _showUpdatesSheet(BuildContext home) {
    showModalBottomSheet<void>(
      context: home,
      showDragHandle: true,
      builder: (sheet) => _UpdatesSheet(home: home),
    );
  }
}

class _UpdatesSummaryRow extends StatelessWidget {
  const _UpdatesSummaryRow({required this.items, required this.onTap});

  final List<_UpdateItem> items;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final names = items.map((i) => '${i.name} ${i.latest}').join(', ');
    return Material(
      color: scheme.primary.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Row(
            children: [
              Icon(Icons.system_update_alt_rounded, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${items.length} updates available',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      names,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.expand_more_rounded, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

/// Every pending update, each with its own Update button. Rebuilds as they
/// are dismissed or installed, and closes when none are left.
class _UpdatesSheet extends StatelessWidget {
  const _UpdatesSheet({required this.home});

  final BuildContext home;

  @override
  Widget build(BuildContext context) {
    final items = _pendingUpdates(context, home);
    if (items.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        popSelf(context); // not maybePop: that closed whatever was on top
      });
    }
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Updates', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Update the pump first, then the tank and the app.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) const SizedBox(height: kHomeUpdateBannerGap),
              items[i].card(before: () => popSelf(context), short: true),
            ],
          ],
        ),
      ),
    );
  }
}
