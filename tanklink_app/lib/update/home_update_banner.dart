import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

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

/// Stacks visible update cards with consistent top inset and spacing.
class HomeUpdateBannerSection extends StatelessWidget {
  const HomeUpdateBannerSection({super.key});

  @override
  Widget build(BuildContext context) {
    final cards = <Widget>[
      ..._appCard(context),
      ..._pumpCard(context),
      ..._tankCard(context),
    ];
    if (cards.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: kHomeUpdateBannerSectionTop),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) const SizedBox(height: kHomeUpdateBannerGap),
            cards[i],
          ],
        ],
      ),
    );
  }

  List<Widget> _appCard(BuildContext context) {
    final app = context.watch<AppSelfUpdate>();
    if (!app.enabled || !app.updateAvailable()) {
      return const [];
    }
    final scheme = Theme.of(context).colorScheme;
    final current = app.installedVersion ?? '—';
    final latest = app.latestVersion ?? '';
    return [
      HomeUpdateBannerCard(
        tint: scheme.primary,
        backgroundAlpha: 0.14,
        icon: Icons.smartphone_outlined,
        title: 'App update available',
        subtitle: '$current → $latest',
        onUpdate: () => showAppUpdateConfirmSheet(context),
        onDismiss: () => app.snoozeLatest(),
      ),
    ];
  }

  List<Widget> _pumpCard(BuildContext context) {
    final session = context.watch<PumpSession>();
    final fw = context.watch<PumpFirmwareUpdate>();
    if (!(session.authed && session.connected)) {
      return const [];
    }
    if (!fw.showHomeBanner(session.firmware)) {
      return const [];
    }
    final scheme = Theme.of(context).colorScheme;
    final current = session.firmware.isEmpty ? '—' : session.firmware;
    final latest = fw.latestVersion ?? '';
    return [
      HomeUpdateBannerCard(
        tint: scheme.primary,
        backgroundAlpha: 0.14,
        icon: Icons.system_update_alt_rounded,
        title: 'Pump update available',
        subtitle: '$current → $latest',
        onUpdate: () => showFirmwareConfirmSheet(context),
        onDismiss: () => fw.snoozeLatest(),
      ),
    ];
  }

  List<Widget> _tankCard(BuildContext context) {
    final session = context.watch<PumpSession>();
    final fw = context.watch<TankFirmwareUpdate>();
    if (!session.ready) {
      return const [];
    }
    // The first sensor in range that can take the update; the rest follow
    // from Settings → Tank sensors (each needs its own button press).
    final sensor = session.sensors
        .where(
          (s) =>
              session.sensorOnline(s) &&
              s.otaReady &&
              fw.showHomeBanner(s.firmware),
        )
        .firstOrNull;
    if (sensor == null) {
      return const [];
    }
    final scheme = Theme.of(context).colorScheme;
    final current = sensor.firmware.isEmpty ? '—' : sensor.firmware;
    final latest = fw.latestVersion ?? '';
    return [
      HomeUpdateBannerCard(
        tint: scheme.tertiary,
        backgroundAlpha: 0.16,
        icon: Icons.sensors,
        title: session.sensors.length > 1
            ? 'Sensor #${sensor.shortId} update available'
            : 'Tank update available',
        subtitle: '$current → $latest',
        tonalUpdateButton: true,
        onUpdate: () => showTankFirmwareConfirmSheet(context, sensor),
        onDismiss: () => fw.snoozeLatest(),
      ),
    ];
  }
}
