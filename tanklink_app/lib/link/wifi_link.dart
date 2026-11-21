import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../ble/protocol.dart';
import '../ble/tanklink_uuids.dart';
import 'pump_link.dart';

/// Port of the pump's Wi-Fi API (docs/PROTOCOL.md, "Wi-Fi transport").
const wifiApiPort = 7580;

/// Frame types.
class WifiFrame {
  static const hello = 0x01;
  static const auth = 0x02;
  static const read = 0x03;
  static const write = 0x04;
  static const result = 0x05;
  static const notify = 0x06;
  static const error = 0x07;

  static const headerLen = 6; // type, chr, counter(4)
  static const tagLen = 8;

  /// The biggest frame body the pump takes (an OTA chunk write).
  static const maxBody = headerLen + 4100 + tagLen;
}

/// `session_key = HMAC-SHA256(token, nonce || "tcp")`.
Uint8List wifiSessionKey(List<int> token, List<int> nonce) =>
    Uint8List.fromList(
      Hmac(sha256, token).convert([...nonce, ...'tcp'.codeUnits]).bytes,
    );

/// length(u16) type chr counter(u32) payload [tag], little-endian. The length
/// counts everything after itself, tag included. With a [key] the frame ends
/// in the first 8 bytes of HMAC-SHA256(key, every byte before the tag).
Uint8List buildWifiFrame(
  int type,
  int chr,
  int counter,
  List<int> payload, {
  List<int>? key,
}) {
  final body =
      WifiFrame.headerLen +
      payload.length +
      (key == null ? 0 : WifiFrame.tagLen);
  final b = BytesBuilder()
    ..add([body & 0xff, body >> 8, type, chr])
    ..add([
      counter & 0xff,
      (counter >> 8) & 0xff,
      (counter >> 16) & 0xff,
      (counter >> 24) & 0xff,
    ])
    ..add(payload);
  final frame = b.toBytes();
  if (key == null) return frame;
  final tag = Hmac(
    sha256,
    key,
  ).convert(frame).bytes.sublist(0, WifiFrame.tagLen);
  return Uint8List.fromList([...frame, ...tag]);
}

class WifiFrameError implements Exception {
  WifiFrameError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One frame the pump sent.
class WifiIncoming {
  WifiIncoming(this.type, this.chr, this.counter, this.payload);
  final int type;
  final int chr;
  final int counter;
  final Uint8List payload;
}

/// Cuts a TCP byte stream into frames, checking the tag (once [key] is set)
/// and that the counter goes up. Throws [WifiFrameError] on a bad frame.
class WifiFrameReader {
  Uint8List? key;
  int _lastCounter = 0;
  Uint8List _pending = Uint8List(0);

  List<WifiIncoming> add(List<int> data) {
    _pending = Uint8List.fromList([..._pending, ...data]);
    final out = <WifiIncoming>[];
    while (_pending.length >= 2) {
      final n = _pending[0] | (_pending[1] << 8);
      if (n < WifiFrame.headerLen || n > WifiFrame.maxBody) {
        throw WifiFrameError('Bad frame length');
      }
      if (_pending.length < 2 + n) break;
      final frame = Uint8List.sublistView(_pending, 0, 2 + n);
      var end = 2 + n;
      final k = key;
      if (k != null) {
        if (n < WifiFrame.headerLen + WifiFrame.tagLen) {
          throw WifiFrameError('Frame without a tag');
        }
        end -= WifiFrame.tagLen;
        final want = Hmac(
          sha256,
          k,
        ).convert(frame.sublist(0, end)).bytes.sublist(0, WifiFrame.tagLen);
        var diff = 0;
        for (var i = 0; i < WifiFrame.tagLen; i++) {
          diff |= want[i] ^ frame[end + i];
        }
        if (diff != 0) throw WifiFrameError('Bad tag from the pump');
      }
      final counter =
          frame[4] | (frame[5] << 8) | (frame[6] << 16) | (frame[7] << 24);
      if (counter <= _lastCounter) {
        throw WifiFrameError('Frame counter went back');
      }
      _lastCounter = counter;
      out.add(WifiIncoming(frame[2], frame[3], counter, frame.sublist(8, end)));
      _pending = Uint8List.fromList(_pending.sublist(2 + n));
    }
    return out;
  }
}

/// A refused request. The text carries the same words Android's BLE errors
/// do, so the session tells "signed out" from "link dropped" either way.
class WifiRequestError implements Exception {
  WifiRequestError(this.status);
  final int status;

