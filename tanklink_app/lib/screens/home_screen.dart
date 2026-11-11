import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../ble/pump_session.dart';
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
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    'TankLink',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.4,
                        ),
                  ),
                  const Spacer(),
                  IconButton.filledTonal(
                    tooltip: 'Pumps',
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const PumpListScreen(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.list_alt_rounded),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'Add pump',
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const AddPumpScreen(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.add_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (pump == null)
                Expanded(child: _EmptyState(scheme: scheme))
              else ...[
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
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 280),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    layoutBuilder: (currentChild, previousChildren) {
                      return Stack(
                        alignment: Alignment.bottomCenter,
                        children: [
                          ...previousChildren,
                          if (currentChild != null) currentChild,
                        ],
                      );
                    },
                    child: session.pumpOn && ready
                        ? _RunningPanel(
                            key: const ValueKey('running'),
                            statusLine: _statusLine(session, ready),
                            onStop: () => _setPump(false),
                          )
                        : Column(
                            key: const ValueKey('idle'),
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                _statusLine(session, ready),
                                textAlign: TextAlign.center,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                              const SizedBox(height: 20),
                              SlideToStart(
                                enabled: ready,
                                onCompleted: () => _setPump(true),
                              ),
                            ],
                          ),
                  ),
                ),
                const Spacer(),
                if (!ready && !session.connecting)
                  FilledButton(
                    onPressed: () => session.connectSelected(),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                    child: Text(
                      session.connectFailed ? 'Try again' : 'Connect',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                if (session.connecting)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Center(child: CircularProgressIndicator()),
                  ),
              ],
            ],
          ),
        ),
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
        const SizedBox(height: 20),
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
          'Hold the pump button for 5 seconds to enter pairing, then add it here.',
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
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onOpenList,
        onLongPress: onRename,
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          height: kHomeControlHeight,
          child: Padding(
            // Left 16 to status; right 6 + icon pad 10 → same 16 visual inset.
            padding: const EdgeInsets.fromLTRB(16, 0, 6, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: connected
                        ? const Color(0xFF3DDC97)
                        : connecting
                            ? scheme.tertiary
                            : scheme.outline,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pump.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 2),
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
                  style: IconButton.styleFrom(
                    padding: const EdgeInsets.all(10),
                    minimumSize: const Size(44, 44),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.tune_rounded),
                ),
                IconButton(
                  tooltip: 'All pumps',
                  onPressed: onOpenList,
                  style: IconButton.styleFrom(
                    padding: const EdgeInsets.all(10),
                    minimumSize: const Size(44, 44),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.unfold_more_rounded),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
