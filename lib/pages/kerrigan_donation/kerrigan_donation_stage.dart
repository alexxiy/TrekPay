import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'kerrigan_donation.dart';

/// The donation screen's colours: violet for the dark, shielded Delta,
/// cyan for the light, transparent one. The stage is always night: the
/// art is drawn for a dark backdrop.
class KerriganDonationPalette {
  const KerriganDonationPalette._(
    this.top,
    this.bottom,
    this.glow,
    this.accent,
    this.accent2,
  );

  static const shielded = KerriganDonationPalette._(
    Color(0xFF2A1650),
    Color(0xFF120A26),
    Color(0xFFA855F7),
    Color(0xFFC084FC),
    Color(0xFFE879F9),
  );
  static const transparent = KerriganDonationPalette._(
    Color(0xFF1A2358),
    Color(0xFF0D1130),
    Color(0xFF22D3EE),
    Color(0xFF67E8F9),
    Color(0xFFC084FC),
  );

  static KerriganDonationPalette of({required bool shielded}) => shielded
      ? KerriganDonationPalette.shielded
      : KerriganDonationPalette.transparent;

  final Color top;
  final Color bottom;
  final Color glow;
  final Color accent;
  final Color accent2;

  /// For buttons and the tier slider.
  LinearGradient get gradient => LinearGradient(colors: [glow, accent2]);
}

/// Delta on stage: the tier's picture, floating, with a glow and the
/// tier's particles (sparkles, code bits, orbiting particles, lightning,
/// star streaks), the custom amounts' surprises, and confetti for a
/// thank-you. A tap makes Delta hop.
class KerriganDonationStage extends StatefulWidget {
  const KerriganDonationStage({
    super.key,
    required this.art,
    required this.mood,
    required this.shielded,
    this.egg,
    this.celebrating = false,
    this.height = 250,
  });

  /// The picture's asset.
  final String art;

  /// Which tier's animation plays.
  final KerriganDonationTier mood;
  final bool shielded;
  final KerriganDonationEgg? egg;
  final bool celebrating;
  final double height;

  @override
  State<KerriganDonationStage> createState() => _KerriganDonationStageState();
}

