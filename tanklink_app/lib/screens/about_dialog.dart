import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../update/app_install.dart';

/// "Made with ❤️" popup with the app version. Opened by
/// tapping the TankLink title on the home screen.
Future<void> showAboutTankLink(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 420),
    pageBuilder: (_, _, _) => const _AboutCard(),
    transitionBuilder: (context, anim, _, child) {
      final curve = CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
      return FadeTransition(
        opacity: anim,
        child: ScaleTransition(
          scale: Tween(begin: 0.85, end: 1.0).animate(curve),
          child: child,
        ),
      );
    },
  );
}

class _AboutCard extends StatefulWidget {
  const _AboutCard();

  @override
  State<_AboutCard> createState() => _AboutCardState();
}

class _AboutCardState extends State<_AboutCard> with TickerProviderStateMixin {
  /// Staggered entrance of the lines.
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..forward();

  /// Heartbeat and floating hearts.
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  );

  /// Name shimmer: one sweep, then a long rest (see [_Shimmer]).
  late final AnimationController _shine = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );

  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((p) {
      if (!mounted) return;
      setState(() => _appVersion = '${p.version} (${p.buildNumber})');
    });
  }

  static const _gitHub = 'https://github.com/madhukartemba';

  Future<void> _openGitHub() async {
    if (await AppInstall.openUrl(_gitHub) || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Couldn’t open github.com/madhukartemba')),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Respect the phone's "remove animations" setting.
    if (MediaQuery.of(context).disableAnimations) {
      _loop.stop();
      _shine.stop();
      _intro.value = 1;
    } else if (!_loop.isAnimating) {
      _loop.repeat();
      _shine.repeat();
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    _loop.dispose();
    _shine.dispose();
    super.dispose();
  }

  /// Fades and lifts a line in during [start]..[end] of the entrance.
  Widget _stagger(double start, double end, Widget child) {
    final a = CurvedAnimation(
      parent: _intro,
      curve: Interval(start, end, curve: Curves.easeOutCubic),
    );
    return AnimatedBuilder(
      animation: a,
      builder: (_, c) => Opacity(
        opacity: a.value,
        child: Transform.translate(
          offset: Offset(0, 14 * (1 - a.value)),
          child: c,
        ),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final rows = <(String, String)>[
      ('Version', _appVersion.isEmpty ? '…' : _appVersion),
    ];

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Material(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(28),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _stagger(
                    0.0,
                    0.4,
                    Text(
                      'TankLink',
                      style: text.titleMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  _stagger(
                    0.15,
                    0.55,
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Made with',
                          style: text.titleLarge?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(width: 10),
                        _BeatingHeart(loop: _loop),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  _stagger(
                    0.35,
                    0.8,
                    // Tap the name: the author's GitHub.
                    Semantics(
                      link: true,
                      child: InkWell(
                        onTap: _openGitHub,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          child: _Shimmer(
                            loop: _shine,
                            colors: [
                              scheme.primary,
                              const Color(0xFFFF5C8A),
                              scheme.primary,
                            ],
                            child: Text(
                              'Madhukar Temba',
                              textAlign: TextAlign.center,
                              style: text.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.3,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  _stagger(
                    0.55,
                    1.0,
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        children: [
                          for (final r in rows)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  Text(
                                    r.$1,
                                    style: TextStyle(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    r.$2,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontFeatures: [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// ❤️ that beats lub-dub and lets small hearts float up from it.
class _BeatingHeart extends StatelessWidget {
  const _BeatingHeart({required this.loop});

  final Animation<double> loop;

  /// One soft beat, then rest.
  static final _beat = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 1.0,
        end: 1.1,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 10,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: 1.1,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.easeIn)),
      weight: 14,
    ),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 76),
  ]);

  static const _floaters = 3;

  @override
  Widget build(BuildContext context) {
    // Fixed size; the floating hearts draw outside it.
    return SizedBox(
      width: 34,
      height: 34,
      child: AnimatedBuilder(
        animation: loop,
        builder: (_, _) {
          final t = loop.value;
          return Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              for (var i = 0; i < _floaters; i++) _floater(i, t),
              Transform.scale(
                scale: _beat.transform(t),
                child: const Text('❤️', style: TextStyle(fontSize: 28)),
              ),
            ],
          );
        },
      ),
    );
  }

  /// One small heart rising, swaying and fading, each on its own phase.
  Widget _floater(int i, double t) {
    final p = (t + i / _floaters) % 1.0;
    final seed = math.Random(i * 7919);
    final drift = (seed.nextDouble() - 0.5) * 24;
    final size = 7.0 + seed.nextDouble() * 3;
    final sway = math.sin((p * 2 + i) * math.pi) * 3;
    final opacity = math.sin(p * math.pi).clamp(0.0, 1.0) * 0.45;
    final colors = [
      const Color(0xFFFF4D6D),
      const Color(0xFFFF8FA3),
      const Color(0xFFE0457B),
    ];
    return Transform.translate(
      offset: Offset(drift * p + sway, -10 - 30 * p),
      child: Opacity(
        opacity: opacity,
        child: Transform.scale(
          scale: 0.6 + 0.4 * p,
          child: Icon(
            Icons.favorite_rounded,
            size: size,
            color: colors[i % colors.length],
          ),
        ),
      ),
    );
  }
}

/// A colour band that sweeps across [child] over and over.
class _Shimmer extends StatelessWidget {
  const _Shimmer({
    required this.loop,
    required this.colors,
    required this.child,
  });

  final Animation<double> loop;
  final List<Color> colors;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: loop,
      child: child,
      builder: (_, c) {
        // Sweep during the first quarter of the cycle, then rest in the
        // first colour (x past the right edge).
        final t = (loop.value / 0.25).clamp(0.0, 1.0);
        final x = Curves.easeInOut.transform(t) * 3 - 1; // -1 → 2
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (rect) => LinearGradient(
            colors: colors,
            stops: [
              (x - 0.35).clamp(0.0, 1.0),
              x.clamp(0.0, 1.0),
              (x + 0.35).clamp(0.0, 1.0),
            ],
          ).createShader(rect),
          child: c,
        );
      },
    );
  }
}
