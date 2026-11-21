// Framing and tags of the Wi-Fi transport. The vectors come from
// scripts/wifi_api_check.py, which the pump firmware is checked against.

import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tanklink/ble/protocol.dart';
import 'package:tanklink/ble/tanklink_uuids.dart';
import 'package:tanklink/link/wifi_link.dart';

String hex(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final token = List<int>.generate(16, (i) => i);
  final nonce = List<int>.generate(16, (i) => 16 + i);

  test('session key and sign-in answer match the script', () {
    expect(
      hex(wifiSessionKey(token, nonce)),
      '3aba303dc8cedafd256ef89d622bdf94f3a2441a20e63d4c176093cb6beb48d9',
    );
    expect(hex(authResponse(token, nonce)), 'f7ccfa50b805d56535c5862cd478bf79');
  });

  test('a tagged READ of State is the same bytes as the script builds', () {
    final f = buildWifiFrame(
      WifiFrame.read,
      0x05,
      1,
      const [],
      key: wifiSessionKey(token, nonce),
    );
    expect(hex(f), '0e000305010000007479c0667166299a');
  });

  test('the reader cuts frames, checks tags and counters', () {
    final key = wifiSessionKey(token, nonce);
    final r = WifiFrameReader()..key = key;
    final a = buildWifiFrame(WifiFrame.notify, 5, 1, [1], key: key);
    final b = buildWifiFrame(WifiFrame.notify, 5, 2, [0], key: key);
    // Split anywhere: bytes arrive however TCP likes.
    final all = [...a, ...b];
    final got = <WifiIncoming>[];
    for (var i = 0; i < all.length; i += 5) {
      got.addAll(r.add(all.sublist(i, (i + 5).clamp(0, all.length))));
    }
    expect(got.map((f) => f.counter), [1, 2]);
    expect(got.first.payload, [1]);
    expect(got.first.type, WifiFrame.notify);
  });

  test('a bad tag or a counter that does not go up is refused', () {
    final key = wifiSessionKey(token, nonce);
    final good = buildWifiFrame(WifiFrame.notify, 5, 3, [1], key: key);
    final bad = Uint8List.fromList(good)..[good.length - 1] ^= 1;
    expect(
      () => (WifiFrameReader()..key = key).add(bad),
      throwsA(isA<WifiFrameError>()),
    );
    final r = WifiFrameReader()..key = key;
    r.add(good);
    expect(
      () => r.add(buildWifiFrame(WifiFrame.notify, 5, 3, [1], key: key)),
      throwsA(isA<WifiFrameError>()),
    );
    // An untagged frame once signed in has no tag to check.
    expect(
      () => (WifiFrameReader()..key = key).add(
        buildWifiFrame(WifiFrame.notify, 5, 1, const []),
      ),
      throwsA(isA<WifiFrameError>()),
    );
  });

  test('an untagged HELLO parses before sign-in', () {
    final hello = buildWifiFrame(WifiFrame.hello, 0, 1, [...nonce, 1, 2, 3]);
    final f = WifiFrameReader().add(hello).single;
    expect(f.type, WifiFrame.hello);
    expect(f.payload.sublist(0, 16), nonce);
  });

  test('characteristic ids come from the UUIDs', () {
    expect(chrIdOf(TankLinkUuids.state), 0x05);
    expect(chrIdOf(TankLinkUuids.wifi), 0x11);
    expect(chrIdOf(Guid('7f1a0006-ac01-4c8c-9b2e-74616e6b6c6e')), 0x06);
  });

  test('errors read like the BLE ones the session already matches', () {
    expect('${WifiRequestError(1)}', contains('WRITE_NOT_PERMITTED'));
    expect('${WifiRequestError(4)}', contains('INSUFFICIENT_RESOURCES'));
  });
}