  @override
  String toString() => switch (status) {
    1 => 'WRITE_NOT_PERMITTED (not signed in)',
    2 => 'INVALID_ATTRIBUTE_LENGTH',
    4 => 'INSUFFICIENT_RESOURCES',
    _ => 'The pump refused (status $status)',
  };
}

/// The pump's characteristic id: the UUID's third byte (`7f1a00XX-…`).
int chrIdOf(Guid uuid) => int.parse(uuid.str128.substring(6, 8), radix: 16);

/// A TCP connection to the pump's local API.
class WifiLink {
  WifiLink._(
    this._socket,
    this._sub,
    this._reader,
    this.host,
    this._nonce,
    this.info,
  ) {
    // The socket is a single-subscription stream: keep its subscription and
    // hand it new handlers.
    _sub
      ..onData(_onData)
      ..onError((Object e) => _close('$e'))
      ..onDone(() => _close('closed'));
  }

  final Socket _socket;
  final String host;
  final Uint8List _nonce;

  /// The nonce this connection signed in with (needed to encrypt a Wi-Fi
  /// password for the pump).
  Uint8List get nonce => _nonce;

  /// The Info payload the pump sent with HELLO (readable before sign-in).
  final Uint8List info;

  final StreamSubscription<List<int>> _sub;
  final WifiFrameReader _reader;
  final _waiting = <Completer<WifiIncoming>>[];
  final _notify = StreamController<WifiIncoming>.broadcast();
  final _closed = Completer<String>();
  int _txCounter = 0;
  Uint8List? _key;
  Timer? _keepAlive;
  Future<void> _queue = Future.value();

  /// Completes when the link is gone, with the reason.
  Future<String> get closed => _closed.future;
  bool get isOpen => !_closed.isCompleted;

