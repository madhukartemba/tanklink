import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';
import 'report_builder.dart';

class ReportSendException implements Exception {
  const ReportSendException(this.message, {this.retryable = true});
  final String message;

  /// False when sending again won't help (bad key, report too large).
  final bool retryable;
  @override
  String toString() => message;
}

/// Sends reports to the report service (`report_worker/`), and keeps the
/// ones that couldn't be sent in a small on-disk queue.
class ReportSender {
  ReportSender._();

  /// The report service (`report_worker/`). While either is empty, sending
  /// is off and the screen offers only "Save or share".
  static const endpoint = 'https://tanklink-reports.madhukartemba.in/v1/report';

  /// Must match the Worker's APP_KEY secret. Anyone can read it from the
  /// APK or this repo; it only stops casual spam (the Worker also caps size
  /// and rate). To rotate: `wrangler secret put APP_KEY`, change it here,
  /// release the app. Older apps then get "update the app" when sending.
  static const appKey = 'tl_5437415b257bec1d3f7da7cbf01ec58565ac56ff1315caaf';

  static const _maxQueued = 10;

  static bool get configured => endpoint.isNotEmpty && appKey.isNotEmpty;

  /// Returns the report ID the service gives back.
  static Future<String> send(BuiltReport report) async {
    if (!configured) {
      throw const ReportSendException('Sending isn’t set up', retryable: false);
    }
    final http.Response res;
    try {
      res = await http
          .post(
            Uri.parse(endpoint),
            headers: {'content-type': 'application/json'},
            body: jsonEncode(report.toJson(appKey)),
          )
          .timeout(const Duration(seconds: 25));
    } catch (e) {
      throw const ReportSendException('No connection');
    }
    if (res.statusCode == 200) {
      final id = (jsonDecode(res.body) as Map<String, dynamic>)['id'];
      AppLog.i('report', 'Report sent: $id');
      return '$id';
    }
    AppLog.w('report', 'Report rejected: ${res.statusCode} ${res.body}');
    switch (res.statusCode) {
      case 401:
        throw const ReportSendException(
          'This app version can’t send reports. Update the app.',
          retryable: false,
        );
      case 413:
        throw const ReportSendException(
          'The report is too large to send',
          retryable: false,
        );
      case 429:
        throw const ReportSendException('Too many reports. Try again later.');
      default:
        throw const ReportSendException('The report service had a problem');
    }
  }

  /// Saves [report] to send later. Drops the oldest beyond [_maxQueued].
  static Future<void> enqueue(BuiltReport report) async {
    final dir = await _queueDir();
    final name = '${DateTime.now().millisecondsSinceEpoch}.json';
    await File(p.join(dir.path, name))
        .writeAsString(jsonEncode(report.toJson('')));
    final files = await _queued(dir);
    final extra = files.length - _maxQueued;
    for (var i = 0; i < extra; i++) {
      await files[i].delete();
    }
    AppLog.i(
      'report',
      'Report queued (${files.length - (extra > 0 ? extra : 0)})',
    );
  }

  static Future<int> queuedCount() async {
    try {
      return (await _queued(await _queueDir())).length;
    } catch (_) {
      return 0;
    }
  }

  static bool _sending = false;

  /// Tries every queued report, oldest first. Stops at the first one that
  /// fails for a retryable reason. Returns how many were sent.
  static Future<int> sendQueued() async {
    if (!configured || _sending) return 0;
    _sending = true;
    var sent = 0;
    try {
      for (final f in await _queued(await _queueDir())) {
        final BuiltReport report;
        try {
          report = BuiltReport.fromJson(
            jsonDecode(await f.readAsString()) as Map<String, dynamic>,
          );
        } catch (_) {
          await f.delete();
          continue;
        }
        try {
          await send(report);
          await f.delete();
          sent++;
        } on ReportSendException catch (e) {
          if (e.retryable) break;
          await f.delete();
        }
      }
    } catch (e) {
      AppLog.w('report', 'Sending queued reports failed: $e');
    } finally {
      _sending = false;
    }
    return sent;
  }

  static Future<Directory> _queueDir() async {
    final dir = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'report_queue'),
    );
    await dir.create(recursive: true);
    return dir;
  }

  static Future<List<File>> _queued(Directory dir) async {
    final files = await dir
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }
}
