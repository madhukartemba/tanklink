import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../ble/pump_session.dart';
import 'firmware_update.dart';
import '../diag/report_builder.dart';
import '../screens/report_problem_screen.dart';

String _fmtBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
  return '${(n / (1024 * 1024)).toStringAsFixed(2)} MB';
}

String _fmtEta(Duration? d) {
  if (d == null) return 'Calculating…';
  final s = d.inSeconds;
  if (s < 60) return 'About ${s}s left';
  final m = s ~/ 60;
  final r = s % 60;
  if (r == 0) return 'About ${m}m left';
  return 'About ${m}m ${r}s left';
}

/// Confirm, then update [sensor] (one of the pump's paired tank sensors).
Future<void> showTankFirmwareConfirmSheet(
  BuildContext context,
  TankSensor sensor,
) async {
  final session = context.read<PumpSession>();
  final fw = context.read<TankFirmwareUpdate>();
  final latest = fw.latestVersion ?? '—';
  final current = sensor.firmware.isEmpty ? '—' : sensor.firmware;
  final size = fw.bytesTotal > 0 ? _fmtBytes(fw.bytesTotal) : '—';
  final ready = session.ready && sensor.otaReady;

  final action = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      return Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          24 + MediaQuery.viewInsetsOf(ctx).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Update sensor #${sensor.shortId}',
              style: Theme.of(ctx).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Current',
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          current,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 18,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.arrow_forward_rounded, color: scheme.primary),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          'New',
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          latest,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 18,
                            color: scheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Size · $size',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            _Bullet(
              icon: Icons.touch_app_rounded,
              text: 'Press the button once on the tank sensor to start the update',
            ),
            const _Bullet(
              icon: Icons.bluetooth_rounded,
              text: 'Stay near the tank — Bluetooth only works during that window',
            ),
            const _Bullet(
              icon: Icons.battery_std_rounded,
              text: 'Prefer a healthy tank battery before updating',
            ),
            if (!sensor.otaReady) ...[
              const SizedBox(height: 8),
              Text(
                'Set up the tank again first, so your phone is allowed to update it.',
                style: TextStyle(color: scheme.error, height: 1.35),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: !ready ? null : () => Navigator.pop(ctx, 'update'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              child: Text(
                !sensor.otaReady ? 'Set up tank again first' : 'Update now',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'snooze'),
              child: const Text('Not now'),
            ),
          ],
        ),
      );
    },
  );

  if (!context.mounted) return;
  if (action == 'snooze') {
    await fw.snoozeLatest();
    return;
  }
  if (action == 'update') {
    await runTankFirmwareUpdate(context, sensor);
  }
}

Future<void> runTankFirmwareUpdate(
  BuildContext context,
  TankSensor sensor,
) async {
  final session = context.read<PumpSession>();
  final fw = context.read<TankFirmwareUpdate>();

  if (!session.ready) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Connect to the pump first')));
    return;
  }
  if (!sensor.otaReady) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Set up the tank sensor again to allow updates'),
      ),
    );
    return;
  }

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _TankOtaProgressDialog(sensor: sensor),
  );
  fw.resetPhase();
}

class _Bullet extends StatelessWidget {
  const _Bullet({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _TankOtaProgressDialog extends StatefulWidget {
  const _TankOtaProgressDialog({required this.sensor});

  final TankSensor sensor;

  @override
  State<_TankOtaProgressDialog> createState() => _TankOtaProgressDialogState();
}

class _TankOtaProgressDialogState extends State<_TankOtaProgressDialog> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final session = context.read<PumpSession>();
    final fw = context.read<TankFirmwareUpdate>();
    HapticFeedback.mediumImpact();
    await WakelockPlus.enable();
    try {
      final image = await fw.ensureBinaryDownloaded();
      fw.setScanning();
      fw.beginTransfer(image.length);
      await session.otaUpdateTank(
        image,
        sensor: widget.sensor,
        onScanning: fw.setScanning,
        onProgress: fw.setTransferProgress,
        onVerifying: fw.setVerifying,
        onRebooting: fw.setRebooting,
      );
      fw.setDone();
      HapticFeedback.heavyImpact();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      fw.setError(e.toString().replaceFirst('Bad state: ', ''));
      HapticFeedback.heavyImpact();
    } finally {
      await WakelockPlus.disable();
    }
  }

  @override
  Widget build(BuildContext context) {
    final fw = context.watch<TankFirmwareUpdate>();
    final scheme = Theme.of(context).colorScheme;
    final progress = fw.bytesTotal > 0 ? fw.bytesDone / fw.bytesTotal : null;
    final failed = fw.phase == FwUpdatePhase.error;
    final done = fw.phase == FwUpdatePhase.done;

    String title;
    switch (fw.phase) {
      case FwUpdatePhase.download:
        title = 'Downloading tank firmware…';
      case FwUpdatePhase.preparing:
        title = 'Waiting for tank button press…';
      case FwUpdatePhase.transfer:
        title = 'Updating tank…';
      case FwUpdatePhase.verifying:
        title = 'Verifying…';
      case FwUpdatePhase.rebooting:
        title = 'Restarting tank…';
      case FwUpdatePhase.done:
        title = 'Tank update complete';
      case FwUpdatePhase.error:
        title = 'Tank update failed';
      default:
        title = 'Starting…';
    }

    return PopScope(
      canPop: failed || done,
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!failed && !done) ...[
              LinearProgressIndicator(
                value:
                    (fw.phase == FwUpdatePhase.verifying ||
                        fw.phase == FwUpdatePhase.rebooting ||
                        fw.phase == FwUpdatePhase.preparing)
                    ? null
                    : progress,
                minHeight: 8,
                borderRadius: BorderRadius.circular(8),
              ),
              const SizedBox(height: 12),
              if (fw.phase == FwUpdatePhase.preparing)
                Text(
                  'Press the button once on the tank sensor',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              if (fw.phase == FwUpdatePhase.transfer ||
                  fw.phase == FwUpdatePhase.download) ...[
                Text(
                  '${(100 * (progress ?? 0)).clamp(0, 100).toStringAsFixed(0)}%'
                  ' · ${_fmtBytes(fw.bytesDone)} / ${_fmtBytes(fw.bytesTotal)}',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 4),
                Text(
                  _fmtEta(fw.eta),
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
            if (failed)
              Text(
                fw.errorMessage ?? 'Update failed',
                style: TextStyle(color: scheme.error),
              ),
            if (done)
              const Text('The tank wakes up when you press its button.'),
          ],
        ),
        actions: [
          if (failed) ...[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
            TextButton(
              onPressed: () {
                final nav = Navigator.of(context);
                nav.pop();
                nav.push(
                  reportRoute(
                    ReportProblem(
                      kind: 'tank-update',
                      title: 'Tank update failed',
                      detail: fw.errorMessage,
                      seenAt: DateTime.now(),
                    ),
                  ),
                );
              },
              child: const Text('Report'),
            ),
          ],
          if (done)
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
        ],
      ),
    );
  }
}
