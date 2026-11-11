import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../ble/pump_session.dart';
import 'pump_firmware_update.dart';

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

Future<void> showFirmwareConfirmSheet(BuildContext context) async {
  final session = context.read<PumpSession>();
  final fw = context.read<PumpFirmwareUpdate>();
  final latest = fw.latestVersion ?? '—';
  final current = session.firmware.isEmpty ? '—' : session.firmware;
  final size = fw.bytesTotal > 0 ? _fmtBytes(fw.bytesTotal) : '—';
  final ready = session.authed && session.connected;
  final running = session.pumpOn;

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
              'Update pump firmware',
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
              icon: Icons.power_settings_new_rounded,
              text: running
                  ? 'Stop the pump before updating'
                  : 'Pump must stay stopped during the update',
            ),
            const _Bullet(
              icon: Icons.bluetooth_rounded,
              text: 'Stay within Bluetooth range of the pump',
            ),
            const _Bullet(
              icon: Icons.schedule_rounded,
              text: 'Usually takes 1–4 minutes',
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: !ready || running
                  ? null
                  : () => Navigator.pop(ctx, 'update'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              child: Text(
                running ? 'Stop pump first' : 'Update now',
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
    await runFirmwareUpdate(context, fromRelease: true);
  }
}

Future<void> runFirmwareUpdate(
  BuildContext context, {
  required bool fromRelease,
  Uint8List? localBytes,
}) async {
  final session = context.read<PumpSession>();
  final fw = context.read<PumpFirmwareUpdate>();

  if (!(session.authed && session.connected)) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Connect to the pump first')),
    );
    return;
  }
  if (session.pumpOn) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Stop the pump before updating')),
    );
    return;
  }

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _OtaProgressDialog(
      fromRelease: fromRelease,
      localBytes: localBytes,
    ),
  );
  fw.resetPhase();
}

Future<void> pickAndInstallFirmware(BuildContext context) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.any,
    withData: true,
  );
  if (result == null || result.files.isEmpty) return;
  final file = result.files.first;
  Uint8List? bytes = file.bytes;
  if (bytes == null && file.path != null) {
    bytes = await File(file.path!).readAsBytes();
  }
  if (bytes == null || bytes.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn’t read that file')),
      );
    }
    return;
  }
  if (!context.mounted) return;
  await runFirmwareUpdate(context, fromRelease: false, localBytes: bytes);
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

class _OtaProgressDialog extends StatefulWidget {
  const _OtaProgressDialog({
    required this.fromRelease,
    this.localBytes,
  });

  final bool fromRelease;
  final Uint8List? localBytes;

  @override
  State<_OtaProgressDialog> createState() => _OtaProgressDialogState();
}

class _OtaProgressDialogState extends State<_OtaProgressDialog> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final session = context.read<PumpSession>();
    final fw = context.read<PumpFirmwareUpdate>();
    HapticFeedback.mediumImpact();
    await WakelockPlus.enable();
    try {
      late Uint8List image;
      if (widget.fromRelease) {
        image = await fw.ensureBinaryDownloaded();
      } else {
        image = widget.localBytes!;
      }

      fw.beginTransfer(image.length);
      await session.otaUpdate(
        image,
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
    final fw = context.watch<PumpFirmwareUpdate>();
    final scheme = Theme.of(context).colorScheme;
    final progress = fw.bytesTotal > 0 ? fw.bytesDone / fw.bytesTotal : null;
    final failed = fw.phase == FwUpdatePhase.error;
    final done = fw.phase == FwUpdatePhase.done;

    String title;
    switch (fw.phase) {
      case FwUpdatePhase.download:
        title = 'Downloading firmware…';
      case FwUpdatePhase.preparing:
        title = 'Preparing update…';
      case FwUpdatePhase.transfer:
        title = 'Updating pump…';
      case FwUpdatePhase.verifying:
        title = 'Verifying…';
      case FwUpdatePhase.rebooting:
        title = 'Restarting pump…';
      case FwUpdatePhase.done:
        title = 'Update complete';
      case FwUpdatePhase.error:
        title = 'Update failed';
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
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Icon(Icons.near_me_rounded, color: scheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Stay near the pump — don’t lock the phone or walk away until this finishes.',
                        style: TextStyle(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (done)
              Text(
                'Now running ${context.read<PumpSession>().firmware.isEmpty ? 'the new firmware' : 'v${context.read<PumpSession>().firmware}'}.',
              ),
            if (failed) ...[
              Text(fw.errorMessage ?? 'Something went wrong'),
              const SizedBox(height: 8),
              Text(
                'The pump kept its previous firmware. You can retry.',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              ),
            ],
          ],
        ),
        actions: [
          if (failed) ...[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                runFirmwareUpdate(
                  context,
                  fromRelease: widget.fromRelease,
                  localBytes: widget.localBytes,
                );
              },
              child: const Text('Retry'),
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

/// Home banner when a newer release is available.
class FirmwareUpdateBanner extends StatelessWidget {
  const FirmwareUpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final fw = context.watch<PumpFirmwareUpdate>();
    if (!(session.authed && session.connected)) {
      return const SizedBox.shrink();
    }
    if (!fw.showHomeBanner(session.firmware)) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Material(
        color: scheme.primary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: () => showFirmwareConfirmSheet(context),
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                Icon(Icons.system_update_alt_rounded, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Firmware ${fw.latestVersion} available',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: scheme.primary,
                        ),
                      ),
                      Text(
                        'Tap to review and update',
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => showFirmwareConfirmSheet(context),
                  child: const Text('Review'),
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
      ),
    );
  }
}
