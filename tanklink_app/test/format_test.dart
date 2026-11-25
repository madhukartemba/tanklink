// Labels in lib/util/format.dart that must cover every value the pump sends.

import 'package:flutter_test/flutter_test.dart';
import 'package:tanklink/ble/tanklink_uuids.dart';
import 'package:tanklink/util/format.dart';

void main() {
  test('every auto-fill state has a short label', () {
    for (var s = 0; s <= TankLinkUuids.afStateNotSelected; s++) {
      expect(autoFillShort(s, 5), isNotEmpty, reason: 'state $s');
    }
  });
}