  /// Opens a socket and reads the pump's HELLO. Throws on timeout.
  static Future<WifiLink> connect(
    String host, {
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    final socket = await Socket.connect(host, wifiApiPort, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    final reader = WifiFrameReader();
    final hello = Completer<WifiIncoming>();
    final sub = socket.listen(
      (d) {
        try {
          for (final f in reader.add(d)) {
            if (!hello.isCompleted && f.type == WifiFrame.hello) {
              hello.complete(f);
            }
          }
        } catch (e) {
          if (!hello.isCompleted) hello.completeError(e);
        }
      },
      onError: (Object e) {
        if (!hello.isCompleted) hello.completeError(e);
      },
      onDone: () {
        if (!hello.isCompleted) hello.completeError('closed');
      },
    );
    try {
      final h = await hello.future.timeout(timeout * 2);
      if (h.payload.length < TankLinkUuids.nonceLen) {
        throw WifiFrameError('Short HELLO');
      }
      return WifiLink._(
        socket,
        sub,
        reader,
        host,
        Uint8List.sublistView(h.payload, 0, TankLinkUuids.nonceLen),
        Uint8List.sublistView(h.payload, TankLinkUuids.nonceLen),
      );
    } catch (_) {
      await sub.cancel();
      socket.destroy();
      rethrow;
    }
  }

  void _onData(List<int> data) {
    try {
      for (final f in _reader.add(data)) {
        if (f.type == WifiFrame.notify) {
          _notify.add(f);
        } else if (f.type == WifiFrame.result && _waiting.isNotEmpty) {
          _waiting.removeAt(0).complete(f);
        }
      }
    } catch (e) {
      _close('$e');
    }
  }

  void _close(String why) {
    if (_closed.isCompleted) return;
    _closed.complete(why);
    _keepAlive?.cancel();
    for (final w in _waiting) {
      if (!w.isCompleted) w.completeError(StateError('Wi-Fi link closed'));
    }
    _waiting.clear();
    unawaited(_sub.cancel());
    _socket.destroy();
    unawaited(_notify.close());
  }

  void close() => _close('closed by the app');

  /// One request at a time, answered in order.
  Future<WifiIncoming> _request(
    int type,
    int chr,
    List<int> payload, {
    required bool tagged,
  }) {
    final c = Completer<WifiIncoming>();
    _queue = _queue.then((_) async {
      if (!isOpen) {
        c.completeError(StateError('Wi-Fi link closed'));
        return;
      }
      _waiting.add(c);
      _txCounter++;
      _socket.add(
        buildWifiFrame(
          type,
          chr,
          _txCounter,
          payload,
          key: tagged ? _key : null,
        ),
      );
      try {
        await c.future.timeout(const Duration(seconds: 8));
      } catch (_) {
        // Fall through: the caller sees the error from c.future.
      }
    });
    return c.future.timeout(
      const Duration(seconds: 12),
      onTimeout: () {
        _close('request timed out');
        throw StateError('The pump did not answer');
      },
    );
  }

  /// Signs in with this phone's [token]. Throws [WifiRequestError] if refused.
  Future<void> signIn(List<int> token) async {
    final key = wifiSessionKey(token, _nonce);
    // The reply is tagged only when it succeeds, so set the key first: a
    // refusal (untagged) then fails the tag check and closes the link.
    _key = key;
    _reader.key = key;
    try {
      final r = await _request(
        WifiFrame.auth,
        0,
        authResponse(token, _nonce),
        tagged: false,
      );
      if (r.payload.isEmpty || r.payload[0] != 0) {
        throw WifiRequestError(r.payload.isEmpty ? 3 : r.payload[0]);
      }
    } on WifiFrameError {
      _close('signed out');
      throw WifiRequestError(1);
    } on StateError {
      if (!isOpen) throw WifiRequestError(1);
      rethrow;
    }
    _keepAlive = Timer.periodic(const Duration(seconds: 30), (_) {
      if (isOpen) {
        unawaited(
          read(0x05).catchError((Object _) => <int>[]),
        ); // State: keeps the link from idling out
      }
    });
  }

  Future<List<int>> read(int chr) async {
    final r = await _request(
      WifiFrame.read,
      chr,
      const [],
      tagged: _key != null,
    );
    if (r.payload.isEmpty) throw WifiRequestError(3);
    if (r.payload[0] != 0) throw WifiRequestError(r.payload[0]);
    return r.payload.sublist(1);
  }

  Future<void> write(int chr, List<int> value) async {
    final r = await _request(WifiFrame.write, chr, value, tagged: _key != null);
    if (r.payload.isEmpty) throw WifiRequestError(3);
    if (r.payload[0] != 0) throw WifiRequestError(r.payload[0]);
  }

  Stream<List<int>> notifications(int chr) =>
      _notify.stream.where((f) => f.chr == chr).map((f) => f.payload);

  /// A characteristic by its BLE UUID.
  PumpChr chr(Guid uuid) => WifiChr(this, chrIdOf(uuid));
}

class WifiChr implements PumpChr {
  const WifiChr(this.link, this.id);

  final WifiLink link;
  final int id;

  @override
  Future<List<int>> read() {
    // Before sign-in only Info can be read, and HELLO carried it already.
    return link.read(id);
  }

  @override
  Future<void> write(List<int> value, {bool withoutResponse = false}) =>
      link.write(id, value);

  @override
  Future<void> setNotifyValue(bool enable) async {}

  @override
  Stream<List<int>> get onValueReceived => link.notifications(id);
}
