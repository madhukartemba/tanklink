import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../ble/pump_session.dart';
import '../update/firmware_update_flow.dart';
import '../update/pump_firmware_update.dart';
import '../update/tank_firmware_update.dart';
import '../update/tank_firmware_update_flow.dart';
import '../widgets/slide_to_start.dart';
import 'add_pump_screen.dart';
import 'pump_list_screen.dart';
import 'pump_settings_sheet.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<PumpFirmwareUpdate>().checkForUpdates();
      context.read<TankFirmwareUpdate>().checkForUpdates();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      context.read<PumpSession>().onAppResumed();
      context.read<PumpFirmwareUpdate>().checkForUpdates();
      context.read<TankFirmwareUpdate>().checkForUpdates();
    }
  }

  Future<void> _setPump(bool on) async {
    HapticFeedback.mediumImpact();
    await context.read<PumpSession>().setPump(on);
  }

  String _autoOffSuffix(PumpSession session) {
    if (session.autoOffMin <= 0) return '';
    final m = session.autoOffMin;
    final auto = m < 60
        ? '${m}m'
        : '${m ~/ 60}h${m % 60 == 0 ? '' : ' ${m % 60}m'}';
    return ' · auto-off $auto';
  }

  String _statusLine(PumpSession session, bool ready) {
    if (!ready) {
      return session.connecting ? 'Connecting…' : 'Not connected';
    }
    if (session.pumpOn) {
      return 'Running · ${session.runLabel}${_autoOffSuffix(session)}';
    }
    if (session.autoOffMin > 0) {
      return 'Stopped${_autoOffSuffix(session)}';
    }
    return 'Stopped';
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final pump = session.selected;
    final scheme = Theme.of(context).colorScheme;
    final ready = session.authed && session.connected;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TopBar(
                onPumps: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const PumpListScreen(),
                    ),
                  );
                },
                onAdd: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const AddPumpScreen(),
                    ),
                  );
                },
              ),
              if (pump == null)
                Expanded(child: _EmptyState(scheme: scheme))
              else ...[
                const SizedBox(height: 10),
                _PumpHeader(
                  pump: pump,
                  connecting: session.connecting,
                  connected: ready,
                  status: session.status,
                  onOpenList: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const PumpListScreen(),
                      ),
                    );
                  },
                  onSettings: () => showPumpSettingsSheet(context),
                  onRename: () => showRenamePumpDialog(context, pump),
                ),
                const FirmwareUpdateBanner(),
                const TankFirmwareUpdateBanner(),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (ready && session.pumpErrorTitle != null) ...[
                          _PumpErrorBanner(session: session),
                          const SizedBox(height: 8),
                        ],
                        Expanded(
                          child: _TankHero(
                            session: session,
                            ready: ready,
                            onOpenSettings: () => showPumpSettingsSheet(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                _PumpControls(
                  session: session,
                  ready: ready,
                  statusLine: _statusLine(session, ready),
                  onStart: () => _setPump(true),
                  onStop: () {
                    _setPump(false);
                  },
                  onConnect: () {
                    session.connectSelected();
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onPumps, required this.onAdd});

  final VoidCallback onPumps;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          'TankLink',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
              ),
        ),
        const Spacer(),
        IconButton.filledTonal(
          tooltip: 'Pumps',
          onPressed: onPumps,
          icon: const Icon(Icons.list_alt_rounded),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          tooltip: 'Add pump',
          onPressed: onAdd,
          icon: const Icon(Icons.add_rounded),
        ),
      ],
    );
  }
}

class _PumpControls extends StatelessWidget {
  const _PumpControls({
    required this.session,
    required this.ready,
    required this.statusLine,
    required this.onStart,
    required this.onStop,
    required this.onConnect,
  });

  final PumpSession session;
  final bool ready;
  final String statusLine;
  final Future<void> Function() onStart;
  final VoidCallback onStop;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: session.pumpOn && ready
              ? _RunningPanel(
                  key: const ValueKey('running'),
                  statusLine: statusLine,
                  onStop: onStop,
                )
              : Column(
                  key: const ValueKey('idle'),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      statusLine,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 14),
                    SlideToStart(
                      enabled: ready && session.canStartPump,
                      label: ready &&
                              session.tankBound &&
                              session.tankOnline &&
                              session.tankFull
                          ? 'Tank is full'
                          : 'Slide to start',
                      onCompleted: onStart,
                    ),
                  ],
                ),
        ),
        if (!ready && !session.connecting) ...[
          const SizedBox(height: 12),
          FilledButton(
            onPressed: onConnect,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            child: Text(
              session.connectFailed ? 'Try again' : 'Connect',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ],
        if (session.connecting)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }
}

