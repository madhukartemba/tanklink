import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../ble/pump_session.dart';
import '../link/pump_link.dart';
import '../update/app_self_update.dart';
import '../update/home_update_banner.dart';
import '../update/firmware_update.dart';
import '../update/github_release_util.dart';
import 'add_pump_screen.dart';
import 'pump_list_screen.dart';
import 'pump_settings_sheet.dart';
import 'home/tank_hero.dart';
import 'home/home_banners.dart';
import 'home/pump_controls.dart';
import 'home/home_header.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  /// Looks for updates every [updateCheckInterval] while the app is in the
  /// foreground, so an app left open for days still finds new releases.
  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _startUpdateChecks());
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _checkForUpdates() {
    if (!mounted) return;
    context.read<PumpFirmwareUpdate>().checkForUpdates();
    context.read<TankFirmwareUpdate>().checkForUpdates();
    context.read<AppSelfUpdate>().checkForUpdates();
  }

  /// Checks now (skipped if checked in the last few minutes), then on a timer.
  void _startUpdateChecks() {
    _checkForUpdates();
    _updateTimer?.cancel();
    _updateTimer = Timer.periodic(
      updateCheckInterval,
      (_) => _checkForUpdates(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      context.read<PumpSession>().onAppResumed();
      _startUpdateChecks();
    } else if (state == AppLifecycleState.paused) {
      _updateTimer?.cancel();
      _updateTimer = null;
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
      if (session.connected && session.protocolMismatch) return 'Update needed';
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
    final ready = session.ready;
    final linked = session.authed && session.connected;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TopBar(
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
              if (pump == null) ...[
                // App updates don't need a pump.
                const HomeUpdateBannerSection(),
                Expanded(child: EmptyState(scheme: scheme)),
              ] else ...[
                const SizedBox(height: 10),
                PumpHeader(
                  pump: pump,
                  connecting: session.connecting,
                  connected: ready,
                  bleRssiDbm: session.connected ? session.bleRssiDbm : null,
                  overWifi: session.link == LinkKind.wifi,
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
                if (ready && session.multiTank) ...[
                  const SizedBox(height: 10),
                  TankChips(session: session),
                ],
                const HomeUpdateBannerSection(),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (session.connectFailed &&
                            !session.connecting &&
                            !session.connected) ...[
                          ConnectFailedBanner(session: session),
                          const SizedBox(height: 8),
                        ],
                        if (linked && session.protocolMismatch) ...[
                          ProtocolMismatchBanner(session: session),
                          const SizedBox(height: 8),
                        ],
                        if (ready && session.fillInterruption != null) ...[
                          FillInterruptedBanner(
                            event: session.fillInterruption!,
                            onDismiss: session.dismissFillInterruption,
                          ),
                          const SizedBox(height: 8),
                        ],
                        if (ready &&
                            session.clockLostPower &&
                            !session.clockLostDismissed) ...[
                          ClockBatteryBanner(
                            onDismiss: session.dismissClockLost,
                          ),
                          const SizedBox(height: 8),
                        ],
                        if (ready && session.pumpErrorTitle != null) ...[
                          PumpErrorBanner(session: session),
                          const SizedBox(height: 8),
                        ],
                        if (ready && session.tankFaultTitle != null) ...[
                          TankFaultBanner(session: session),
                          const SizedBox(height: 8),
                        ],
                        Expanded(
                          child: TankHero(session: session, ready: ready),
                        ),
                      ],
                    ),
                  ),
                ),
                PumpControls(
                  session: session,
                  ready: ready,
                  linked: linked,
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
