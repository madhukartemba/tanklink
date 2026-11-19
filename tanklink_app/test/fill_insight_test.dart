import 'package:flutter_test/flutter_test.dart';
import 'package:tanklink/ble/models.dart';
import 'package:tanklink/ble/tanklink_uuids.dart';
import 'package:tanklink/util/fill_insight.dart';

FillRecord fill(
  int min, {
  int slot = 0,
  int stop = TankLinkUuids.causeTankFull,
}) => FillRecord(
  startedAt: null,
  ranSec: min * 60,
  slot: slot,
  startedBy: TankLinkUuids.causeApp,
  stoppedBy: stop,
);

void main() {
  test('flags a fill much slower than that tank usually takes', () {
    final slow = findSlowFill([fill(26), fill(18), fill(17), fill(19)]);
    expect(slow, isNotNull);
    expect(slow!.usualSec, 18 * 60);
  });

  test('normal fill: nothing', () {
    expect(findSlowFill([fill(20), fill(18), fill(17), fill(19)]), isNull);
  });

  test('needs three earlier full fills of the same tank', () {
    expect(
      findSlowFill([fill(40), fill(18), fill(18, slot: 1), fill(18)]),
      isNull,
    );
  });

  test('ignores fills that did not end full', () {
    final fills = [
      fill(5, stop: TankLinkUuids.causeAutoOff),
      fill(30),
      fill(18),
      fill(18),
      fill(18),
    ];
    expect(findSlowFill(fills)!.fill.ranSec, 30 * 60);
  });
}
