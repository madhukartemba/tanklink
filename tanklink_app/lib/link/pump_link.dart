import 'dart:async';

/// One characteristic of the pump, however the phone reaches it. The session
/// and the OTA upload talk to this, so they work the same over Bluetooth and
/// over Wi-Fi. The bytes are exactly those of docs/PROTOCOL.md.
abstract class PumpChr {
  Future<List<int>> read();

  /// Resolves once the pump has accepted the write; throws if it refuses.
  Future<void> write(List<int> value, {bool withoutResponse = false});

  /// Turns notifications on. Over Wi-Fi the pump always sends them.
  Future<void> setNotifyValue(bool enable);

  Stream<List<int>> get onValueReceived;
}

/// Which way the phone is talking to the pump.
enum LinkKind { bluetooth, wifi }
