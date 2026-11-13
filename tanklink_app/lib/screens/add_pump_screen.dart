import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ble/pump_session.dart';
import 'pair_tank_prompt_screen.dart';

class AddPumpScreen extends StatefulWidget {
  const AddPumpScreen({super.key});

  @override
  State<AddPumpScreen> createState() => _AddPumpScreenState();
}

class _AddPumpScreenState extends State<AddPumpScreen> {
  PumpSession? _session;

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

  Future<void> _claim(int index) async {
    final session = context.read<PumpSession>();
    final device = session.scanResults[index].device;
    try {
      await session.claimDevice(device);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added ${session.selected?.name ?? 'pump'}')),
      );
      // Tank status is read during connect; prompt if this pump has no tank yet.
      if (!session.tankBound) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const PairTankPromptScreen(),
          ),
        );
        if (!mounted) return;
      }
      Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Couldn’t add pump: $e')),
      );
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
            onPressed: session.scanning ? null : () => session.startScan(),
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
                      ? 'Nothing found. Hold Start and Stop together 5s for pairing, then scan again.'
                      : 'Tap a pump to claim it.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: session.scanResults.isEmpty
                ? Center(
                    child: session.scanning
                        ? const CircularProgressIndicator()
                        : Icon(Icons.bluetooth_searching,
                            size: 48, color: scheme.onSurfaceVariant),
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
                      final known = session.pumps.any(
                        (p) => p.remoteId == r.device.remoteId.str,
                      );
                      return Material(
                        color: scheme.surfaceContainerHighest
                            .withValues(alpha: 0.55),
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
                            child: Icon(Icons.water_drop,
                                color: scheme.onPrimaryContainer),
                          ),
                          title: Text(
                            name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: known
                              ? Text(
                                  'Already saved',
                                  style: TextStyle(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                )
                              : null,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _SignalBars(rssi: r.rssi),
                              const SizedBox(width: 8),
                              const Icon(Icons.chevron_right_rounded),
                            ],
                          ),
                          onTap: () => _claim(i),
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
