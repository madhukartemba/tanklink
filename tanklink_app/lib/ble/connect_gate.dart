import 'dart:async';

/// One connect attempt. The attempt checks [cancelled] after every wait and,
/// once it is set, returns without touching the session: a newer attempt
/// (or a disconnect) owns the session from then on.
class ConnectAttempt {
  ConnectAttempt._(this.pumpId);

  /// The pump this attempt connects to.
  final String? pumpId;

  final _cancel = Completer<void>();
  late final Future<void> _done;

  bool get cancelled => _cancel.isCompleted;

  /// Completes when the attempt is cancelled (stops a scan early).
  Future<void> get whenCancelled => _cancel.future;
}

/// Runs one connect at a time. A connect to the pump already being connected
/// joins that attempt; a connect to another pump (or [cancel]) cancels the
/// running attempt, calls [abort] to break off whatever it is waiting on,
/// and waits for it to end before anything new starts. So two attempts never
/// run at once, and a cancelled one can't undo a newer one.
class ConnectGate {
  ConnectGate({required this.abort});

  /// Closes the link the cancelled attempt is opening, so its waits end now.
  final Future<void> Function() abort;

  ConnectAttempt? _current;

  /// The running attempt that hasn't been cancelled, if any.
  ConnectAttempt? get current {
    final c = _current;
    return c == null || c.cancelled ? null : c;
  }

  /// Connect to the pump [target] names (read again after each wait, since
  /// the selection can change meanwhile) by running [body].
  Future<void> run(
    String? Function() target,
    Future<void> Function(ConnectAttempt attempt) body,
  ) async {
    while (true) {
      final c = _current;
      if (c == null) break;
      if (!c.cancelled && c.pumpId == target()) return c._done;
      await _end(c);
    }
    final a = ConnectAttempt._(target());
    _current = a;
    a._done = body(a);
    try {
      await a._done;
    } finally {
      if (identical(_current, a)) _current = null;
    }
  }

  /// Cancel the running attempt and wait until it has stopped.
  Future<void> cancel() async {
    final c = _current;
    if (c != null) await _end(c);
  }

  Future<void> _end(ConnectAttempt c) async {
    if (!c.cancelled) {
      c._cancel.complete();
      await abort();
    }
    // Its error, if any, goes to the caller that started it.
    await c._done.then((_) {}, onError: (Object _) {});
    if (identical(_current, c)) _current = null;
  }
}
