import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

class _SlideToStartState extends State<SlideToStart> {
  double _progress = 0;
  bool _dragging = false;
  bool _busy = false;

  static const double _height = kHomeControlHeight;
  static const double _border = 1.5;
  static const double _pad = 5; // same inset on left/right/top/bottom
  static const double _radius = 20;
  static const double _completeAt = 0.92;

  Future<void> _finish() async {
    if (_busy || !widget.enabled) return;
    setState(() {
      _busy = true;
      _progress = 1;
    });
    HapticFeedback.heavyImpact();
    try {
      await widget.onCompleted();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = 0;
          _dragging = false;
        });
      }
    }
  }

  void _snapBack() {
    setState(() {
      _progress = 0;
      _dragging = false;
    });
    HapticFeedback.selectionClick();
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

    return LayoutBuilder(
      builder: (context, constraints) {
        // Stack is laid out inside the border; keep equal _pad on all sides there.
        final innerW = constraints.maxWidth - _border * 2;
        final travel = (innerW - thumbSize - _pad * 2).clamp(1.0, innerW);
        final dx = _progress * travel;
        final hintHidden = _dragging || _progress > 0.12;

        return Opacity(
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
                      widthFactor:
                          ((_pad + dx + thumbSize) / innerW).clamp(0.0, 1.0),
                      heightFactor: 1,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              scheme.primary.withValues(alpha: 0.35 * _progress),
                              scheme.primary.withValues(alpha: 0.12 * _progress),
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
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.label,
                          textAlign: TextAlign.center,
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.2,
                                    color: scheme.onSurface,
                                  ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.keyboard_double_arrow_right_rounded,
                          size: 22,
                          color: scheme.primary,
                        ),
                      ],
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
                            HapticFeedback.selectionClick();
                          }
                        : null,
                    onHorizontalDragUpdate: enabled
                        ? (d) {
                            final next =
                                (_progress + d.delta.dx / travel).clamp(0.0, 1.0);
                            setState(() => _progress = next);
                            if (next > 0.48 && next < 0.55) {
                              HapticFeedback.selectionClick();
                            }
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
                                  color:
                                      scheme.primary.withValues(alpha: 0.35),
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
        );
      },
    );
  }
}
