import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'tanklink_uuids.dart';

/// The three OTA characteristics. Pump and tank share the same, frozen,
/// protocol (docs/PROTOCOL.md, "OTA").
class OtaCharacteristics {
  const OtaCharacteristics({
    required this.ctrl,
    required this.data,
    required this.status,
  });

  final BluetoothCharacteristic ctrl;
  final BluetoothCharacteristic data;
  final BluetoothCharacteristic status;
}

/// Sends [image] to a board that is already connected and authenticated,
/// and returns once it has verified the image and is about to reboot.
///
/// On any failure it asks the board to abort, so the running firmware stays
/// in place, then rethrows.
Future<void> uploadFirmware(
  OtaCharacteristics ota,
  Uint8List image, {
  required int mtu,
  void Function(int done, int total)? onProgress,
  void Function()? onVerifying,
  List<int> startOp = const [TankLinkUuids.otaOpStart],
}) async {
  final size = image.length;
  final statusCtrl = StreamController<List<int>>.broadcast();
  await ota.status.setNotifyValue(true);
  final statusSub = ota.status.onValueReceived.listen(statusCtrl.add);

  /// Waits until OtaStatus reports one of [states] with no error.
  Future<void> waitFor(Set<int> states, Duration timeout) async {
    bool ok(List<int> v) => v.length >= 2 && states.contains(v[0]) && v[1] == 0;
    if (ok(await ota.status.read())) return;
    await statusCtrl.stream.where(ok).first.timeout(timeout);
  }

  try {
    // Start: op(1) [node(1) for a tank image] size(u32) sha256(32).
    await ota.ctrl.write([
      ...startOp,
      ..._u32(size),
      ...sha256.convert(image).bytes,
    ], withoutResponse: false);
    await waitFor({
      TankLinkUuids.otaStReady,
      TankLinkUuids.otaStWriting,
    }, const Duration(seconds: 20));

    // Data: offset(u32) + payload. An ATT write carries MTU - 3 bytes.
    final maxChunk = (mtu - 3 - 4).clamp(20, 480);
    for (var offset = 0; offset < size;) {
      final end = (offset + maxChunk).clamp(0, size);
      await ota.data.write([
        ..._u32(offset),
        ...image.sublist(offset, end),
      ], withoutResponse: false);
      offset = end;
      onProgress?.call(offset, size);
    }

    onVerifying?.call();
    await ota.ctrl.write([TankLinkUuids.otaOpFinish], withoutResponse: false);
    await waitFor({
      TankLinkUuids.otaStVerifyOk,
      TankLinkUuids.otaStRebooting,
    }, const Duration(seconds: 30));
  } catch (_) {
    try {
      await ota.ctrl.write([TankLinkUuids.otaOpAbort], withoutResponse: false);
    } catch (_) {}
    rethrow;
  } finally {
    await statusSub.cancel();
    await statusCtrl.close();
  }
}

List<int> _u32(int v) => [
  v & 0xff,
  (v >> 8) & 0xff,
  (v >> 16) & 0xff,
  (v >> 24) & 0xff,
];
