import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'pump_link.dart';

/// A BLE characteristic as a [PumpChr].
class BleChr implements PumpChr {
  const BleChr(this.chr);

  final BluetoothCharacteristic chr;

  @override
  Future<List<int>> read() => chr.read();

  @override
  Future<void> write(List<int> value, {bool withoutResponse = false}) =>
      chr.write(value, withoutResponse: withoutResponse);

  @override
  Future<void> setNotifyValue(bool enable) async {
    await chr.setNotifyValue(enable);
  }

  @override
  Stream<List<int>> get onValueReceived => chr.onValueReceived;
}
