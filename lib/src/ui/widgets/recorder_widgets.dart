import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../spec.dart';
import 'frame.dart';

/// The recessed "LCD" panel that holds the timer: an inner shadow along the
/// top and left edges and a light bevel along the bottom and right edges.
class TimerBox extends StatelessWidget {
  const TimerBox({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: Spec.timerBoxWidth,
      height: Spec.timerBoxHeight,
      child: CustomPaint(
        painter: const _TimerBoxPainter(),
        child: Center(
          child: AText(
            text,
            style: Spec.timerText,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
          ),
        ),
      ),
    );
  }
}

class _TimerBoxPainter extends CustomPainter {
  const _TimerBoxPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const r = Radius.circular(Spec.timerBoxRadius);
    final body = RRect.fromRectAndRadius(Offset.zero & size, r);

    // bevel: the body shape shifted down/right, minus the body itself
    final bevel = Path.combine(
      PathOperation.difference,
      Path()..addRRect(
        body.shift(const Offset(Spec.timerBevel * 0.95, Spec.timerBevel)),
      ),
      Path()..addRRect(body),
    );
    canvas.drawPath(bevel, Paint()..color = const Color(0xFFA6A6A6));

    // slight darkening of the panel
    canvas.drawRRect(body, Paint()..color = const Color(0x0A000000));

    // inner shadow along the top and left edges
    canvas.save();
    canvas.clipRRect(body);
    final ring = Path.combine(
      PathOperation.difference,
      Path()..addRect(body.outerRect.inflate(20)),
      Path()..addRRect(body.shift(const Offset(1.4, 1.6))),
    );
    canvas.drawPath(
      ring,
      Paint()
        ..color = const Color(0x8C000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.2),
    );
    canvas.restore();

    // crisp dark rim
    canvas.drawRRect(
      body.deflate(0.3),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6
        ..color = const Color(0x40000000),
    );
  }

  @override
  bool shouldRepaint(_TimerBoxPainter oldDelegate) => false;
}

/// Ten squares under the timer; [lit] of them are blue.
class LevelMeter extends StatelessWidget {
  const LevelMeter({super.key, required this.lit});

  final int lit;

  static double get width =>
      Spec.meterPitch * (Spec.meterSegments - 1) + Spec.meterSquareWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: Spec.meterSquareHeight,
      child: CustomPaint(painter: _MeterPainter(lit)),
    );
  }
}

class _MeterPainter extends CustomPainter {
  _MeterPainter(this.lit);

  final int lit;

  @override
  void paint(Canvas canvas, Size size) {
    final on = Paint()..color = Spec.meterOn;
    final off = Paint()..color = Spec.meterOff;
    for (var i = 0; i < Spec.meterSegments; i++) {
      canvas.drawRect(
        Rect.fromLTWH(
          i * Spec.meterPitch,
          0,
          Spec.meterSquareWidth,
          Spec.meterSquareHeight,
        ),
        i < lit ? on : off,
      );
    }
  }

  @override
  bool shouldRepaint(_MeterPainter old) => old.lit != lit;
}

/// One of the glossy bitmap buttons (record, play, list play).
class GlossyButton extends StatefulWidget {
  const GlossyButton({
    super.key,
    required this.asset,
    required this.size,
    required this.onTap,
    this.semanticLabel,
  });

  final String asset;
  final Size size;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  State<GlossyButton> createState() => _GlossyButtonState();
}

class _GlossyButtonState extends State<GlossyButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    Widget img = Image.asset(
      widget.asset,
      width: widget.size.width,
      height: widget.size.height,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
    );
    if (_down) {
      img = ColorFiltered(
        colorFilter: const ColorFilter.matrix([
          0.75, 0, 0, 0, 0, //
          0, 0.75, 0, 0, 0,
          0, 0, 0.75, 0, 0,
          0, 0, 0, 1, 0,
        ]),
        child: img,
      );
    }
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapUp: enabled ? (_) => setState(() => _down = false) : null,
        onTapCancel: enabled ? () => setState(() => _down = false) : null,
        onTap: widget.onTap,
        child: Opacity(opacity: enabled ? 1 : 0.45, child: img),
      ),
    );
  }
}

/// The "no ads" badge: white outline on the Recorder screen, red/green in
/// Settings.
class AdsBadge extends StatelessWidget {
  const AdsBadge({super.key, required this.size, this.colored = false});

  final double size;
  final bool colored;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size.square(size), painter: _AdsPainter(colored));
  }
}

class _AdsPainter extends CustomPainter {
  _AdsPainter(this.colored);

  final bool colored;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final c = Offset(s / 2, s / 2);
    final ringColor = colored
        ? const Color(0xFFFF0A0A)
        : const Color(0xFFFFFFFF);
    final ringWidth = s * (colored ? 0.115 : 0.085);
    final r = s / 2 - ringWidth / 2;

    if (colored) {
      canvas.drawCircle(c, r, Paint()..color = const Color(0xFFFFFFFF));
    }

    final tp = TextPainter(
      text: TextSpan(
        text: 'Ads',
        style: TextStyle(
          fontFamily: Spec.font,
          fontWeight: FontWeight.w900,
          fontSize: s * 0.42,
          letterSpacing: -s * 0.012,
          color: colored ? const Color(0xFF12E012) : const Color(0xFFFFFFFF),
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, c - Offset(tp.width / 2, tp.height * 0.52));

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = ringWidth
      ..color = ringColor;
    canvas.drawCircle(c, r, ring);
    final d = r * math.cos(math.pi / 4);
    canvas.drawLine(
      c + Offset(-d, -d),
      c + Offset(d, d),
      Paint()
        ..strokeWidth = ringWidth * (colored ? 0.95 : 0.9)
        ..color = ringColor,
    );
  }

  @override
  bool shouldRepaint(_AdsPainter old) => old.colored != colored;
}
