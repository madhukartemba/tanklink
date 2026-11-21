import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../link/pump_link.dart';
import 'tanklink_uuids.dart';

/// The three OTA characteristics. Pump and tank share the same, frozen,
/// protocol (docs/PROTOCOL.md, "OTA").
class OtaCharacteristics {
  const OtaCharacteristics({
    required this.ctrl,
    required this.data,
    required this.status,
  });

  final PumpChr ctrl;
  final PumpChr data;
  final PumpChr status;
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
  int? chunkSize,
  void Function(int done, int total)? onProgress,
  void Function()? onVerifying,
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
    // Start: op(1) size(u32) sha256(32).
    await ota.ctrl.write([
      TankLinkUuids.otaOpStart,
      ..._u32(size),
      ...sha256.convert(image).bytes,
    ], withoutResponse: false);
    await waitFor({
      TankLinkUuids.otaStReady,
      TankLinkUuids.otaStWriting,
    }, const Duration(seconds: 20));

    // Data: offset(u32) + payload. An ATT write carries MTU - 3 bytes.
    // Over Wi-Fi the caller names a bigger chunk; over BLE it follows the MTU.
    final maxChunk = chunkSize ?? (mtu - 3 - 4).clamp(20, 480);
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
    try {
      await ota.ctrl.write([TankLinkUuids.otaOpFinish], withoutResponse: false);
    } catch (e) {
      // The board refuses a bad image with an error the phone only sees as a
      // generic GATT failure; its own reason is in OtaStatus.
      throw StateError(await _boardReason(ota.status, e));
    }
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

/// The board's own reason for a failed OTA (OtaStatus: state, error), or
/// the phone's error when the board can't be read (it restarted or the link
/// dropped).
Future<String> _boardReason(PumpChr status, Object e) async {
  try {
    final v = await status.read().timeout(const Duration(seconds: 3));
    if (v.length >= 2 && v[1] != 0) {
      return 'The board refused the update: ${_otaErrors[v[1]] ?? 'error ${v[1]}'} '
          '(OTA error ${v[1]})';
    }
  } catch (_) {}
  return 'The link dropped while the board was checking the update: $e';
}

/// The board's words for an OtaStatus error byte.
String otaErrorText(int code) => _otaErrors[code] ?? 'error $code';

/// OTA_STATUS error byte (tanklink_uuid.h / tanklink_ble_uuid.h).
const _otaErrors = {
  1: 'not signed in',
  2: 'the pump is running',
  3: 'bad size or offset',
  4: 'the image was rejected or flash failed (image check or signature)',
  5: 'what arrived does not match the image (SHA-256)',
  6: 'wrong update state',
  7: 'another update is running',
};
