/// Spot a fill that took much longer than usual. Pure, so it is unit tested.
library;

import '../ble/models.dart';
import '../ble/tanklink_uuids.dart';

class SlowFill {
  const SlowFill({required this.fill, required this.usualSec});

  final FillRecord fill;

  /// Median of that tank's earlier fills that ended with the tank full.
  final int usualSec;
}

/// Earlier full fills of the same tank needed before comparing.
const slowFillMinEarlier = 3;

/// How much longer than usual counts as slow.
const slowFillFactor = 1.3;

/// The newest fill that ended because its tank was full, if it took at least
/// [slowFillFactor] times that tank's usual time. [fills] is newest first.
SlowFill? findSlowFill(List<FillRecord> fills) {
  final full = [
    for (final f in fills)
      if (f.stoppedBy == TankLinkUuids.causeTankFull && f.ranSec > 0) f,
  ];
  if (full.isEmpty) return null;
  final latest = full.first;
  final earlier = [
    for (final f in full.skip(1))
      if (f.slot == latest.slot) f.ranSec,
  ]..sort();
  if (earlier.length < slowFillMinEarlier) return null;
  final mid = earlier.length ~/ 2;
  final usual = earlier.length.isOdd
      ? earlier[mid]
      : ((earlier[mid - 1] + earlier[mid]) / 2).round();
  if (latest.ranSec < usual * slowFillFactor) return null;
  return SlowFill(fill: latest, usualSec: usual);
}
