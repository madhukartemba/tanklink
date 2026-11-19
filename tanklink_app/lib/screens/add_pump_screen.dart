import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../ble/protocol.dart';
import '../ble/pump_session.dart';
import 'pair_tank_prompt_screen.dart';
import 'pairing_wait_sheet.dart';
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

  /// The pump refused the claim: its pairing window isn't open.
  static bool _notInPairingMode(Object e) =>
      '$e'.contains('WRITE_NOT_PERMITTED');

  Future<void> _claim(int index) async {
    final session = context.read<PumpSession>();
    final r = session.scanResults[index];
    final device = r.device;
    final id = device.remoteId.str;
    final name = _nameOf(r);
    final state = pumpAdvState(r.advertisementData.manufacturerData);

    // Not in pairing mode: show how, and wait for it before connecting.
    if (state == PumpAdvState.notReady &&
        !await showPairingWaitSheet(
          context,
          remoteId: id,
          name: name,
          canDetect: true,
        )) {
      return;
    }
    if (!mounted) return;

    setState(() => _claimingId = id);
    try {
      try {
        await session.claimDevice(device);
      } catch (e) {
        // The window closed meanwhile, or older firmware that doesn't
        // advertise its state: guide the user, then try once more.
        if (!_notInPairingMode(e) || !mounted) rethrow;
        AppLog.i('pump', 'Claim refused: not in pairing mode');
        setState(() => _claimingId = null);
        final again = await showPairingWaitSheet(
          context,
          remoteId: id,
          name: name,
          canDetect: state != PumpAdvState.unknown,
        );
        if (!again || !mounted) return;
        setState(() => _claimingId = id);
        await session.claimDevice(device);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar() // an earlier failure's message
        ..showSnackBar(
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
      // The snackbar can outlive this screen (a retry that works closes
      // it), so Report uses the app's root navigator, not this context.
      final nav = Navigator.of(context, rootNavigator: true);
      final problem = ReportProblem(
        kind: 'add-pump',
        title: 'Couldn’t add pump',
        detail: '$e',
        seenAt: DateTime.now(),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_addFailedText(e)),
          action: SnackBarAction(
            label: 'Report',
            onPressed: () => nav.push(reportRoute(problem)),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _claimingId = null);
    }
  }

  /// Plain words for the snackbar; the full error goes in the report.
  static String _addFailedText(Object e) {
    final s = '$e';
    if (s.contains('connect') ||
        s.contains('disconnected') ||
        s.contains('TimeoutException')) {
      return 'Couldn’t connect to the pump. Move closer and try again.';
    }
    if (_notInPairingMode(e)) {
      return 'The pump isn’t in pairing mode.';
    }
    return 'Couldn’t add the pump. Try again.';
  }

  static String _nameOf(ScanResult r) => r.advertisementData.advName.isNotEmpty
      ? r.advertisementData.advName
      : 'TankLink device';

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
                  ? 'Nothing found. Check the pump has power and is nearby, '
                        'then scan again.'
                  : 'Tap a pump to add it.',
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
                      final name = _nameOf(r);
                      final adv = pumpAdvState(
                        r.advertisementData.manufacturerData,
                      );
                      final id = r.device.remoteId.str;
                      final known = session.pumps
                          .where((p) => p.remoteId == id)
                          .firstOrNull;
                      // Signed out of this pump: add it again, don't open it.
                      final signedOut =
                          known != null &&
                          session.authRejected &&
                          session.selectedRemoteId == id;
                      final saved = signedOut ? null : known;
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
                              : signedOut
                              ? Text(
                                  'Signed out · tap to add again',
                                  style: TextStyle(color: scheme.error),
                                )
                              : adv == PumpAdvState.ready
                              ? Text(
                                  'Ready to add',
                                  style: TextStyle(color: scheme.primary),
                                )
                              : adv == PumpAdvState.notReady
                              ? Text(
                                  'Not in pairing mode · tap for help',
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
