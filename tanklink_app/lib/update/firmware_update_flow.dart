import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../ble/pump_session.dart';
import '../link/pump_link.dart';
import 'firmware_update.dart';
import '../diag/report_builder.dart';
import '../screens/report_problem_screen.dart';
import '../util/nav.dart';

/// Ways to get a pump update onto the pump, best first.
enum PumpUpdateMethod { pumpDownloads, phoneWifi, bluetooth }

/// The methods that can work right now: the pump's own download needs its
/// Wi-Fi up and an update it found; sending from the phone over Wi-Fi needs
/// the phone to be talking to the pump over Wi-Fi; Bluetooth always works.
List<PumpUpdateMethod> availableUpdateMethods(
  PumpSession session,
  PumpFirmwareUpdate fw,
) {
  final wifi = session.wifiStatus;
  return [
    if (wifi != null &&
        wifi.state == WifiState.connected &&
        wifi.update == PumpUpdateState.available)
      PumpUpdateMethod.pumpDownloads,
    // Sending from the phone needs the release this phone has found.
    if (session.link == LinkKind.wifi && fw.latestBinUrl != null)
      PumpUpdateMethod.phoneWifi,
    PumpUpdateMethod.bluetooth,
  ];
}

String _methodLabel(PumpUpdateMethod m) => switch (m) {
  PumpUpdateMethod.pumpDownloads => 'Let the pump download it',
  PumpUpdateMethod.phoneWifi => 'Send from this phone over Wi-Fi',
  PumpUpdateMethod.bluetooth => 'Send over Bluetooth',
};

String _methodHint(PumpUpdateMethod m) => switch (m) {
  PumpUpdateMethod.pumpDownloads => 'Fastest. Uses the pump’s own Wi-Fi.',
  PumpUpdateMethod.phoneWifi => 'Usually under a minute.',
  PumpUpdateMethod.bluetooth => 'Slower: stay close to the pump.',
};

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
  final latest =
      fw.latestVersion ?? session.wifiStatus?.availableVersion ?? '—';
  final current = session.firmware.isEmpty ? '—' : session.firmware;
  final size = fw.bytesTotal > 0 ? _fmtBytes(fw.bytesTotal) : '—';
  final ready = session.authed && session.connected;
  final running = session.pumpOn;

  final methods = availableUpdateMethods(session, fw);
  final action = await showModalBottomSheet<Object>(
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
              'Update pump firmware',
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
              icon: Icons.power_settings_new_rounded,
              text: running
                  ? 'Stop the pump before updating'
                  : 'Pump must stay stopped during the update',
            ),
            if (methods.first == PumpUpdateMethod.bluetooth)
              const _Bullet(
                icon: Icons.bluetooth_rounded,
                text: 'Stay within Bluetooth range of the pump',
              ),
            _Bullet(
              icon: Icons.schedule_rounded,
              text: methods.first == PumpUpdateMethod.bluetooth
                  ? 'Usually takes 1–4 minutes'
                  : 'Usually takes under a minute',
            ),
            const SizedBox(height: 20),
            for (final m in methods) ...[
              (m == methods.first ? FilledButton.new : OutlinedButton.new)(
                onPressed: !ready || running
                    ? null
                    : () => Navigator.pop(ctx, m),
                style: ButtonStyle(
                  padding: const WidgetStatePropertyAll(
                    EdgeInsets.symmetric(vertical: 14),
                  ),
                  shape: WidgetStatePropertyAll(
                    RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
                child: Column(
                  children: [
                    Text(
                      running ? 'Stop pump first' : _methodLabel(m),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    if (!running)
                      Text(
                        _methodHint(m),
                        style: const TextStyle(fontSize: 12),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
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
  if (action is PumpUpdateMethod) {
    await runFirmwareUpdate(context, fromRelease: true, method: action);
  }
}

Future<void> runFirmwareUpdate(
  BuildContext context, {
  required bool fromRelease,
  Uint8List? localBytes,
  PumpUpdateMethod? method,
}) async {
  final session = context.read<PumpSession>();
  final fw = context.read<PumpFirmwareUpdate>();
  // A file from the phone can't be fetched by the pump itself.
  var how =
      method ??
      availableUpdateMethods(
        session,
        fw,
      ).firstWhere((m) => m != PumpUpdateMethod.pumpDownloads || fromRelease);
  if (!fromRelease && how == PumpUpdateMethod.pumpDownloads) {
    how = PumpUpdateMethod.bluetooth;
  }

  if (!(session.authed && session.connected)) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Connect to the pump first')));
    return;
  }
  if (session.pumpOn) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Stop the pump before updating')),
    );
    return;
  }

  // The dialog returns true for Retry. It can't start the retry itself: its
  // own context is gone once it closes.
  while (true) {
    final retry = await showDialog<Object>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _OtaProgressDialog(
        fromRelease: fromRelease,
        localBytes: localBytes,
        method: how,
      ),
    );
    fw.resetPhase();
    if (!context.mounted) return;
    // Retry (true) or "Try over Bluetooth" (the next method to use).
    if (retry is PumpUpdateMethod) {
      how = retry;
    } else if (retry != true) {
      return;
    }
    if (!(session.authed && session.connected)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connect to the pump first')),
      );
      return;
    }
  }
}

Future<void> pickAndInstallFirmware(BuildContext context) async {
  final file = await FilePicker.pickFile();
  if (file == null) return;
  Uint8List? bytes;
  try {
    bytes = await file.readAsBytes();
  } catch (_) {
    bytes = null;
  }
  if (bytes == null || bytes.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Couldn’t read that file')));
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
    required this.method,
    this.localBytes,
  });

  final bool fromRelease;
  final Uint8List? localBytes;
  final PumpUpdateMethod method;

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
      if (widget.method == PumpUpdateMethod.pumpDownloads) {
        // The pump fetches and checks the image itself; the phone follows.
        final total = fw.bytesTotal;
        fw.beginTransfer(total);
        await session.pumpDownloadsUpdate(
          onProgress: (done) => fw.setTransferProgress(done, total),
          onVerifying: fw.setVerifying,
          onRebooting: fw.setRebooting,
        );
        fw.setDone();
        HapticFeedback.heavyImpact();
        return;
      }
      if (widget.method == PumpUpdateMethod.bluetooth &&
          session.link != LinkKind.bluetooth) {
        await session.forceBluetooth();
      }
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
      // Stays open on "Update complete" until Done: closing it here too
      // raced the Done tap, and the second close popped the home screen.
      fw.setDone();
      HapticFeedback.heavyImpact();
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
              if (widget.method == PumpUpdateMethod.bluetooth)
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
              onPressed: () => popSelf(context),
              child: const Text('Close'),
            ),
            TextButton(
              onPressed: () {
                final nav = Navigator.of(context);
                if (!popSelf(context)) return;
                nav.push(
                  reportRoute(
                    ReportProblem(
                      kind: 'pump-update',
                      title: 'Pump update failed',
                      detail: fw.errorMessage,
                      seenAt: DateTime.now(),
                    ),
                  ),
                );
              },
              child: const Text('Report'),
            ),
            if (widget.method != PumpUpdateMethod.bluetooth)
              TextButton(
                onPressed: () => popSelf(context, PumpUpdateMethod.bluetooth),
                child: const Text('Try over Bluetooth'),
              ),
            FilledButton(
              onPressed: () => popSelf(context, true),
              child: const Text('Retry'),
            ),
          ],
          if (done)
            FilledButton(
              onPressed: () => popSelf(context),
              child: const Text('Done'),
            ),
        ],
      ),
    );
  }
}
