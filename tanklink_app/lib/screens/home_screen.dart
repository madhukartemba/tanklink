import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../ble/pump_session.dart';
import '../update/app_self_update.dart';
import '../update/home_update_banner.dart';
import '../update/firmware_update.dart';
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<PumpFirmwareUpdate>().checkForUpdates();
      context.read<TankFirmwareUpdate>().checkForUpdates();
      context.read<AppSelfUpdate>().checkForUpdates();
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
      context.read<AppSelfUpdate>().checkForUpdates();
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
              if (pump == null)
                Expanded(child: EmptyState(scheme: scheme))
              else ...[
                const SizedBox(height: 10),
                PumpHeader(
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
                if (ready && session.twoTankMode) ...[
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
                        if (ready && session.pumpErrorTitle != null) ...[
                          PumpErrorBanner(session: session),
                          const SizedBox(height: 8),
                        ],
                        Expanded(
                          child: TankHero(
                            session: session,
                            ready: ready,
                            onOpenSettings: () =>
                                showPumpSettingsSheet(context),
                          ),
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
