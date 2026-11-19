import 'dart:convert';
import 'dart:math';

/// What a report is about. Built by the screen or banner that offers the
/// Report button; null fields mean "not known".
class ReportProblem {
  const ReportProblem({
    required this.kind,
    required this.title,
    this.code,
    this.detail,
    this.seenAt,
  });

  /// Short machine name: `pump-err`, `tank-err`, `interrupt`, `connect`,
  /// `pump-update`, `tank-update`, `app-update`, `manual`.
  final String kind;
  final String title;
  final int? code;
  final String? detail;
  final DateTime? seenAt;

  static const manual = ReportProblem(kind: 'manual', title: 'Problem report');
}

/// The finished report: what the user previews, and what the report service
/// needs to file it. The JSON keys are a contract with `report_worker/`.
class BuiltReport {
  const BuiltReport({
    required this.title,
    required this.fingerprint,
    required this.labels,
    required this.summary,
    required this.text,
    this.contact = '',
  });

  final String title;
  final String fingerprint;
  final List<String> labels;
  final String summary;
  final String text;

  /// Email the user gave so the developer can reply. Empty = none.
  final String contact;

  Map<String, Object> toJson(String appKey) => {
    'app_key': appKey,
    'fingerprint': fingerprint,
    'title': title,
    'labels': labels,
    'summary': summary,
    'report_text': text,
    if (contact.isNotEmpty) 'contact': contact,
  };

  factory BuiltReport.fromJson(Map<String, dynamic> j) => BuiltReport(
    title: j['title'] as String,
    fingerprint: j['fingerprint'] as String,
    labels: (j['labels'] as List).cast<String>(),
    summary: j['summary'] as String,
    text: j['report_text'] as String,
    contact: (j['contact'] as String?) ?? '',
  );
}

/// Versions of everything involved. Empty string = unknown / not connected.
class ReportVersions {
  const ReportVersions({
    required this.app,
    this.pump = '',
    this.tank = '',
    this.pumpProto = '',
    this.pumpHwRev = 0,
    this.tankHwRev = 0,
  });

  final String app;
  final String pump;
  final String tank;
  final String pumpProto;
  final int pumpHwRev;
  final int tankHwRev;
}

/// Builds the report text. Pure: everything comes in as arguments.
///
/// [secrets] are byte strings (tokens) that must never appear in the report,
/// in hex, decimal list or base64 form. They are replaced with `[redacted]`.
BuiltReport buildReport({
  required String description,
  required ReportProblem problem,
  required ReportVersions versions,
  required DateTime now,
  Map<String, String> phone = const {},
  Map<String, String> pumpState = const {},
  String? appLog,
  String when = '',
  String contactEmail = '',
  List<List<int>> secrets = const [],
  Random? random,
}) {
  final desc = description.trim();
  final title = problem.kind == 'manual' ? _titleFrom(desc) : problem.title;

  final labels = <String>[
    problem.kind,
    if (problem.code != null) '${problem.kind}-${problem.code}',
    // Version name only: GitHub labels drop the '+' of '1.3.0+21'.
    'app-${versions.app.split('+').first}',
    if (versions.pump.isNotEmpty) 'pump-${versions.pump}',
    if (versions.tank.isNotEmpty) 'tank-${versions.tank}',
  ];

  final fingerprint = problem.kind == 'manual'
      ? 'manual:${_randomTag(random ?? Random.secure())}'
      : [
          problem.kind,
          problem.code ?? '',
          'pump${versions.pump}',
          'tank${versions.tank}',
          if (problem.kind == 'app-update' || problem.kind == 'connect')
            'app${versions.app}',
        ].join(':');

  final versionLine = [
    'App ${versions.app}',
    if (versions.pump.isNotEmpty) 'pump ${versions.pump}',
    if (versions.tank.isNotEmpty) 'tank ${versions.tank}',
  ].join(' · ');

  final summary = StringBuffer()
    ..writeln(desc.isEmpty ? '(no description)' : desc)
    ..writeln()
    ..writeln(versionLine);
  if (problem.kind != 'manual') {
    summary.writeln('Error: ${problem.title}');
  }

  final t = StringBuffer()
    ..writeln('TankLink problem report')
    ..writeln('Created: ${_stamp(now)}')
    ..writeln()
    ..writeln('== What happened ==')
    ..writeln(desc.isEmpty ? '(no description)' : desc);
  if (when.isNotEmpty) t.writeln('When: $when');
  final contact = contactEmail.trim();
  if (contact.isNotEmpty) t.writeln('Contact: $contact');
  t
    ..writeln()
    ..writeln('== Problem ==')
    ..writeln('Kind: ${problem.kind}')
    ..writeln('Title: ${problem.title}');
  if (problem.code != null) t.writeln('Code: ${problem.code}');
  if (problem.detail != null && problem.detail!.isNotEmpty) {
    t.writeln('Detail: ${problem.detail}');
  }
  if (problem.seenAt != null) t.writeln('Seen at: ${_stamp(problem.seenAt!)}');
  t
    ..writeln()
    ..writeln('== Versions ==')
    ..writeln('App: ${versions.app}')
    ..writeln('Pump firmware: ${_or(versions.pump)}')
    ..writeln('Pump protocol: ${_or(versions.pumpProto)}')
    ..writeln('Pump board rev: ${versions.pumpHwRev}')
    ..writeln('Tank firmware: ${_or(versions.tank)}')
    ..writeln('Tank board rev: ${versions.tankHwRev}');
  _section(t, 'Phone', phone);
  _section(t, 'Pump state', pumpState);
  if (appLog != null) {
    t
      ..writeln()
      ..writeln('== App log ==')
      ..writeln(appLog.trimRight());
  }

  return BuiltReport(
    title: title,
    fingerprint: fingerprint,
    labels: labels,
    summary: redact(summary.toString().trimRight(), secrets),
    text: redact(t.toString(), secrets),
    contact: contact,
  );
}