/// Full-area tank status — level, signal, battery; no FW / tank ID.
class _TankHero extends StatelessWidget {
  const _TankHero({
    required this.session,
    required this.ready,
    required this.onOpenSettings,
  });

  final PumpSession session;
  final bool ready;
  final VoidCallback onOpenSettings;

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
              'Connect to see the tank',
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              'Tank level, signal, and battery show up here.',
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
              'Hold the tank button about 3 seconds',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
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
              onPressed: onOpenSettings,
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
      subtitle = 'No recent heartbeat';
    } else if (session.tankFull) {
      subtitle = 'Pump stays off while full';
    } else if (session.tankEmpty) {
      subtitle = 'Almost empty';
    } else if (session.emptyFloatConnected) {
      subtitle = 'Not empty';
    } else {
      subtitle = 'Level looks good';
    }

    final batPct = session.tankBatteryPct;
    final batUnknown = batPct <= 0;
    final String batDetail;
    if (batUnknown) {
      batDetail = 'No reading';
    } else if (lowBat) {
      batDetail = 'Low — recharge soon';
    } else {
      batDetail = 'OK';
    }
    final batAccent = (batUnknown || lowBat) ? scheme.error : accent;

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
                      detail: (!offline && session.tankRssiDbm != null)
                          ? '${session.tankRssiDbm} dBm'
                          : '—',
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
                      value: batUnknown ? '—' : '$batPct%',
                      detail: batDetail,
                      progress:
                          batUnknown ? 0 : (batPct / 100).clamp(0.0, 1.0),
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
              if (offline || lowBat || batUnknown) ...[
                SizedBox(height: tight ? 6 : 12),
                Text(
                  offline
                      ? 'Check tank power, antenna, and range.'
                      : batUnknown
                          ? 'Battery reading missing — check the tank ADC wiring.'
                          : 'Tank battery is getting low.',
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

class _PumpErrorBanner extends StatelessWidget {
  const _PumpErrorBanner({required this.session});

  final PumpSession session;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = session.pumpErrorTitle;
    final detail = session.pumpErrorDetail;
    if (title == null) return const SizedBox.shrink();
    return Material(
      color: scheme.errorContainer.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: scheme.onErrorContainer,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onErrorContainer.withValues(alpha: 0.9),
                            height: 1.3,
                          ),
                    ),
                  ],
                ],
              ),
            ),
            Text(
              '${session.pumpLastError}',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w800,
                  ),
            ),
            IconButton(
              tooltip: 'Clear error',
              visualDensity: VisualDensity.compact,
              onPressed: () => session.clearPumpError(),
              icon: Icon(Icons.close_rounded, color: scheme.onErrorContainer),
            ),
          ],
        ),
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
          style: (compact ? text.titleMedium : text.titleLarge)
              ?.copyWith(fontWeight: FontWeight.w700),
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
  const _HeroFrame({
    required this.child,
    required this.accent,
    this.onTap,
  });

  final Widget child;
  final Color accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = Container(
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
    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: content,
      ),
    );
  }
}

class _RunningPanel extends StatelessWidget {
  const _RunningPanel({
    super.key,
    required this.statusLine,
    required this.onStop,
  });

  final String statusLine;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            statusLine,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          height: kHomeControlHeight,
          child: FilledButton(
            onPressed: onStop,
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            child: const Text(
              'Stop pump',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.water_drop_outlined, size: 56, color: scheme.primary),
        const SizedBox(height: 16),
        Text(
          'No pumps yet',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 8),
        Text(
          'Hold Start and Stop together for 5 seconds to enter pairing, then add it here.',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 28),
        FilledButton.icon(
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const AddPumpScreen()),
            );
          },
          icon: const Icon(Icons.add),
          label: const Text('Add pump'),
        ),
      ],
    );
  }
}

class _PumpHeader extends StatelessWidget {
  const _PumpHeader({
    required this.pump,
    required this.connecting,
    required this.connected,
    required this.status,
    required this.onOpenList,
    required this.onSettings,
    required this.onRename,
  });

  final SavedPump pump;
  final bool connecting;
  final bool connected;
  final String status;
  final VoidCallback onOpenList;
  final VoidCallback onSettings;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onOpenList,
        onLongPress: onRename,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
          child: Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: connected
                      ? const Color(0xFF3DDC97)
                      : connecting
                          ? scheme.tertiary
                          : scheme.outline,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pump.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    Text(
                      connected
                          ? 'Online · #${pump.serial}'
                          : connecting
                              ? status
                              : 'Offline · #${pump.serial}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Settings',
                onPressed: onSettings,
                icon: const Icon(Icons.tune_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
