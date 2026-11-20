/// Every fill this phone has seen from a pump, kept on the phone.
///
/// The pump only keeps its last 20 fills, which is a week or two. Each time
/// the app reads them it adds the new ones here, so the usage charts can
/// look further back. One file per pump, newest first, capped.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'models.dart';

class FillArchive {
  /// About two years of three fills a day.
  static const maxFills = 2000;

  static Future<File> _file(String pumpId) async {
    final dir = await getApplicationSupportDirectory();
    final safe = pumpId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    return File(p.join(dir.path, 'fills_$safe.json'));
  }

  static String _key(FillRecord f) =>
      '${f.startedAt!.millisecondsSinceEpoch}:${f.slot}:${f.ranSec}';

  static Map<String, Object> _toJson(FillRecord f) => {
    't': f.startedAt!.millisecondsSinceEpoch,
    'r': f.ranSec,
    's': f.slot,
    'b': f.startedBy,
    'x': f.stoppedBy,
  };

  static FillRecord? _fromJson(Object? j) {
    if (j is! Map) return null;
    final t = j['t'], r = j['r'], s = j['s'], b = j['b'], x = j['x'];
    if (t is! int || r is! int || s is! int || b is! int || x is! int) {
      return null;
    }
    return FillRecord(
      startedAt: DateTime.fromMillisecondsSinceEpoch(t),
      ranSec: r,
      slot: s,
      startedBy: b,
      stoppedBy: x,
    );
  }

  /// The saved fills for [pumpId], newest first.
  static Future<List<FillRecord>> load(String pumpId) async {
    try {
      final f = await _file(pumpId);
      if (!await f.exists()) return [];
      final list = jsonDecode(await f.readAsString());
      if (list is! List) return [];
      return list.map(_fromJson).whereType<FillRecord>().toList();
    } catch (_) {
      return [];
    }
  }

  /// Add [fresh] (from the pump) to the saved fills and return them all,
  /// newest first. Fills without a time are not kept.
  static Future<List<FillRecord>> merge(
    String pumpId,
    List<FillRecord> fresh,
  ) async {
    final all = mergeLists(await load(pumpId), fresh);
    try {
      final f = await _file(pumpId);
      await f.writeAsString(jsonEncode(all.map(_toJson).toList()));
    } catch (_) {}
    return all;
  }

  /// Pure part of [merge], unit tested.
  static List<FillRecord> mergeLists(
    List<FillRecord> saved,
    List<FillRecord> fresh,
  ) {
    final byKey = <String, FillRecord>{};
    for (final f in [...saved, ...fresh]) {
      if (f.startedAt == null) continue;
      byKey[_key(f)] = f;
    }
    final all = byKey.values.toList()
      ..sort((a, b) => b.startedAt!.compareTo(a.startedAt!));
    return all.length > maxFills ? all.sublist(0, maxFills) : all;
  }
}
