import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tanklink/ble/connect_gate.dart';

void main() {
  late List<String> log;
  late ConnectGate gate;
  late String? selected;

  setUp(() {
    log = [];
    selected = 'A';
    gate = ConnectGate(
      abort: () async {
        log.add('abort');
      },
    );
  });

  /// A connect that waits on [until] (or its cancel) and logs how it ended.
  Future<void> Function(ConnectAttempt) body(Completer<void> until) {
    return (a) async {
      log.add('start ${a.pumpId}');
      await Future.any([until.future, a.whenCancelled]);
      log.add(a.cancelled ? 'cancelled ${a.pumpId}' : 'done ${a.pumpId}');
    };
  }

  test('a second connect to the same pump joins the running one', () async {
    final until = Completer<void>();
    final first = gate.run(() => selected, body(until));
    final second = gate.run(() => selected, body(Completer<void>()));
    until.complete();
    await Future.wait([first, second]);
    expect(log, ['start A', 'done A']);
    expect(gate.current, isNull);
  });

  test(
    'switching pumps cancels the old connect before the new starts',
    () async {
      final a = gate.run(() => selected, body(Completer<void>()));
      selected = 'B';
      final bDone = Completer<void>();
      final b = gate.run(() => selected, body(bDone));
      await a;
      await pumpEventQueue();
      expect(log, ['start A', 'abort', 'cancelled A', 'start B']);
      expect(gate.current?.pumpId, 'B');
      bDone.complete();
      await b;
      expect(log.last, 'done B');
    },
  );

  test(
    'Connect pressed while a switch is waiting starts only one connect',
    () async {
      unawaited(gate.run(() => selected, body(Completer<void>())));
      selected = 'B';
      final bDone = Completer<void>();
      // selectPump's connect and a Connect tap, both while A is still running.
      final b1 = gate.run(() => selected, body(bDone));
      final b2 = gate.run(() => selected, body(bDone));
      await pumpEventQueue();
      bDone.complete();
      await Future.wait([b1, b2]);
      expect(log.where((l) => l == 'start B'), hasLength(1));
      expect(log.where((l) => l == 'abort'), hasLength(1));
    },
  );

  test('Connect works again after a cancel', () async {
    final a = gate.run(() => selected, body(Completer<void>()));
    await gate.cancel();
    await a;
    expect(gate.current, isNull);
    final again = Completer<void>()..complete();
    await gate.run(() => selected, body(again));
    expect(log, ['start A', 'abort', 'cancelled A', 'start A', 'done A']);
  });

  test(
    'a failed connect frees the gate and its error reaches its caller',
    () async {
      final failing = gate.run(() => selected, (_) async {
        throw StateError('no pump');
      });
      await expectLater(failing, throwsStateError);
      expect(gate.current, isNull);
    },
  );
}
