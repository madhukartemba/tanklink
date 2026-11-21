import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble/pump_session.dart';
import '../diag/app_log.dart';
import '../diag/report_builder.dart';
import '../diag/report_sender.dart';
import '../util/nav.dart';

/// Opens "Report a problem", pre-filled with [problem] when it comes from an
/// error banner or a failed update.
Future<void> openReportScreen(
  BuildContext context, [
  ReportProblem problem = ReportProblem.manual,
]) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ReportProblemScreen(problem: problem),
    ),
  );
}

/// Route for callers that close a dialog first and so can't use a context.
Route<void> reportRoute(ReportProblem problem) => MaterialPageRoute<void>(
  builder: (_) => ReportProblemScreen(problem: problem),
);

class ReportProblemScreen extends StatefulWidget {
  const ReportProblemScreen({super.key, required this.problem});

  final ReportProblem problem;

  @override
  State<ReportProblemScreen> createState() => _ReportProblemScreenState();
}

enum _When { now, today, earlier }

class _ReportProblemScreenState extends State<ReportProblemScreen> {
  final _desc = TextEditingController();
  final _email = TextEditingController();
  _When _when = _When.now;
  bool _withLog = true;
  bool _withPump = true;
  bool _withPhone = true;
  bool _busy = false;
  String? _error;

  bool get _manual => widget.problem.kind == 'manual';

  @override
  void initState() {
    super.initState();
    _desc.addListener(() => setState(() {}));
    _email.addListener(() => setState(() {}));
    _loadEmail();
  }

  static const _emailKey = 'report_contact_email';

