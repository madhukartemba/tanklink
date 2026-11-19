import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tanklink/diag/report_builder.dart';

void main() {
  final token = List<int>.generate(16, (i) => 0xA0 + i);
  final now = DateTime(2026, 11, 19, 14, 3);
  const versions = ReportVersions(
    app: '1.3.0+21',
    pump: '0.13.2',
    tank: '0.3.2',
    pumpProto: '3.1',
  );

  group('redact', () {
    test('hex in any case and with separators', () {
      final hex = token.map((b) => b.toRadixString(16).padLeft(2, '0'));
      final lower = hex.join();
      final upperColon = hex.join(':').toUpperCase();
      final out = redact('a $lower b $upperColon c', [token]);
      expect(out, 'a [redacted] b [redacted] c');
    });

    test('decimal byte list as flutter_blue_plus prints it', () {
      final out = redact('value: [${token.join(', ')}] end', [token]);
      expect(out, 'value: [[redacted]] end');
    });

    test('base64 with and without padding', () {
      final b64 = base64Encode(token);
      final out = redact('$b64 / ${b64.replaceAll('=', '')}', [token]);
      expect(out.contains(b64.substring(0, 10)), isFalse);
    });

    test('does not touch a longer number that only ends the same', () {
      final short = [12, 34, 56, 78];
      expect(redact('112, 34, 56, 78', [short]), '112, 34, 56, 78');
    });
  });

  test('shortSensorId keeps the last 3 bytes', () {
    expect(shortSensorId('AA:BB:CC:DD:EE:FF'), '…ddeeff');
    expect(shortSensorId('abc'), 'abc');
  });

  group('buildReport', () {
    test('error report: title, labels, stable fingerprint', () {
      const problem = ReportProblem(
        kind: 'pump-err',
        code: 3,
        title: 'Pump error 3: Tank offline',
      );
      final a = buildReport(
        description: 'Tank stopped reporting',
        problem: problem,
        versions: versions,
        now: now,
      );
      final b = buildReport(
        description: 'Something else',
        problem: problem,
        versions: versions,
        now: now,
      );
      expect(a.title, 'Pump error 3: Tank offline');
      expect(a.fingerprint, b.fingerprint);
      expect(
        a.labels,
        containsAll(['pump-err', 'pump-err-3', 'app-1.3.0', 'pump-0.13.2']),
      );
      expect(a.summary, contains('Tank stopped reporting'));
      expect(a.summary, contains('Error: Pump error 3: Tank offline'));
    });

    test('fingerprint changes with firmware version', () {
      const problem = ReportProblem(kind: 'tank-err', code: 6, title: 'x');
      final a = buildReport(
        description: '',
        problem: problem,
        versions: versions,
        now: now,
      );
      final b = buildReport(
        description: '',
        problem: problem,
        versions: const ReportVersions(app: '1.3.0+21', tank: '0.4.0'),
        now: now,
      );
      expect(a.fingerprint, isNot(b.fingerprint));
    });

    test('manual reports never group and take their title from the text', () {
      final a = buildReport(
        description: 'Schedule did not start\nmore text',
        problem: ReportProblem.manual,
        versions: versions,
        now: now,
        random: Random(1),
      );
      final b = buildReport(
        description: 'Schedule did not start',
        problem: ReportProblem.manual,
        versions: versions,
        now: now,
        random: Random(2),
      );
      expect(a.title, 'Schedule did not start');
      expect(a.fingerprint, startsWith('manual:'));
      expect(a.fingerprint, isNot(b.fingerprint));
    });

    test('no token bytes survive anywhere in the report', () {
      final hex = token.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final r = buildReport(
        description: 'my token is $hex',
        problem: ReportProblem.manual,
        versions: versions,
        now: now,
        pumpState: {'Debug': '[${token.join(', ')}]'},
        appLog: 'I ble: wrote ${base64Encode(token)}',
        secrets: [token],
      );
      final all = '${r.text}\n${r.summary}';
      expect(all.contains(hex), isFalse);
      expect(all.contains(token.join(', ')), isFalse);
      expect(all.contains(base64Encode(token)), isFalse);
      expect(all, contains('[redacted]'));
    });

    test('sections appear only when included', () {
      final r = buildReport(
        description: 'x',
        problem: ReportProblem.manual,
        versions: versions,
        now: now,
        phone: {'Phone': 'Pixel'},
        appLog: 'line one',
      );
      expect(r.text, contains('== Phone =='));
      expect(r.text, contains('== App log =='));
      expect(r.text, isNot(contains('== Pump state ==')));
    });

    test('JSON round trip keeps what the queue needs', () {
      final r = buildReport(
        description: 'x',
        problem: ReportProblem.manual,
        versions: versions,
        now: now,
      );
      final j = jsonDecode(jsonEncode(r.toJson('k'))) as Map<String, dynamic>;
      expect(j['app_key'], 'k');
      final back = BuiltReport.fromJson(j);
      expect(back.fingerprint, r.fingerprint);
      expect(back.text, r.text);
      expect(back.labels, r.labels);
    });
  });

  group('contact email', () {
    BuiltReport build(String email) => buildReport(
      description: 'x',
      problem: ReportProblem.manual,
      versions: versions,
      now: now,
      contactEmail: email,
      random: Random(1),
    );

    test('sent as its own field and shown in the report', () {
      final r = build('  pat@example.com ');
      expect(r.contact, 'pat@example.com');
      expect(r.toJson('k')['contact'], 'pat@example.com');
      expect(r.text, contains('Contact: pat@example.com'));
      expect(BuiltReport.fromJson(r.toJson('k')).contact, 'pat@example.com');
    });

    test('left out when empty', () {
      final r = build('');
      expect(r.toJson('k').containsKey('contact'), isFalse);
      expect(r.text.contains('Contact:'), isFalse);
      expect(BuiltReport.fromJson(r.toJson('k')).contact, '');
    });

    test('isPlausibleEmail', () {
      expect(isPlausibleEmail(''), isTrue);
      expect(isPlausibleEmail('a.b+c@mail.co.in'), isTrue);
      expect(isPlausibleEmail('no-at.example.com'), isFalse);
      expect(isPlausibleEmail('a@nodot'), isFalse);
      expect(isPlausibleEmail('a b@example.com'), isFalse);
    });
  });
}