/// Loose check: something@something.tld, no spaces. Empty is allowed.
bool isPlausibleEmail(String s) {
  final e = s.trim();
  return e.isEmpty ||
      (e.length <= 254 && RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(e));
}

/// Replaces every form of each secret: hex (any case, optional `:` or space
/// separators), decimal byte lists like `[12, 34, 56]`, and base64.
String redact(String text, List<List<int>> secrets) {
  var out = text;
  for (final s in secrets) {
    if (s.length < 4) continue;
    final hexBytes = s.map((b) => b.toRadixString(16).padLeft(2, '0'));
    out = out.replaceAll(
      RegExp(hexBytes.join(r'[:\s-]?'), caseSensitive: false),
      '[redacted]',
    );
    out = out.replaceAll(RegExp('\\b${s.join(r',\s*')}\\b'), '[redacted]');
    final b64 = base64Encode(s);
    out = out.replaceAll(b64, '[redacted]');
    final b64NoPad = b64.replaceAll('=', '');
    if (b64NoPad.length >= 8) out = out.replaceAll(b64NoPad, '[redacted]');
  }
  return out;
}

/// Last 3 bytes of a 6-byte sensor id, e.g. `…a1b2c3`. Enough to tell
/// sensors apart in a report without the full radio address.
String shortSensorId(String idHex) {
  final clean = idHex.replaceAll(':', '').toLowerCase();
  if (clean.length <= 6) return clean;
  return '…${clean.substring(clean.length - 6)}';
}

void _section(StringBuffer t, String name, Map<String, String> values) {
  if (values.isEmpty) return;
  t
    ..writeln()
    ..writeln('== $name ==');
  values.forEach((k, v) => t.writeln('$k: $v'));
}

String _titleFrom(String desc) {
  final first = desc.split('\n').first.trim();
  if (first.isEmpty) return 'Problem report';
  return first.length <= 80 ? first : '${first.substring(0, 77)}…';
}

String _or(String v) => v.isEmpty ? 'unknown' : v;

String _randomTag(Random r) =>
    List.generate(8, (_) => r.nextInt(16).toRadixString(16)).join();

String _stamp(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  final off = t.timeZoneOffset;
  final sign = off.isNegative ? '-' : '+';
  final oh = two(off.inHours.abs());
  final om = two(off.inMinutes.abs() % 60);
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)} UTC$sign$oh:$om';
}