  Future<void> _loadEmail() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_emailKey) ?? '';
    if (mounted && _email.text.isEmpty) _email.text = saved;
  }

  /// Remembered for the next report; cleared when the field is emptied.
  Future<void> _saveEmail() async {
    final prefs = await SharedPreferences.getInstance();
    final e = _email.text.trim();
    if (e.isEmpty) {
      await prefs.remove(_emailKey);
    } else {
      await prefs.setString(_emailKey, e);
    }
  }

  @override
  void dispose() {
    _desc.dispose();
    _email.dispose();
    super.dispose();
  }

  bool get _emailOk => isPlausibleEmail(_email.text);

  bool get _canSend =>
      !_busy && _emailOk && (!_manual || _desc.text.trim().isNotEmpty);

  Future<BuiltReport> _build() async {
    final session = context.read<PumpSession>();
    final pkg = await PackageInfo.fromPlatform();
    final connected = session.connected && session.authed;
    return buildReport(
      description: _desc.text,
      problem: widget.problem,
      when: _manual ? _whenLabel(_when) : '',
      contactEmail: _email.text,
      now: DateTime.now(),
      versions: ReportVersions(
        app: '${pkg.version}+${pkg.buildNumber}',
        pump: connected ? session.firmware : '',
        tank: connected ? session.tankFw : '',
        pumpProto: connected
            ? '${session.pumpProtoMajor}.${session.pumpProtoMinor}'
            : '',
        pumpHwRev: session.pumpHwRev,
        tankHwRev: session.tankHwRev,
      ),
      phone: _withPhone ? await _phoneDetails() : const {},
      pumpState: _withPump ? _pumpState(session) : const {},
      appLog: _withLog ? await AppLog.recentText() : null,
      secrets: _secrets(session),
    );
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    // Any failure must end with the button usable again and a message.
    try {
      final report = await _build();
      await _saveEmail();
      final String id;
      try {
        id = await ReportSender.send(report);
      } on ReportSendException catch (e) {
        if (!e.retryable) {
          _fail('${e.message}. You can still save or share it as a file.');
          return;
        }
        await ReportSender.enqueue(report);
        // A dialog, not a snackbar: this screen is often opened from the
        // settings sheet, which would cover a snackbar on the home screen.
        await _doneDialog(
          'Saved for later',
          '${e.message}. The report is saved on this phone and will be sent '
              'the next time you open the app.',
        );
        return;
      }
      await _doneDialog(
        'Report sent',
        'Thank you. If you get in touch about it, mention this report ID.',
        reportId: id,
      );
    } catch (e, st) {
      AppLog.e('report', 'Send failed', e, st);
      _fail('Couldn’t send the report. You can save or share it as a file.');
    }
  }

  /// Tells the user how it went, then closes this screen.
  Future<void> _doneDialog(
    String title,
    String message, {
    String? reportId,
  }) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            if (reportId != null) ...[
              const SizedBox(height: 16),
              _ReportIdChip(id: reportId),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (mounted) popSelf(context);
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = message;
    });
  }

  Future<void> _share() async {
    setState(() => _busy = true);
    try {
      final report = await _build();
      final dir = await getTemporaryDirectory();
      final path = p.join(dir.path, 'tanklink-report-${_fileStamp()}.txt');
      await File(path).writeAsString(report.text);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path, mimeType: 'text/plain')],
          subject: 'TankLink report: ${report.title}',
        ),
      );
    } catch (e) {
      AppLog.w('report', 'Share failed: $e');
      if (mounted) setState(() => _error = 'Couldn’t share the file');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _preview() async {
    final BuiltReport report;
    try {
      report = await _build();
    } catch (e, st) {
      AppLog.e('report', 'Preview failed', e, st);
      _fail('Couldn’t build the report');
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('What will be sent'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              report.text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final pumpConnected = session.connected && session.authed;
    final canSendOnline = ReportSender.configured;

    return Scaffold(
      appBar: AppBar(title: const Text('Report a problem')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            if (!_manual) ...[
              Material(
                color: scheme.errorContainer.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.problem.title,
                        style: text.titleSmall?.copyWith(
                          color: scheme.onErrorContainer,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (widget.problem.detail != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          widget.problem.detail!,
                          style: text.bodySmall?.copyWith(
                            color: scheme.onErrorContainer,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            TextField(
              controller: _desc,
              minLines: 3,
              maxLines: 8,
              maxLength: 2000,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: _manual
                    ? 'What went wrong?'
                    : 'What were you doing? (optional)',
                alignLabelWithHint: true,
                border: const OutlineInputBorder(),
              ),
            ),
            if (_manual) ...[
              const SizedBox(height: 4),
              Text('When did it happen?', style: text.labelLarge),
              const SizedBox(height: 8),
              SegmentedButton<_When>(
                segments: const [
                  ButtonSegment(value: _When.now, label: Text('Now')),
                  ButtonSegment(value: _When.today, label: Text('Today')),
                  ButtonSegment(value: _When.earlier, label: Text('Earlier')),
                ],
                selected: {_when},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _when = s.first),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: 'Your email (optional)',
                helperText: 'Only used to ask you about this report',
                errorText: _emailOk ? null : 'Check the email address',
                prefixIcon: const Icon(Icons.mail_outline_rounded),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('App log'),
              subtitle: const Text('What the app did recently'),
              value: _withLog,
              onChanged: (v) => setState(() => _withLog = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Pump details'),
              subtitle: Text(
                pumpConnected
                    ? 'Versions, tanks, sensors and errors'
                    : 'Saved pumps and why it isn’t connected',
              ),
              value: _withPump,
              onChanged: (v) => setState(() => _withPump = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Phone details'),
              subtitle: const Text('Model and Android version'),
              value: _withPhone,
              onChanged: (v) => setState(() => _withPhone = v),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ],
            const SizedBox(height: 16),
            if (canSendOnline)
              FilledButton.icon(
                onPressed: _canSend ? _send : null,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_rounded),
                label: const Text('Send report'),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : _preview,
                    child: const Text('Preview'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _canSend ? _share : null,
                    child: const Text('Save or share'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              canSendOnline
                  ? 'Sent to the TankLink developer to fix the problem. '
                        'Passwords, keys and pairing codes are never included.'
                  : 'Save the report as a file and send it to the TankLink '
                        'developer. Keys and pairing codes are never included.',
              style: text.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _whenLabel(_When w) {
  switch (w) {
    case _When.now:
      return 'just now';
    case _When.today:
      return 'earlier today';
    case _When.earlier:
      return 'before today';
  }
}

String _fileStamp() {
  final t = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}';
}

Future<Map<String, String>> _phoneDetails() async {
  final out = <String, String>{};
  try {
    if (Platform.isAndroid) {
      final a = await DeviceInfoPlugin().androidInfo;
      out['Phone'] = '${a.manufacturer} ${a.model}';
      out['Android'] = '${a.version.release} (SDK ${a.version.sdkInt})';
    } else {
      out['OS'] =
          '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    }
  } catch (_) {}
  // adapterStateNow stays "unknown" until the state stream has reported.
  try {
    final state = await FlutterBluePlus.adapterState
        .firstWhere((s) => s != BluetoothAdapterState.unknown)
        .timeout(const Duration(seconds: 2));
    out['Bluetooth'] = state.name;
  } catch (_) {
    out['Bluetooth'] = FlutterBluePlus.adapterStateNow.name;
  }
  return out;
}

/// What the pump last told the app. No tokens; sensor ids shortened.
Map<String, String> _pumpState(PumpSession s) {
  final out = <String, String>{
    'Saved pumps': '${s.pumps.length}',
    'Selected pump': s.selected?.serial ?? 'none',
    'Status line': s.status,
    'Connection': s.connecting
        ? 'connecting'
        : s.connected
        ? (s.authed ? 'connected' : 'connected, not signed in')
        : (s.connectFailed ? 'failed' : 'not connected'),
  };
  if (!(s.connected && s.authed)) return out;
  out.addAll({
    'Running': s.pumpOn ? 'yes (${s.runSeconds}s)' : 'no',
    'Pump error': '${s.pumpLastError}',
    'Tank sensor code': '${s.tankFault}',
    'Selected tank': '${s.activeSlot} (${s.activeTankName})',
    'Tank online': s.tankBound ? (s.tankOnline ? 'yes' : 'no') : 'not paired',
    'Tank last heard': s.tankAgeSec == null ? 'never' : '${s.tankAgeSec}s ago',
    'Tank LoRa': s.tankRssiDbm == null
        ? 'unknown'
        : '${s.tankRssiDbm} dBm, SNR ${s.tankSnrDb} dB',
    'Phone BLE': s.bleRssiDbm == null ? 'unknown' : '${s.bleRssiDbm} dBm',
    'Clock': s.pumpClockValid
        ? '${s.pumpClockHour}:${s.pumpClockMinute.toString().padLeft(2, '0')}'
              '${s.pumpRtcOk ? '' : ' (no clock chip)'}'
        : 'not set',
    'Starter': '${s.starterType}, pulse ${s.relayPulseMs} ms',
    'Schedules': '${s.schedules.where((x) => x.enabled).length} on',
    'Fill notice': s.fillInterruption == null
        ? 'none'
        : 'reason ${s.fillInterruption!.reason}',
  });
  for (final t in s.tanks) {
    out['Tank slot ${t.index}'] =
        '"${t.name}" sensor ${t.sensor} node ${t.node} auto-off ${t.autoOffMin}m';
  }
  for (final x in s.sensors) {
    out['Sensor ${x.index}'] =
        '${shortSensorId(x.idHex)} mode ${x.mode} fw ${x.firmware.isEmpty ? '?' : x.firmware} '
        'battery ${x.batteryPct}% ${x.online ? 'online' : 'offline'} '
        'age ${x.ageSec ?? '-'}s RSSI ${x.rssiDbm} code ${x.fault}';
  }
  final fill = s.fills.isEmpty ? null : s.fills.first;
  if (fill != null) {
    out['Last fill'] =
        'ran ${fill.ranSec}s, started by ${fill.startedBy}, stopped by ${fill.stoppedBy}';
  }
  return out;
}

List<List<int>> _secrets(PumpSession s) => [
  for (final pump in s.pumps) pump.token,
  if (s.tankBleToken != null) s.tankBleToken!,
  for (final x in s.sensors)
    if (x.bleToken != null) x.bleToken!,
];

/// The report ID with a copy button, so the user can quote it later.
class _ReportIdChip extends StatelessWidget {
  const _ReportIdChip({required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
        child: Row(
          children: [
            Expanded(
              child: SelectableText(
                id,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: id));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Report ID copied')),
                  );
                }
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy'),
            ),
          ],
        ),
      ),
    );
  }
}
