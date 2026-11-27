import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Feedback patterns, named by what happened rather than how strong it is.
/// Played by `Haptics.kt` (vibrator primitives where the phone has them).
/// Off when the user turns Vibration off in the app's settings, and on
/// Android 13+ when the phone's "Touch feedback" is off.
enum Haptic {
  /// A light mark: a list row, a slider step.
  tick,

  /// A button.
  tap,

  /// A choice: chip, segment, menu item.
  select,
  toggleOn,
  toggleOff,

  /// Slide-to-start detents; strength follows the thumb.
  detent,

  /// Picking up the slide-to-start thumb, and letting go short of the end.
  grab,
  release,

  /// The user confirmed something that acts on the pump.
  confirm,

  /// The pump reports it is running / stopped.
  pumpStart,
  pumpStop,
  success,
  warning,
  error,
  longPress,
  tankFull,
  connected,
}

class Haptics {
  Haptics._();

  static const _channel = MethodChannel('com.tanklink/haptics');

  /// The app's Vibration switch (AppPrefs).
  static bool enabled = true;

  static final _last = <Haptic, int>{};

  /// Plays [h]. Light patterns repeated faster than the motor can render
  /// (a fast slider drag) are skipped.
  static void play(Haptic h, {double scale = 1}) {
    if (!enabled || defaultTargetPlatform != TargetPlatform.android) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final gap = switch (h) {
      Haptic.tick || Haptic.detent || Haptic.select => 35,
      _ => 80,
    };
    if (now - (_last[h] ?? 0) < gap) return;
    _last[h] = now;
    unawaited(
      _channel.invokeMethod<void>('play', {'name': h.name, 'scale': scale}),
    );
  }

  /// A Switch's onChanged that also gives on/off feedback.
  static ValueChanged<bool>? toggle(ValueChanged<bool>? f) => f == null
      ? null
      : (v) {
          play(v ? Haptic.toggleOn : Haptic.toggleOff);
          f(v);
        };

  /// A nullable-bool onChanged (Checkbox, SwitchListTile.adaptive).
  static ValueChanged<bool?>? toggleN(ValueChanged<bool?>? f) => f == null
      ? null
      : (v) {
          play(v == true ? Haptic.toggleOn : Haptic.toggleOff);
          f(v);
        };

  /// A chip, segment or radio choice.
  static ValueChanged<T>? pick<T>(ValueChanged<T>? f) => f == null
      ? null
      : (v) {
          play(Haptic.select);
          f(v);
        };

  /// [pick] for a callback that can't be null (RadioGroup).
  static ValueChanged<T> choose<T>(ValueChanged<T> f) => (v) {
    play(Haptic.select);
    f(v);
  };

  /// A Slider's onChanged: a tick per step (Slider calls it only when the
  /// value changes, so with divisions that is one per division).
  static ValueChanged<double>? slide(ValueChanged<double>? f) => f == null
      ? null
      : (v) {
          play(Haptic.tick);
          f(v);
        };

  /// A button's onPressed with a tap.
  static VoidCallback? tapped(VoidCallback? f, [Haptic h = Haptic.tap]) =>
      f == null
      ? null
      : () {
          play(h);
          f();
        };
}
