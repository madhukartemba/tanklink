import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../ble/pump_session.dart';
import 'pump_firmware_update.dart' show FwUpdatePhase;
import 'tank_firmware_update.dart';

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

Future<void> showTankFirmwareConfirmSheet(BuildContext context) async {
  final session = context.read<PumpSession>();
  final fw = context.read<TankFirmwareUpdate>();
  final latest = fw.latestVersion ?? '—';
  final current = session.tankFw.isEmpty ? '—' : session.tankFw;
  final size = fw.bytesTotal > 0 ? _fmtBytes(fw.bytesTotal) : '—';
  final ready = session.authed && session.connected && session.tankOtaReady;

  final action = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
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
              'Update tank firmware',
              style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
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
            Text('Size · $size', style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            _Bullet(
              icon: Icons.touch_app_rounded,
              text:
                  'Press the button once on the tank sensor to start the update',
            ),
            const _Bullet(
              icon: Icons.bluetooth_rounded,
              text: 'Stay near the tank — Bluetooth only works during that window',
            ),
            const _Bullet(
              icon: Icons.battery_std_rounded,
              text: 'Prefer a healthy tank battery before updating',
            ),
            if (!session.tankOtaReady) ...[
              const SizedBox(height: 8),
              Text(
                'Re-pair the tank sensor first so the phone can authenticate OTA.',
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
                !session.tankOtaReady ? 'Re-pair tank first' : 'Update now',
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
    await runTankFirmwareUpdate(context);
  }
}

Future<void> runTankFirmwareUpdate(BuildContext context) async {
  final session = context.read<PumpSession>();
  final fw = context.read<TankFirmwareUpdate>();

  if (!(session.authed && session.connected)) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Connect to the pump first')),
    );
    return;
  }
  if (!session.tankOtaReady) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Re-pair the tank sensor to enable updates')),
    );
    return;
  }

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => const _TankOtaProgressDialog(),
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
  const _TankOtaProgressDialog();

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
                value: (fw.phase == FwUpdatePhase.verifying ||
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
              const Text('Tank will wake on the next heartbeat or button press.'),
          ],
        ),
        actions: [
          if (failed)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
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

class TankFirmwareUpdateBanner extends StatelessWidget {
  const TankFirmwareUpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final fw = context.watch<TankFirmwareUpdate>();
    if (!(session.authed && session.connected && session.tankBound)) {
      return const SizedBox.shrink();
    }
    // Need a live tank reading + OTA token; 0.0.0 / offline must not prompt.
    if (!session.tankOnline || !session.tankOtaReady) {
      return const SizedBox.shrink();
    }
    if (!fw.showHomeBanner(session.tankFw)) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final current = session.tankFw.isEmpty ? '—' : session.tankFw;
    final latest = fw.latestVersion ?? '';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: scheme.tertiary.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Row(
            children: [
              Icon(Icons.sensors, color: scheme.tertiary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Tank update available',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: scheme.tertiary,
                      ),
                    ),
                    Text(
                      '$current → $latest',
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton.tonal(
                onPressed: () => showTankFirmwareConfirmSheet(context),
                child: const Text('Update'),
              ),
              IconButton(
                tooltip: 'Dismiss',
                onPressed: () => fw.snoozeLatest(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
