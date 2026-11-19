import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The app's own log: INFO, WARN and ERROR lines in two rotating files in the
/// app support dir, plus the newest lines in memory. Read by "Report a
/// problem". Never log tokens or raw payloads.
class AppLog {
  AppLog._();

  static const _maxFileBytes = 256 * 1024;
  static const _memLines = 500;

  static final List<String> _mem = [];
  static final List<String> _pending = [];
  static File? _file;
  static File? _old;
  static Timer? _flushTimer;
  static bool _flushing = false;

  static void i(String tag, String msg) => _add('I', tag, msg);
  static void w(String tag, String msg) => _add('W', tag, msg);
  static void e(String tag, String msg, [Object? error, StackTrace? stack]) {
    final b = StringBuffer(msg);
    if (error != null) b.write(': $error');
    if (stack != null) b.write('\n${_trimStack(stack)}');
    _add('E', tag, b.toString());
  }

  /// Opens the log files. Lines logged before this are kept and written.
  static Future<void> init() async {
    try {
      final dir = Directory(
        p.join((await getApplicationSupportDirectory()).path, 'logs'),
      );
      await dir.create(recursive: true);
      _file = File(p.join(dir.path, 'app.log'));
      _old = File(p.join(dir.path, 'app.1.log'));
      _scheduleFlush();
    } catch (err) {
      debugPrintSynchronously('AppLog init failed: $err');
    }
  }

  /// The newest lines from both files (older file first), at most [maxBytes].
  static Future<String> recentText({int maxBytes = 120 * 1024}) async {
    await _flush();
    final parts = <String>[];
    for (final f in [_old, _file]) {
      if (f != null && await f.exists()) {
        parts.add(await f.readAsString());
      }
    }
    var text = parts.isEmpty ? _mem.join('\n') : parts.join();
    if (text.length > maxBytes) {
      text = text.substring(text.length - maxBytes);
      final nl = text.indexOf('\n');
      if (nl >= 0) text = text.substring(nl + 1);
    }
    return text;
  }

  static void _add(String level, String tag, String msg) {
    final line = '${_stamp(DateTime.now())} $level $tag: $msg';
    _mem.add(line);
    if (_mem.length > _memLines) _mem.removeRange(0, _mem.length - _memLines);
    _pending.add(line);
    if (kDebugMode) debugPrintSynchronously(line);
    _scheduleFlush();
  }

  static void _scheduleFlush() {
    if (_file == null || _flushTimer != null) return;
    _flushTimer = Timer(const Duration(seconds: 2), () {
      _flushTimer = null;
      _flush();
    });
  }

  static Future<void> _flush() async {
    final f = _file;
    if (f == null || _pending.isEmpty || _flushing) return;
    _flushing = true;
    final lines = List<String>.of(_pending);
    _pending.clear();
    try {
      if (await f.exists() && await f.length() > _maxFileBytes) {
        await f.rename(_old!.path);
      }
      await f.writeAsString(
        '${lines.join('\n')}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (err) {
      debugPrintSynchronously('AppLog write failed: $err');
    } finally {
      _flushing = false;
    }
    if (_pending.isNotEmpty) _scheduleFlush();
  }

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.$ms';
  }

  static String _trimStack(StackTrace s) => s
      .toString()
      .split('\n')
      .where((l) => l.trim().isNotEmpty)
      .take(12)
      .join('\n');
}
