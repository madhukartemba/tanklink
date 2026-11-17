import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_install.dart';
import 'app_self_update.dart';
import 'firmware_update.dart' show FwUpdatePhase;

String _fmtBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
  return '${(n / (1024 * 1024)).toStringAsFixed(2)} MB';
}

Future<void> showAppUpdateConfirmSheet(BuildContext context) async {
  final app = context.read<AppSelfUpdate>();
  final latest = app.latestVersion ?? '—';
  final current = app.installedVersion ?? '—';
  final size = app.bytesTotal > 0 ? _fmtBytes(app.bytesTotal) : '—';

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
              'Update TankLink app',
              style: Theme.of(ctx).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text(
              'Android will ask to install the update. Allow “Install unknown apps” for TankLink if prompted.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Row(
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
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.arrow_forward_rounded),
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
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Download size: $size',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'update'),
              child: Text('Download and install $latest'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'later'),
              child: const Text('Later'),
            ),
          ],
        ),
      );
    },
  );

  if (!context.mounted) return;
  if (action == 'later') {
    await app.snoozeLatest();
    return;
  }
  if (action == 'update') {
    await runAppSelfUpdate(context);
  }
}

Future<void> runAppSelfUpdate(BuildContext context) async {
  if (!Platform.isAndroid) return;
  final app = context.read<AppSelfUpdate>();

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => const _AppUpdateProgressDialog(),
  );

  try {
    final path = await app.ensureApkDownloaded();
    if (!context.mounted) return;
    Navigator.of(context).pop();
    await AppInstall.installApk(path);
    app.setDone();
  } catch (e) {
    app.setError(e.toString());
    if (context.mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('App update failed: ${app.errorMessage ?? e}')),
      );
    }
  } finally {
    app.resetPhase();
  }
}

class _AppUpdateProgressDialog extends StatelessWidget {
  const _AppUpdateProgressDialog();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppSelfUpdate>();
    final progress = app.bytesTotal > 0 ? app.bytesDone / app.bytesTotal : null;
    return AlertDialog(
      title: const Text('Downloading app update…'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (progress != null) LinearProgressIndicator(value: progress),
          const SizedBox(height: 12),
          Text(
            '${_fmtBytes(app.bytesDone)} / ${_fmtBytes(app.bytesTotal)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (app.phase == FwUpdatePhase.error)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                app.errorMessage ?? 'Download failed',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}
