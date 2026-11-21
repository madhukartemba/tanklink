import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_install.dart';
import 'app_self_update.dart';
import 'firmware_update.dart' show FwUpdatePhase;
import '../util/nav.dart';
import '../diag/report_builder.dart';
import '../screens/report_problem_screen.dart';

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

  // Close only this dialog: a blind pop after the download would close
  // whatever is on top, the home screen included.
  BuildContext? dialog;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      dialog = ctx;
      return const PopScope(canPop: false, child: _AppUpdateProgressDialog());
    },
  );
  void closeDialog() {
    final d = dialog;
    if (d != null) popSelf(d);
  }

  try {
    final path = await app.ensureApkDownloaded();
    closeDialog();
    if (!context.mounted) return;
    await AppInstall.installApk(path);
    app.setDone();
  } catch (e) {
    app.setError(e.toString());
    closeDialog();
    if (context.mounted) {
      final message = app.errorMessage ?? '$e';
      final nav = Navigator.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('App update failed: $message'),
          action: SnackBarAction(
            label: 'Report',
            onPressed: () => nav.push(
              reportRoute(
                ReportProblem(
                  kind: 'app-update',
                  title: 'App update failed',
                  detail: message,
                  seenAt: DateTime.now(),
                ),
              ),
            ),
          ),
        ),
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
