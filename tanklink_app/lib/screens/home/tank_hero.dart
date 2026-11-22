import 'package:material_ui/material_ui.dart';

import '../../ble/pump_session.dart';
import '../../util/format.dart';
import '../../util/error_text.dart';

/// Full-area tank status — level, signal, battery; no FW / tank ID.
class TankHero extends StatelessWidget {
  const TankHero({super.key, required this.session, required this.ready});

  final PumpSession session;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    if (!ready) {
      return _HeroFrame(
        accent: scheme.outline,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.sensors_off_outlined, size: 48, color: scheme.outline),
            const SizedBox(height: 16),
            Text(
              session.protocolMismatch
                  ? 'Update needed'
                  : 'Connect to see the tank',
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              session.protocolMismatch
                  ? 'The tank shows up here once the pump and app match.'
                  : 'Tank level, signal, and battery show up here.',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    if (session.tankPairing) {
      return _HeroFrame(
        accent: scheme.tertiary,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: scheme.tertiary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Listening for tank…',
              style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Hold the tank button for 3 seconds',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            // Closes the pump's pairing window too, not just this screen.
            TextButton(
              onPressed: session.stopTankPair,
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
    }

    if (!session.tankBound) {
      return _HeroFrame(
        accent: scheme.primary,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.water_drop_outlined, size: 56, color: scheme.primary),
            const SizedBox(height: 18),
            Text(
              'No tank sensor',
              style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Pair a sensor so the pump can stop when the tank is full.',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 22),
            FilledButton.tonal(
              onPressed: () async {
                try {
                  await session.startTankPair();
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Tank pair failed: ${errorMessage(e)}'),
                    ),
                  );
                }
              },
              child: const Text('Pair tank sensor'),
            ),
          ],
        ),
      );
    }

    final offline = !session.tankOnline;
    final lowBat = session.tankBatteryLow;
    final Color accent;
    if (offline) {
      accent = scheme.error;
    } else if (session.tankFull) {
      accent = const Color(0xFF1FA97A);
    } else if (session.tankEmpty || lowBat) {
      accent = const Color(0xFFC47A2A);
    } else {
      accent = scheme.primary;
    }

    final String title;
    if (offline) {
      title = 'Out of range';
    } else if (session.tankFull) {
      title = 'Full';
    } else if (session.tankEmpty) {
      title = 'Almost empty';
    } else if (session.emptyFloatConnected) {
      title = 'Half full';
    } else {
      title = 'Ready';
    }

    final String subtitle;
    if (offline) {
      subtitle = 'No recent news from the tank';
    } else if (session.tankFull) {
      subtitle = 'Pump stays off while full';
    } else if (session.tankEmpty) {
      subtitle = 'Almost empty';
    } else if (session.emptyFloatConnected) {
      subtitle = 'Not empty';
    } else {
      subtitle = 'Level looks good';
    }

    // Offline: the last reading may be hours old, so show it as unknown
    // (like the signal) and keep the old value only as a hint.
    final batPct = session.tankBatteryPct;
    final sensor = session.activeSensor;
    final outlook = sensor == null
        ? const BatteryOutlook(BatteryTrend.unknown)
        : session.batteryOutlook(sensor);
    final solarBehind = !offline && !lowBat && solarFallingBehind(outlook);
    final batMissing = !offline && batPct <= 0;
    final String batValue;
    final String? batDetail;
    final Color batAccent;
    if (offline) {
      batValue = 'Unknown';
      batDetail = batPct > 0 ? 'Last $batPct%' : null;
      batAccent = scheme.outline;
    } else if (batMissing) {
      batValue = '—';
      batDetail = 'No reading';
      batAccent = scheme.error;
    } else {
      batValue = '$batPct%';
      batDetail = batteryHint(batPct, low: lowBat, outlook: outlook);
      batAccent = lowBat ? scheme.error : accent;
    }
    final rssi = session.tankRssiDbm;

    return _HeroFrame(
      accent: accent,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final h = constraints.maxHeight;
          final tight = h < 420;
          final veryTight = h < 340;
          final gap = veryTight ? 6.0 : (tight ? 10.0 : 20.0);
          final titleStyle = (veryTight ? text.titleLarge : text.displaySmall)
              ?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -1.0,
                color: accent,
              );

