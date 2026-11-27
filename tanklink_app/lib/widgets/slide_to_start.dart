import 'package:material_ui/material_ui.dart';

import '../util/haptics.dart';

/// Matches [_PumpHeader] height on the home screen (14+48+14).
const double kHomeControlHeight = 76;

/// Safety slider — drag the thumb all the way to confirm starting the pump.
class SlideToStart extends StatefulWidget {
  const SlideToStart({
    super.key,
    required this.enabled,
    required this.onCompleted,
    this.label = 'Slide to start',
  });

  final bool enabled;
  final Future<void> Function() onCompleted;
  final String label;

  @override
  State<SlideToStart> createState() => _SlideToStartState();
}

class _SlideToStartState extends State<SlideToStart>
    with SingleTickerProviderStateMixin {
  double _progress = 0;
  bool _dragging = false;
  bool _busy = false;
  late final AnimationController _shimmer;

  static const double _height = kHomeControlHeight;
  static const double _border = 1.5;
  static const double _pad = 5; // same inset on left/right/top/bottom
  static const double _radius = 20;
  static const double _completeAt = 0.92;

  @override
  void initState() {
    super.initState();
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    _syncShimmer();
  }

  @override
  void didUpdateWidget(covariant SlideToStart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      _syncShimmer();
    }
  }

  void _syncShimmer() {
    final play = widget.enabled && !_busy && !_dragging && _progress <= 0.12;
    if (play) {
      if (!_shimmer.isAnimating) {
        _shimmer.repeat();
      }
    } else if (_shimmer.isAnimating) {
      _shimmer.stop();
    }
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    if (_busy || !widget.enabled) return;
    setState(() {
      _busy = true;
      _progress = 1;
    });
    _syncShimmer();
    Haptics.play(Haptic.confirm);
    try {
      await widget.onCompleted();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = 0;
          _dragging = false;
        });
        _syncShimmer();
      }
    }
  }

  /// Detents the thumb passes on the way (each one firmer), and a last one
  /// where letting go will start the pump.
  static const _marks = [0.2, 0.4, 0.6, 0.8, _completeAt];
  int _detent = 0;

  void _detents(double p) {
    var n = 0;
    while (n < _marks.length && p >= _marks[n]) {
      n++;
    }
    if (n > _detent) {
      Haptics.play(
        n == _marks.length ? Haptic.tap : Haptic.detent,
        scale: n / _marks.length,
      );
    }
    _detent = n;
  }

  void _snapBack() {
    setState(() {
      _progress = 0;
      _dragging = false;
    });
    _syncShimmer();
    Haptics.play(Haptic.release);
  }

  Widget _hintLabel(ColorScheme scheme, TextStyle? style, bool shimmer) {
    final text = Text(
      widget.label,
      textAlign: TextAlign.right,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: 0.2,
        color: scheme.onSurface,
      ),
    );
    if (!shimmer) return text;

    return AnimatedBuilder(
      animation: _shimmer,
      builder: (context, child) {
        final t = _shimmer.value;
        // Sweep a bright band across muted text (slide-to-unlock style).
        final shift = (t * 2.4) - 0.7;
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) {
            return LinearGradient(
              begin: Alignment(-1.2 + shift, 0),
              end: Alignment(0.2 + shift, 0),
              colors: [
                scheme.onSurface.withValues(alpha: 0.28),
                scheme.onSurface.withValues(alpha: 0.28),
                scheme.onSurface.withValues(alpha: 0.95),
                scheme.brightness == Brightness.dark
                    ? Colors.white
                    : scheme.primary,
                scheme.onSurface.withValues(alpha: 0.95),
                scheme.onSurface.withValues(alpha: 0.28),
                scheme.onSurface.withValues(alpha: 0.28),
              ],
              stops: const [0.0, 0.32, 0.44, 0.50, 0.56, 0.68, 1.0],
            ).createShader(bounds);
          },
          child: child,
        );
      },
      child: text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.enabled && !_busy;
    final trackRadius = BorderRadius.circular(_radius);

    // Stack lives inside the border — size the thumb from the inner area.
    final innerH = _height - _border * 2;
    final thumbSize = innerH - _pad * 2;
    final thumbRadius = BorderRadius.circular(_radius - 4);
    final showChevron = enabled;
    final useShimmer = enabled && !_dragging && _progress <= 0.12;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Stack is laid out inside the border; keep equal _pad on all sides there.
        final innerW = constraints.maxWidth - _border * 2;
        final travel = (innerW - thumbSize - _pad * 2).clamp(1.0, innerW);
        final dx = _progress * travel;
        final hintHidden = _dragging || _progress > 0.12;

        // TalkBack can't drag the thumb: a double tap is its deliberate
        // action instead.
        return Semantics(
          button: true,
          enabled: enabled,
          label: widget.label,
          hint: enabled ? 'Double tap to start the pump' : null,
          onTap: enabled ? _finish : null,
          excludeSemantics: true,
          child: Opacity(
            opacity: widget.enabled ? 1 : 0.5,
            child: Container(
              width: double.infinity,
              height: _height,
              decoration: BoxDecoration(
                borderRadius: trackRadius,
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.85),
                border: Border.all(
                  color: enabled
                      ? scheme.primary.withValues(alpha: 0.65)
                      : scheme.outlineVariant,
                  width: _border,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: ((_pad + dx + thumbSize) / innerW).clamp(
                          0.0,
                          1.0,
                        ),
                        heightFactor: 1,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                scheme.primary.withValues(
                                  alpha: 0.35 * _progress,
                                ),
                                scheme.primary.withValues(
                                  alpha: 0.12 * _progress,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  IgnorePointer(
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 140),
                      opacity: hintHidden ? 0.0 : 1.0,
                      child: Padding(
                        // Clear the thumb on the left; align label toward the end.
                        padding: EdgeInsets.only(
                          left: thumbSize + _pad * 2,
                          right: 16,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Flexible(
                              child: _hintLabel(
                                scheme,
                                Theme.of(context).textTheme.titleMedium,
                                useShimmer,
                              ),
                            ),
                            if (showChevron) ...[
                              const SizedBox(width: 6),
                              Icon(
                                Icons.keyboard_double_arrow_right_rounded,
                                size: 22,
                                color: scheme.primary.withValues(alpha: 0.85),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Equal top/bottom inset → vertically centered in the track.
                  Positioned(
                    left: _pad + dx,
                    top: _pad,
                    bottom: _pad,
                    width: thumbSize,
                    child: GestureDetector(
                      onHorizontalDragStart: enabled
                          ? (_) {
                              setState(() => _dragging = true);
                              _syncShimmer();
                              _detent = 0;
                              Haptics.play(Haptic.grab);
                            }
                          : null,
                      onHorizontalDragUpdate: enabled
                          ? (d) {
                              final next = (_progress + d.delta.dx / travel)
                                  .clamp(0.0, 1.0);
                              setState(() => _progress = next);
                              _detents(next);
                            }
                          : null,
                      onHorizontalDragEnd: enabled
                          ? (_) {
                              if (_progress >= _completeAt) {
                                _finish();
                              } else {
                                _snapBack();
                              }
                            }
                          : null,
                      child: AnimatedContainer(
                        duration: _dragging
                            ? Duration.zero
                            : const Duration(milliseconds: 180),
                        curve: Curves.easeOutCubic,
                        decoration: BoxDecoration(
                          color: enabled ? scheme.primary : scheme.outline,
                          borderRadius: thumbRadius,
                          boxShadow: enabled
                              ? [
                                  BoxShadow(
                                    color: scheme.primary.withValues(
                                      alpha: 0.35,
                                    ),
                                    blurRadius: 8,
                                    offset: Offset.zero,
                                  ),
                                ]
                              : null,
                        ),
                        child: Icon(
                          _busy
                              ? Icons.hourglass_top_rounded
                              : Icons.play_arrow_rounded,
                          color: enabled ? scheme.onPrimary : scheme.onSurface,
                          size: 28,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
