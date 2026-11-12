import 'package:flutter/material.dart';

/// Left↔right soft comet — matches pump NeoPixel tank-search / BLE pair motion.
class PingPongIndicator extends StatefulWidget {
  const PingPongIndicator({
    super.key,
    this.color = const Color(0xFF00C8AA),
    this.height = 10,
  });

  final Color color;
  final double height;

  @override
  State<PingPongIndicator> createState() => _PingPongIndicatorState();
}

class _PingPongIndicatorState extends State<PingPongIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: AnimatedBuilder(
        animation: _ctl,
        builder: (context, _) {
          return CustomPaint(
            painter: _PingPongPainter(
              t: _ctl.value,
              color: widget.color,
            ),
          );
        },
      ),
    );
  }
}

class _PingPongPainter extends CustomPainter {
  _PingPongPainter({required this.t, required this.color});

  final double t;
  final Color color;

  static double _smooth(double x) {
    x = x.clamp(0.0, 1.0);
    return x * x * x * (x * (x * 6 - 15) + 10);
  }

  @override
  void paint(Canvas canvas, Size size) {
    const dots = 11;
    final tri = t < 0.5 ? t * 2 : 2 - t * 2;
    final pos = _smooth(tri) * (dots - 1);
    final cy = size.height * 0.5;
    final spacing = size.width / (dots - 1);
    final r = size.height * 0.42;

    for (var i = 0; i < dots; i++) {
      final dist = (i - pos).abs();
      var bri = 0.0;
      if (dist < 3) {
        final u = 1 - dist / 3;
        bri = u * u;
      }
      bri = bri < 0.08 ? 0.08 : bri;
      final paint = Paint()
        ..color = color.withValues(alpha: bri)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(i * spacing, cy), r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PingPongPainter oldDelegate) =>
      oldDelegate.t != t || oldDelegate.color != color;
}