          return Column(
            children: [
              Spacer(flex: veryTight ? 1 : 2),
              Flexible(
                flex: veryTight ? 2 : 3,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: _LevelGlyph(
                    accent: accent,
                    full: session.tankFull && !offline,
                    empty: session.tankEmpty && !offline,
                    offline: offline,
                    size: veryTight ? 88 : 120,
                  ),
                ),
              ),
              SizedBox(height: gap),
              if (session.multiTank)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    session.activeTankName,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              Text(title, style: titleStyle, textAlign: TextAlign.center),
              SizedBox(height: veryTight ? 2 : 6),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.titleMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                  fontSize: veryTight ? 14 : null,
                ),
              ),
              Spacer(flex: veryTight ? 1 : 2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _MetricTile(
                      icon: Icons.signal_cellular_alt_rounded,
                      label: 'Signal',
                      value: offline ? 'Offline' : session.tankSignalLabel,
                      detail: offline || rssi == null ? null : '$rssi dBm',
                      progress: offline ? 0 : session.tankSignalQuality,
                      accent: offline ? scheme.error : accent,
                      compact: tight,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _MetricTile(
                      icon: Icons.battery_std_rounded,
                      label: 'Battery',
                      value: batValue,
                      detail: batDetail,
                      progress: offline || batMissing
                          ? 0
                          : (batPct / 100).clamp(0.0, 1.0),
                      accent: batAccent,
                      compact: tight,
                    ),
                  ),
                ],
              ),
              SizedBox(height: tight ? 8 : 14),
              Row(
                children: [
                  Icon(
                    Icons.schedule_rounded,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Last seen ${session.tankAgeLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
              if (offline || lowBat || batMissing || solarBehind) ...[
                SizedBox(height: tight ? 6 : 12),
                Text(
                  offline
                      ? 'Check tank power, antenna, and range.'
                      : batMissing
                      ? 'Battery reading missing — check the tank ADC wiring.'
                      : lowBat
                      ? 'Tank battery is low. Check the solar panel gets sun and is clean.'
                      : 'Solar isn’t keeping up. Check the panel gets sun and is clean.',
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(
                    color: scheme.error,
                    height: 1.35,
                    fontSize: veryTight ? 12.5 : null,
                  ),
                ),
              ],
              Spacer(flex: 1),
            ],
          );
        },
      ),
    );
  }
}

class _LevelGlyph extends StatelessWidget {
  const _LevelGlyph({
    required this.accent,
    required this.full,
    required this.empty,
    required this.offline,
    this.size = 120,
  });

  final Color accent;
  final bool full;
  final bool empty;
  final bool offline;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fill = offline
        ? 0.12
        : full
        ? 0.92
        : empty
        ? 0.18
        : 0.55;
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              accent.withValues(alpha: 0.35 + 0.35 * fill),
              accent.withValues(alpha: 0.06),
            ],
          ),
        ),
        child: Center(
          child: Icon(
            offline
                ? Icons.signal_wifi_off_rounded
                : full
                ? Icons.water_drop
                : Icons.water_drop_outlined,
            size: size * 0.43,
            color: accent,
          ),
        ),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.progress,
    required this.accent,
    this.detail,
    this.compact = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? detail;
  final double progress;
  final Color accent;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(icon, size: compact ? 16 : 18, color: accent),
            const SizedBox(width: 6),
            Text(
              label,
              style: text.labelLarge?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                fontSize: compact ? 12 : null,
              ),
            ),
          ],
        ),
        SizedBox(height: compact ? 4 : 8),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: (compact ? text.titleMedium : text.titleLarge)?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        SizedBox(
          height: compact ? 14 : 16,
          child: Text(
            detail ?? ' ',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontSize: compact ? 11 : null,
            ),
          ),
        ),
        SizedBox(height: compact ? 6 : 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: progress.clamp(0.0, 1.0),
            minHeight: compact ? 4 : 6,
            backgroundColor: scheme.surfaceContainerHighest,
            color: accent,
          ),
        ),
      ],
    );
  }
}

class _HeroFrame extends StatelessWidget {
  const _HeroFrame({required this.child, required this.accent});

  final Widget child;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      height: double.infinity,
      padding: const EdgeInsets.fromLTRB(22, 16, 22, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            accent.withValues(alpha: 0.14),
            scheme.surfaceContainerHighest.withValues(alpha: 0.35),
            scheme.surface.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.45, 1.0],
        ),
      ),
      child: child,
    );
  }
}