class _KerriganDonationStageState extends State<KerriganDonationStage>
    with TickerProviderStateMixin {
  /// Seconds since the stage appeared.
  final _time = ValueNotifier<double>(0);
  late final Ticker _ticker = createTicker(
    (elapsed) => _time.value = elapsed.inMicroseconds / 1e6,
  );
  late final AnimationController _hop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
  );
  double? _pokedAt;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.disableAnimationsOf(context);
    if (still && _ticker.isActive) {
      _ticker.stop();
    } else if (!still && !_ticker.isActive) {
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _hop.dispose();
    _time.dispose();
    super.dispose();
  }

  void _poke() {
    HapticFeedback.lightImpact();
    _pokedAt = _time.value;
    _hop.forward(from: 0);
  }

  /// 0 (Tiny Spark) to 5 (Astro Flight); the custom amount is all out.
  int get _energy => widget.mood.isCustom
      ? 5
      : KerriganDonationTier.fixed.indexOf(widget.mood);

  Widget _picture(double size) {
    final image = Image.asset(
      widget.art,
      key: ValueKey(widget.art),
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
    );
    if (widget.egg != KerriganDonationEgg.fuelNotFound) return image;
    // Error 404: the picture tears into colour channels now and then.
    return ValueListenableBuilder<double>(
      key: ValueKey("glitch ${widget.art}"),
      valueListenable: _time,
      builder: (_, t, _) {
        final g = _glitch(t);
        Widget tinted(Color color, double dx) => Transform.translate(
          offset: Offset(dx, 0),
          child: ColorFiltered(
            colorFilter: ColorFilter.mode(color, BlendMode.srcATop),
            child: image,
          ),
        );
        return Stack(
          children: [
            if (g > 0) ...[
              Opacity(opacity: 0.55, child: tinted(Colors.red, -5 * g)),
              Opacity(opacity: 0.55, child: tinted(Colors.cyan, 5 * g)),
            ],
            Opacity(opacity: g > 0.5 ? 0.6 : 1, child: image),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = KerriganDonationPalette.of(shielded: widget.shielded);
    final egg = widget.egg;
    final h = widget.height;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final overload = egg == KerriganDonationEgg.overload;
        final size =
            math.min(h * 0.86, math.min(w * 0.72, 240.0)) *
            (overload ? 0.78 : 1);
        final center = Offset(overload ? w * 0.3 : w / 2, h - 8 - size / 2);
        final scene = _Scene(
          time: _time,
          palette: palette,
          energy: _energy,
          mood: widget.mood,
          egg: egg,
          celebrating: widget.celebrating,
          center: center,
          size: size,
          pokedAt: _pokedAt,
        );
        return Semantics(
          image: true,
          label: widget.mood.title(shielded: widget.shielded),
          child: GestureDetector(
            onTap: _poke,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                height: h,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [palette.top, palette.bottom],
                  ),
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(painter: _BackPainter(scene)),
                    ),
                    Positioned(
                      left: center.dx - size / 2,
                      top: center.dy - size / 2,
                      width: size,
                      height: size,
                      child: AnimatedBuilder(
                        animation: Listenable.merge([_time, _hop]),
                        builder: (_, child) => Transform.translate(
                          offset: scene.bob,
                          child: Transform.scale(
                            scale: 1 + 0.08 * math.sin(_hop.value * math.pi),
                            alignment: Alignment.bottomCenter,
                            child: child,
                          ),
                        ),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 350),
                          switchInCurve: Curves.easeOutBack,
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                                opacity: animation,
                                child: ScaleTransition(
                                  scale: Tween(
                                    begin: 0.85,
                                    end: 1.0,
                                  ).animate(animation),
                                  child: child,
                                ),
                              ),
                          child: _picture(size),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(painter: _FrontPainter(scene)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// How torn the 404 picture is at [t]: mostly 0, short bursts up to 1.
double _glitch(double t) {
  final slot = (t / 1.3).floor();
  final into = t - slot * 1.3;
  if (_rnd(slot, 7) < 0.35 || into > 0.22) return 0;
  return 0.5 + 0.5 * _rnd((t * 30).floor(), 3);
}

/// A repeatable random number in [0, 1).
double _rnd(int i, int salt) {
  final x = math.sin(i * 12.9898 + salt * 78.233) * 43758.5453;
  return x - x.floorToDouble();
}

/// What both painters draw from.
class _Scene {
  _Scene({
    required this.time,
    required this.palette,
    required this.energy,
    required this.mood,
    required this.egg,
    required this.celebrating,
    required this.center,
    required this.size,
    required this.pokedAt,
  });

  final ValueNotifier<double> time;
  final KerriganDonationPalette palette;

  /// 0 (Tiny Spark) to 5 (Astro Flight and the custom amount).
  final int energy;
  final KerriganDonationTier mood;
  final KerriganDonationEgg? egg;
  final bool celebrating;
  final Offset center;
  final double size;
  final double? pokedAt;

  double get t => time.value;

  /// The floating offset: a gentle sway for the tiny spark, a buzz for the
  /// surge, a slow climb for the flight. The thank-you art just floats.
  Offset get bob {
    final t = this.t;
    switch (celebrating ? null : mood) {
      case KerriganDonationTier.spark:
        return Offset(1.5 * math.sin(t * 0.8), 2 * math.sin(t * 1.6));
      case KerriganDonationTier.surge:
        return Offset(
          1.2 * math.sin(t * 47),
          -5 + 5 * math.sin(t * 3) + math.cos(t * 39),
        );
      case KerriganDonationTier.flight:
        return Offset(2 * math.sin(t * 1.3), -8 + 7 * math.sin(t * 2.2));
      default:
        final amp = 3.0 + energy;
        return Offset(0, -amp + amp * math.sin(t * (1.6 + energy * 0.25)));
    }
  }
}

// Shapes shared by the painters.

void _sparkle(Canvas canvas, Offset c, double r, Color color) {
  final path = Path()
    ..moveTo(c.dx, c.dy - r)
    ..quadraticBezierTo(c.dx, c.dy, c.dx + r, c.dy)
    ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy + r)
    ..quadraticBezierTo(c.dx, c.dy, c.dx - r, c.dy)
    ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy - r)
    ..close();
  canvas.drawPath(path, Paint()..color = color);
}

void _text(
  Canvas canvas,
  String text,
  Offset center,
  double fontSize,
  Color color, {
  FontWeight weight = FontWeight.w800,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontSize: fontSize,
        color: color,
        fontWeight: weight,
        height: 1,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, center - Offset(painter.width / 2, painter.height / 2));
}

void _bolt(Canvas canvas, Offset from, Offset to, int seed, Paint paint) {
  final path = Path()..moveTo(from.dx, from.dy);
  const steps = 6;
  for (var i = 1; i < steps; i++) {
    final p = Offset.lerp(from, to, i / steps)!;
    path.lineTo(p.dx + (_rnd(seed, i) - 0.5) * 18, p.dy);
  }
  path.lineTo(to.dx, to.dy);
  canvas.drawPath(path, paint);
}

/// A lightning bolt [h] high around [c].
void _boltBadge(Canvas canvas, Offset c, double h, Color color) {
  final u = h / 10;
  final path = Path()
    ..moveTo(c.dx + 1 * u, c.dy - 5 * u)
    ..lineTo(c.dx - 3 * u, c.dy + 1 * u)
    ..lineTo(c.dx, c.dy + 1 * u)
    ..lineTo(c.dx - 1 * u, c.dy + 5 * u)
    ..lineTo(c.dx + 3 * u, c.dy - 1 * u)
    ..lineTo(c.dx, c.dy - 1 * u)
    ..close();
  canvas.drawPath(path, Paint()..color = color);
}

/// Behind Delta: corner pixels, the glow, the floor shadow, and the
/// flight's star streaks and the surge's lightning.
class _BackPainter extends CustomPainter {
  _BackPainter(this.s) : super(repaint: s.time);

  final _Scene s;

  @override
  void paint(Canvas canvas, Size size) {
    final t = s.t;
    final p = s.palette;

    // Pixel confetti in two corners, like the artwork's backdrop.
    for (var i = 0; i < 14; i++) {
      final corner = i.isEven;
      final dx = _rnd(i, 1) * 70;
      final dy = _rnd(i, 2) * 60;
      final side = 4.0 + (_rnd(i, 3) * 3).floor() * 3;
      final twinkle = 0.5 + 0.5 * math.sin(t * (0.8 + _rnd(i, 4)) + i);
      canvas.drawRect(
        Rect.fromLTWH(
          corner ? size.width - 12 - dx : 12 + dx,
          corner ? 12 + dy : size.height - 12 - dy,
          side,
          side,
        ),
        Paint()..color = p.glow.withValues(alpha: 0.08 + 0.18 * twinkle),
      );
    }

    if (s.mood == KerriganDonationTier.flight && !s.celebrating) {
      // Stars streaking down: Delta is going up.
      for (var i = 0; i < 16; i++) {
        final x = _rnd(i, 5) * size.width;
        final speed = 60 + _rnd(i, 6) * 120;
        final len = 8 + _rnd(i, 7) * 22;
        final y =
            (_rnd(i, 8) * size.height + t * speed) % (size.height + len) - len;
        canvas.drawLine(
          Offset(x, y),
          Offset(x, y + len),
          Paint()
            ..strokeWidth = 1.5
            ..strokeCap = StrokeCap.round
            ..color = Colors.white.withValues(alpha: 0.15 + 0.35 * _rnd(i, 9)),
        );
      }
    }

    // The glow, brighter for bigger tiers.
    final energy = s.energy / 5;
    var glow = 0.28 + 0.3 * energy;
    if (s.mood == KerriganDonationTier.surge && !s.celebrating) {
      glow *= 0.75 + 0.25 * _rnd((t * 12).floor(), 11);
    }
    final bob = s.bob;
    final c = s.center + Offset(bob.dx, bob.dy * 0.5);
    final r = s.size * (0.5 + 0.12 * energy) * (1 + 0.04 * math.sin(t * 2));
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [
            p.glow.withValues(alpha: glow),
            p.glow.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );

    if (s.mood != KerriganDonationTier.flight || s.celebrating) {
      // The floor shadow shrinks as Delta rises.
      final lift = (-bob.dy).clamp(0, 12) / 12;
      final floor = Offset(s.center.dx, s.center.dy + s.size * 0.47);
      canvas.drawOval(
        Rect.fromCenter(
          center: floor,
          width: s.size * (0.62 - 0.12 * lift),
          height: 12,
        ),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.3 - 0.1 * lift)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
    }

    if (s.mood == KerriganDonationTier.surge && !s.celebrating) {
      // Lightning now and then.
      final slot = (t / 1.4).floor();
      if (t - slot * 1.4 < 0.16) {
        final paint = Paint()
          ..color = p.accent2.withValues(alpha: 0.85)
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round;
        final left = _rnd(slot, 12) < 0.5;
        final x = left
            ? s.center.dx - s.size * 0.55
            : s.center.dx + s.size * 0.55;
        _bolt(canvas, Offset(x, 0), Offset(x, s.center.dy), slot, paint);
        canvas.drawRect(
          Offset.zero & size,
          Paint()..color = Colors.white.withValues(alpha: 0.04),
        );
      }
    }

    if (s.egg == KerriganDonationEgg.overload) _giantCell(canvas, size, t);
  }

  /// $250 and up: a power cell stretching past the top of the stage.
  void _giantCell(Canvas canvas, Size size, double t) {
    final p = s.palette;
    final width = math.min(size.width * 0.34, 150.0);
    final left = size.width * 0.56;
    final bottom = size.height - 10;
    final stretch = 1.2 + 0.08 * math.sin(t * 2.4);
    final top = bottom - size.height * stretch;
    final body = RRect.fromLTRBR(
      left,
      top,
      left + width,
      bottom,
      const Radius.circular(18),
    );
    canvas.drawRRect(body, Paint()..color = p.glow.withValues(alpha: 0.32));
    final stroke = Paint()
      ..color = p.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawRRect(body, stroke);
    // Charge bars, filling up and up.
    for (var i = 0; i < 7; i++) {
      final y = bottom - 40 - ((i * 34 + t * 50) % (bottom - 40 - top));
      canvas.drawRRect(
        RRect.fromLTRBR(
          left + 14,
          y - 6,
          left + width - 14,
          y + 6,
          const Radius.circular(3),
        ),
        Paint()..color = p.accent.withValues(alpha: 0.22),
      );
    }
    // The bolt badge.
    final badge = Offset(left + width / 2, bottom - 48);
    canvas.drawCircle(badge, 20, Paint()..color = p.bottom);
    canvas.drawCircle(
      badge,
      20,
      Paint()
        ..color = p.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    _boltBadge(canvas, badge, 13, p.accent);
  }

  @override
  bool shouldRepaint(_BackPainter old) => true;
}

/// In front of Delta: the tier's particles, the eggs' props, the burst
/// after a tap and confetti.
class _FrontPainter extends CustomPainter {
  _FrontPainter(this.s) : super(repaint: s.time);

  final _Scene s;

  @override
  void paint(Canvas canvas, Size size) {
    final t = s.t;
    final p = s.palette;
    final c = s.center + s.bob;
    final half = s.size / 2;

    if (s.celebrating) {
      _confetti(canvas, size, t);
    } else {
      switch (s.mood) {
        case KerriganDonationTier.console:
          // Code bits flying off the keyboard.
          for (var i = 0; i < 9; i++) {
            final phase = ((t * 0.9 + _rnd(i, 21)) % 1);
            final x = c.dx + (_rnd(i, 22) - 0.5) * s.size * 0.9;
            final y = c.dy + half * 0.4 - phase * half * 1.3;
            _text(
              canvas,
              _rnd(i, 23) < 0.5 ? "0" : "1",
              Offset(x, y),
              10,
              p.accent.withValues(alpha: math.sin(phase * math.pi) * 0.9),
              weight: FontWeight.w600,
            );
          }
        case KerriganDonationTier.hyperdrive:
          // Particles racing around a ring; the far half is dimmer.
          for (var i = 0; i < 12; i++) {
            final a = t * 2.6 + i / 12 * math.pi * 2;
            final pos =
                c +
                Offset(math.cos(a) * half * 1.02, math.sin(a) * half * 0.28);
            final near = (math.sin(a) + 1) / 2;
            canvas.drawCircle(
              pos,
              1.5 + 2 * near,
              Paint()
                ..color = (i.isEven ? p.accent : Colors.white).withValues(
                  alpha: 0.25 + 0.65 * near,
                ),
            );
          }
        case KerriganDonationTier.surge:
          // Sparks around the edges.
          final slot = (t * 8).floor();
          for (var i = 0; i < 3; i++) {
            if (_rnd(slot, 40 + i) < 0.5) continue;
            final a = _rnd(slot, 50 + i) * math.pi * 2;
            final from = c + Offset(math.cos(a), math.sin(a)) * half * 0.75;
            final to = c + Offset(math.cos(a), math.sin(a)) * half * 0.98;
            _bolt(
              canvas,
              from,
              to,
              slot + i,
              Paint()
                ..color = Colors.white.withValues(alpha: 0.85)
                ..strokeWidth = 1.5
                ..style = PaintingStyle.stroke,
            );
          }
        case KerriganDonationTier.spark:
        case KerriganDonationTier.cell:
        case KerriganDonationTier.flight:
        case KerriganDonationTier.custom:
          break;
      }
      // Twinkles, more of them for bigger tiers.
      final count = 2 + s.energy;
      for (var i = 0; i < count; i++) {
        final a = _rnd(i, 61) * math.pi * 2;
        final d = half * (0.75 + 0.3 * _rnd(i, 62));
        final pos = c + Offset(math.cos(a) * d, math.sin(a) * d * 0.8);
        final tw = math.max(0.0, math.sin(t * (1.5 + _rnd(i, 63) * 2) + i * 2));
        _sparkle(
          canvas,
          pos,
          2 + 4 * tw,
          (i.isEven ? p.accent : p.accent2).withValues(alpha: 0.9 * tw),
        );
      }
    }

    switch (s.egg) {
      case KerriganDonationEgg.lowBattery:
        _lowBattery(canvas, c + Offset(half * 0.78, half * 0.45), t);
      case KerriganDonationEgg.fuelNotFound:
        _phantomCell(canvas, size, c + Offset(half * 0.8, half * 0.4), t);
      case KerriganDonationEgg.overload:
        // Little arrows up the power cell.
        for (var i = 0; i < 3; i++) {
          final phase = ((t * 0.6 + i / 3) % 1);
          _text(
            canvas,
            "↑",
            Offset(size.width * 0.5, size.height * (0.8 - phase * 0.7)),
            16,
            Colors.white.withValues(alpha: math.sin(phase * math.pi) * 0.7),
          );
        }
      case null:
        break;
    }

    // The burst after a tap.
    final poked = s.pokedAt;
    if (poked != null && t - poked < 0.7) {
      final k = (t - poked) / 0.7;
      for (var i = 0; i < 10; i++) {
        final a = i / 10 * math.pi * 2 + _rnd(i, 71);
        final pos =
            c + Offset(math.cos(a), math.sin(a)) * half * (0.3 + k * 0.8);
        _sparkle(
          canvas,
          pos,
          5 * (1 - k) + 1,
          (i.isEven ? p.accent2 : Colors.white).withValues(alpha: 1 - k),
        );
      }
    }
  }

  /// Under a dollar: a battery with one blinking bar, and a question.
  void _lowBattery(Canvas canvas, Offset bottom, double t) {
    final p = s.palette;
    final o = bottom + Offset(0, 3 * math.sin(t * 2));
    final body = RRect.fromLTRBR(
      o.dx - 22,
      o.dy - 28,
      o.dx + 18,
      o.dy - 6,
      const Radius.circular(4),
    );
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white.withValues(alpha: 0.85);
    canvas.drawRRect(body, outline);
    canvas.drawRRect(
      RRect.fromLTRBR(
        o.dx + 18,
        o.dy - 21,
        o.dx + 23,
        o.dy - 13,
        const Radius.circular(1.5),
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.85),
    );
    if ((t * 1.6) % 1 < 0.6) {
      canvas.drawRRect(
        RRect.fromLTRBR(
          o.dx - 18,
          o.dy - 24,
          o.dx - 12,
          o.dy - 10,
          const Radius.circular(1.5),
        ),
        Paint()..color = const Color(0xFFF87171),
      );
    }
    _text(
      canvas,
      "?",
      o + Offset(10 + 2 * math.sin(t * 4), -46),
      20,
      p.accent2,
    );
  }

  /// $4.04: an outline of a power cell that keeps blinking out, and a torn
  /// picture.
  void _phantomCell(Canvas canvas, Size size, Offset bottom, double t) {
    final p = s.palette;
    final g = _glitch(t);
    if (g > 0) {
      for (var i = 0; i < 4; i++) {
        final y = _rnd((t * 30).floor(), 80 + i) * size.height;
        canvas.drawRect(
          Rect.fromLTWH(0, y, size.width, 2 + 6 * _rnd(i, 81)),
          Paint()
            ..color = (i.isEven ? Colors.cyan : Colors.pinkAccent).withValues(
              alpha: 0.18,
            ),
        );
      }
    }
    final on = _rnd((t * 6).floor(), 90) > 0.25;
    if (!on) return;
    final dash = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = p.accent.withValues(alpha: 0.75);
    final cell = Rect.fromLTRB(
      bottom.dx - 13,
      bottom.dy - 38,
      bottom.dx + 13,
      bottom.dy,
    );
    // Dashed sides, bottom and top.
    void dashed(Offset a, Offset b) {
      const n = 6;
      for (var i = 0; i < n; i += 2) {
        canvas.drawLine(
          Offset.lerp(a, b, i / n)!,
          Offset.lerp(a, b, (i + 1) / n)!,
          dash,
        );
      }
    }

    dashed(cell.topLeft, cell.bottomLeft);
    dashed(cell.bottomLeft, cell.bottomRight);
    dashed(cell.bottomRight, cell.topRight);
    dashed(cell.topLeft, cell.topRight);
    // The terminal on top.
    dashed(
      Offset(cell.center.dx - 5, cell.top),
      Offset(cell.center.dx - 5, cell.top - 5),
    );
    dashed(
      Offset(cell.center.dx + 5, cell.top),
      Offset(cell.center.dx + 5, cell.top - 5),
    );
    _boltBadge(canvas, cell.center, 16, p.accent.withValues(alpha: 0.5));
    _text(canvas, "404", Offset(cell.center.dx, cell.top - 16), 12, p.accent2);
  }

  void _confetti(Canvas canvas, Size size, double t) {
    final p = s.palette;
    final colors = [p.accent, p.accent2, Colors.white, const Color(0xFFFBBF24)];
    for (var i = 0; i < 40; i++) {
      final speed = 50 + _rnd(i, 101) * 70;
      final y =
          (_rnd(i, 102) * size.height + t * speed) % (size.height + 20) - 10;
      final x = _rnd(i, 103) * size.width + 10 * math.sin(t * 2 + i);
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(t * (1 + _rnd(i, 104) * 3) + i);
      canvas.drawRect(
        const Rect.fromLTWH(-3, -1.5, 6, 3),
        Paint()..color = colors[i % colors.length],
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_FrontPainter old) => true;
}
