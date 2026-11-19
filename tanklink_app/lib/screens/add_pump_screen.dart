import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../ble/pump_session.dart';
import 'pair_tank_prompt_screen.dart';
import '../diag/app_log.dart';
import '../diag/report_builder.dart';
import 'report_problem_screen.dart';

class AddPumpScreen extends StatefulWidget {
  const AddPumpScreen({super.key});

  @override
  State<AddPumpScreen> createState() => _AddPumpScreenState();
}

class _AddPumpScreenState extends State<AddPumpScreen> {
  PumpSession? _session;

  /// Remote id of the pump being claimed; its row shows a spinner and the
  /// other rows can't be tapped meanwhile.
  String? _claimingId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _session = context.read<PumpSession>();
      _session!.startScan();
    });
  }

  @override
  void dispose() {
    _session?.stopScan();
    super.dispose();
  }

  /// A pump that is already saved isn't claimed again (that fails); it is
  /// opened on the home screen instead.
  Future<void> _open(SavedPump pump) async {
    final session = context.read<PumpSession>();
    Navigator.of(context).popUntil((route) => route.isFirst);
    await session.selectPump(pump);
  }

  Future<void> _claim(int index) async {
    final session = context.read<PumpSession>();
    final device = session.scanResults[index].device;
    setState(() => _claimingId = device.remoteId.str);
    try {
      await session.claimDevice(device);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added ${session.selected?.name ?? 'pump'}')),
      );
      // Tank status is read during connect; prompt if this pump has no tank yet.
      if (!session.tankBound) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(builder: (_) => const PairTankPromptScreen()),
        );
        if (!mounted) return;
      }
      Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e) {
      AppLog.w('pump', 'Add pump failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Couldn’t add pump: $e'),
          action: SnackBarAction(
            label: 'Report',
            onPressed: () => openReportScreen(
              context,
              ReportProblem(
                kind: 'add-pump',
                title: 'Couldn’t add pump',
                detail: '$e',
                seenAt: DateTime.now(),
              ),
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _claimingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Add pump'),
        actions: [
          IconButton(
            tooltip: 'Scan again',
            onPressed: session.scanning || _claimingId != null
                ? null
                : () => session.startScan(),
            icon: session.scanning
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Text(
              session.scanning
                  ? 'Looking for TankLink pumps nearby…'
                  : session.scanResults.isEmpty
                  ? 'Nothing found. Hold the pump button 5s for pairing, then scan again.'
                  : 'Tap a pump to claim it.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
          if (!session.scanning && session.scanResults.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => openReportScreen(
                    context,
                    ReportProblem(
                      kind: 'add-pump',
                      title: 'Pump not found when adding',
                      seenAt: DateTime.now(),
                    ),
                  ),
                  icon: const Icon(Icons.bug_report_outlined, size: 18),
                  label: const Text('Still can’t find it? Report a problem'),
                ),
              ),
            ),
          Expanded(
            child: session.scanResults.isEmpty
                ? Center(
                    child: session.scanning
                        ? const CircularProgressIndicator()
                        : Icon(
                            Icons.bluetooth_searching,
                            size: 48,
                            color: scheme.onSurfaceVariant,
                          ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: session.scanResults.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final r = session.scanResults[i];
                      final name = r.advertisementData.advName.isNotEmpty
                          ? r.advertisementData.advName
                          : 'TankLink device';
                      final id = r.device.remoteId.str;
                      final saved = session.pumps
                          .where((p) => p.remoteId == id)
                          .firstOrNull;
                      final claiming = _claimingId == id;
                      final busy = _claimingId != null;
                      return Material(
                        color: scheme.surfaceContainerHighest.withValues(
                          alpha: 0.55,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 6,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          leading: CircleAvatar(
                            backgroundColor: scheme.primaryContainer,
                            child: Icon(
                              Icons.water_drop,
                              color: scheme.onPrimaryContainer,
                            ),
                          ),
                          title: Text(
                            name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: claiming
                              ? Text(
                                  session.status,
                                  style: TextStyle(color: scheme.primary),
                                )
                              : saved != null
                              ? Text(
                                  'Already added · tap to open',
                                  style: TextStyle(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                )
                              : null,
                          trailing: claiming
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                  ),
                                )
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _SignalBars(rssi: r.rssi),
                                    const SizedBox(width: 8),
                                    Icon(
                                      saved != null
                                          ? Icons.check_circle_outline_rounded
                                          : Icons.chevron_right_rounded,
                                    ),
                                  ],
                                ),
                          enabled: !busy || claiming,
                          onTap: busy
                              ? null
                              : saved != null
                              ? () => _open(saved)
                              : () => _claim(i),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Classic 4-bar BLE signal indicator from RSSI (dBm).
class _SignalBars extends StatelessWidget {
  const _SignalBars({required this.rssi});

  final int rssi;

  int get _level {
    if (rssi >= -55) return 4;
    if (rssi >= -65) return 3;
    if (rssi >= -75) return 2;
    if (rssi >= -85) return 1;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final level = _level;
    const heights = [6.0, 10.0, 14.0, 18.0];

    return Tooltip(
      message: 'Signal strength',
      child: SizedBox(
        width: 22,
        height: 18,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (var i = 0; i < 4; i++)
              Container(
                width: 3.5,
                height: heights[i],
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(1),
                  color: i < level
                      ? scheme.primary
                      : scheme.outlineVariant.withValues(alpha: 0.55),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
