import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'glyph.dart';
import 'glyph_data.dart';

/// An icon drawn into an exact ink rectangle.
///
/// The original app's icons were bitmaps; here each icon is a vector outline
/// that is scaled so its *ink* fills the rectangle measured from the
/// reference screenshots.
abstract class IconShape {
  const IconShape();

  void paint(Canvas canvas, Rect ink, Color color);
}

class GlyphShape extends IconShape {
  const GlyphShape(this.glyph);

  final Glyph glyph;

  @override
  void paint(Canvas canvas, Rect ink, Color color) {
    canvas.drawPath(glyph.fit(ink), Paint()..color = color);
  }
}

/// A shape built from a path in its own coordinate space, whose bounds are
/// fitted into the ink rectangle.
class PathShape extends IconShape {
  const PathShape(this.builder);

  final Path Function() builder;

  static final Map<Object, Path> _cache = {};

  @override
  void paint(Canvas canvas, Rect ink, Color color) {
    final path = _cache[builder] ??= builder();
    final b = path.getBounds();
    final m = Float64List(16)
      ..[0] = ink.width / b.width
      ..[5] = ink.height / b.height
      ..[10] = 1
      ..[12] = ink.left - b.left * ink.width / b.width
      ..[13] = ink.top - b.top * ink.height / b.height
      ..[15] = 1;
    canvas.drawPath(path.transform(m), Paint()..color = color);
  }
}

/// An outline drawn with a stroke; [builder] returns the centre line.
class StrokeShape extends IconShape {
  const StrokeShape(this.builder, this.strokeWidth);

  final Path Function() builder;

  /// Stroke width in the path's own units.
  final double strokeWidth;

  static final Map<Object, Path> _cache = {};

  @override
  void paint(Canvas canvas, Rect ink, Color color) {
    final path = _cache[builder] ??= builder();
    final b = path.getBounds().inflate(strokeWidth / 2);
    final sx = ink.width / b.width;
    final sy = ink.height / b.height;
    canvas
      ..save()
      ..translate(ink.left - b.left * sx, ink.top - b.top * sy)
      ..scale(sx, sy)
      ..drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeJoin = StrokeJoin.round
          ..color = color,
      )
      ..restore();
  }
}

/// A shape drawn in its own [box] (its ink spans exactly 0..width and
/// 0..height there), which is stretched to the ink rectangle.
class DrawnShape extends IconShape {
  const DrawnShape(this.draw, this.box);

  final void Function(Canvas canvas, Paint paint) draw;
  final Size box;

  @override
  void paint(Canvas canvas, Rect ink, Color color) {
    canvas
      ..save()
      ..translate(ink.left, ink.top)
      ..scale(ink.width / box.width, ink.height / box.height);
    draw(canvas, Paint()..color = color);
    canvas.restore();
  }
}

/// Every icon used by the three screens.
abstract final class AppIcons {
  static const share = GlyphShape(GlyphData.share);
  static const trash = GlyphShape(GlyphData.trash);
  static const floppy = GlyphShape(GlyphData.floppy);
  static const folderOpen = GlyphShape(GlyphData.folderOpen);
  static const star = GlyphShape(GlyphData.star);
  static const mic = GlyphShape(GlyphData.mic);
  static const gear = StrokeShape(_gear, 4.5);
  static const about = GlyphShape(GlyphData.errorOutline);
  static const file = GlyphShape(GlyphData.fileOutline);
  static const pencil = PathShape(_pencil);
  static const list = PathShape(_list);
  static const back = PathShape(_chevron);
  static const quality = PathShape(_quality);

  // Added with the upgrades.
  static const search = GlyphShape(GlyphData.search);
  static const sort = GlyphShape(GlyphData.sortDown);
  static const close = GlyphShape(GlyphData.close);
  static const checkBox = GlyphShape(GlyphData.checkBox);
  static const checkBoxBlank = GlyphShape(GlyphData.checkBoxBlank);
  static const selectAll = GlyphShape(GlyphData.doneAll);
  static const restore = GlyphShape(GlyphData.restoreFromTrash);
  static const deleteForever = GlyphShape(GlyphData.deleteForever);
  static const emptyTrash = GlyphShape(GlyphData.deleteSweep);
  static const recentlyDeleted = GlyphShape(GlyphData.autoDelete);
  static const import = GlyphShape(GlyphData.download);
  static const calendar = GlyphShape(GlyphData.event);
  static const lock = GlyphShape(GlyphData.lock);
  static const speed = GlyphShape(GlyphData.speed);
  static const noise = GlyphShape(GlyphData.noiseAware);
  static const replay10 = GlyphShape(GlyphData.replay10);
  static const forward10 = GlyphShape(GlyphData.forward10);

  // The recording page, drawn after the original's.
  static const deleteFilled = GlyphShape(GlyphData.deleteFilled);
  static const shareFilled = GlyphShape(GlyphData.shareFilled);
  static const musicNote = DrawnShape(_musicNote, Size(20, 20));
  static const expand = DrawnShape(_expand, Size(20, 20));
  static const playedAt = DrawnShape(_playedAt, Size(25.1, 23.4));
  static const length = DrawnShape(_length, Size(24.3, 24.3));
  static const skipPrevious = DrawnShape(_skipPrevious, Size(16.9, 10.6));
  static const skipNext = DrawnShape(_skipNext, Size(16.9, 10.6));
  static const rewind = DrawnShape(_rewind, Size(24, 15.1));
  static const fastForward = DrawnShape(_fastForward, Size(24, 15.1));
  static const pause = DrawnShape(_pause, Size(15.7, 22));
  static const play = DrawnShape(_play, Size(18.5, 21.4));
}

// ------------------------------------------------------- recording page

Paint _stroke(Paint p, double width) => Paint()
  ..color = p.color
  ..style = PaintingStyle.stroke
  ..strokeWidth = width;

/// Two beamed-off notes' worth of flags on one stem: a tilted head at the
/// bottom left, the stem and two wavy flags to the right.
void _musicNote(Canvas c, Paint p) {
  c
    ..save()
    ..translate(4.78, 16.11)
    ..rotate(-25 * math.pi / 180)
    ..drawOval(Rect.fromCenter(center: Offset.zero, width: 10, height: 7.2), p)
    ..restore()
    ..drawRect(const Rect.fromLTRB(8.2, 1.0, 9.7, 15.6), p);
  final flag = _stroke(p, 2)..strokeCap = StrokeCap.round;
  for (final y in const [1.0, 6.0]) {
    c.drawPath(
      Path()
        ..moveTo(9.2, y)
        ..cubicTo(12.6, y + 0.4, 13.2, y + 3.4, 16.0, y + 2.7)
        ..cubicTo(17.6, y + 2.3, 18.4, y + 1.0, 19.0, y + 0.2),
      flag,
    );
  }
}

/// Four thin arrows pointing out to the corners.
void _expand(Canvas c, Paint p) {
  const w = 1.6, e = w / 2, leg = 6.2, inner = 7.4;
  final s = _stroke(p, w)..strokeJoin = StrokeJoin.miter;
  final corner = Path()
    ..moveTo(e, e + leg)
    ..lineTo(e, e)
    ..lineTo(e + leg, e)
    ..moveTo(e, e)
    ..lineTo(inner, inner);
  for (final (sx, sy) in const [(1.0, 1.0), (-1.0, 1.0), (1.0, -1.0)]) {
    c
      ..save()
      ..translate(10, 10)
      ..scale(sx, sy)
      ..translate(-10, -10)
      ..drawPath(corner, s)
      ..restore();
  }
  c
    ..save()
    ..translate(10, 10)
    ..scale(-1, -1)
    ..translate(-10, -10)
    ..drawPath(corner, s)
    ..restore();
}

/// When it was recorded: a circle turning back, with a play mark inside.
void _playedAt(Canvas c, Paint p) {
  const r = 10.7, w = 2.0, cx = 25.1 - r - w / 2, cy = 23.4 / 2;
  c.drawArc(
    Rect.fromCircle(center: const Offset(cx, cy), radius: r),
    math.pi - 0.05,
    5 * math.pi / 3,
    false,
    _stroke(p, w),
  );
  // The arrowhead on the left, pointing down.
  const ax = cx - r;
  c
    ..drawPath(
      Path()
        ..moveTo(ax - 2.7, cy - 0.6)
        ..lineTo(ax + 2.7, cy - 0.6)
        ..lineTo(ax, cy + 3.4)
        ..close(),
      p,
    )
    ..drawPath(
      Path()
        ..moveTo(cx - 2.4, cy - 4.0)
        ..lineTo(cx + 4.2, cy)
        ..lineTo(cx - 2.4, cy + 4.0)
        ..close(),
      p,
    );
}

/// Its length: a clock face with a quarter filled and dots for the hours.
void _length(Canvas c, Paint p) {
  const r = 11.2, w = 1.9, m = 24.3 / 2;
  const centre = Offset(m, m);
  c
    ..drawCircle(centre, r, _stroke(p, w))
    ..drawPath(
      Path()
        ..moveTo(m, m)
        ..arcTo(
          Rect.fromCircle(center: centre, radius: 7.6),
          -math.pi / 2,
          math.pi / 2,
          false,
        )
        ..close(),
      p,
    );
  for (var hour = 4; hour <= 11; hour++) {
    final a = (hour - 3) * math.pi / 6;
    c
      ..save()
      ..translate(m + 8.0 * math.cos(a), m + 8.0 * math.sin(a))
      ..rotate(a)
      ..drawRect(
        Rect.fromCenter(center: Offset.zero, width: 1.8, height: 1.6),
        p,
      )
      ..restore();
  }
}

Path _triangle(double x0, double x1, double h) => Path()
  ..moveTo(x0, h / 2)
  ..lineTo(x1, 0)
  ..lineTo(x1, h)
  ..close();

void _rewind(Canvas c, Paint p) => c
  ..drawPath(_triangle(0, 12, 15.1), p)
  ..drawPath(_triangle(12, 24, 15.1), p);

void _fastForward(Canvas c, Paint p) => c
  ..drawPath(_triangle(12, 0, 15.1), p)
  ..drawPath(_triangle(24, 12, 15.1), p);

void _skipPrevious(Canvas c, Paint p) => c
  ..drawRect(const Rect.fromLTWH(0, 0, 2.3, 10.6), p)
  ..drawPath(_triangle(2.3, 9.6, 10.6), p)
  ..drawPath(_triangle(9.6, 16.9, 10.6), p);

void _skipNext(Canvas c, Paint p) => c
  ..drawRect(const Rect.fromLTWH(14.6, 0, 2.3, 10.6), p)
  ..drawPath(_triangle(14.6, 7.3, 10.6), p)
  ..drawPath(_triangle(7.3, 0, 10.6), p);

/// Two bars with their corners cut.
void _pause(Canvas c, Paint p) {
  Path bar(double x) {
    const w = 5.0, h = 22.0, cut = 1.3;
    return Path()
      ..moveTo(x + cut, 0)
      ..lineTo(x + w - cut, 0)
      ..lineTo(x + w, cut)
      ..lineTo(x + w, h - cut)
      ..lineTo(x + w - cut, h)
      ..lineTo(x + cut, h)
      ..lineTo(x, h - cut)
      ..lineTo(x, cut)
      ..close();
  }

  c
    ..drawPath(bar(0), p)
    ..drawPath(bar(10.7), p);
}

void _play(Canvas c, Paint p) => c.drawPath(_triangle(18.5, 0, 21.4), p);

// ---------------------------------------------------------------- pencil
//
// Outline pencil lying at 45 degrees with the point at the bottom left. Built
// horizontally (point at x = 0, eraser at x = 100, width 30.2) and rotated.
Path _pencil() {
  // Proportions fitted to the original icon (correlation 0.905).
  const h = 30.0;
  const stroke = 5.4;
  final p = Path()..fillType = PathFillType.evenOdd;

  // Tip: a triangular ring whose inner edges are parallel to the outer ones.
  const tipEnd = 25.0;
  const slope = (h / 2) / tipEnd;
  const innerApex = tipEnd - (h / 2 - stroke) / slope;
  final tip = Path()
    ..fillType = PathFillType.evenOdd
    ..moveTo(0.9, h / 2 - 0.55)
    ..lineTo(tipEnd, 0)
    ..lineTo(tipEnd, h)
    ..lineTo(0.9, h / 2 + 0.55)
    ..close()
    ..moveTo(innerApex, h / 2)
    ..lineTo(tipEnd + 0.01, stroke)
    ..lineTo(tipEnd + 0.01, h - stroke)
    ..close();
  p.addPath(tip, Offset.zero);

  // Body: two outer strokes and a middle bar with a pointed end.
  const bodyEnd = 76.5;
  const mid = 7.2;
  final body = Path()
    ..addRect(const Rect.fromLTRB(tipEnd - 0.2, 0, bodyEnd, stroke))
    ..addRect(const Rect.fromLTRB(tipEnd - 0.2, h - stroke, bodyEnd, h))
    ..moveTo(tipEnd - 0.8, h / 2)
    ..lineTo(tipEnd + 3.6, (h - mid) / 2)
    ..lineTo(bodyEnd, (h - mid) / 2)
    ..lineTo(bodyEnd, (h + mid) / 2)
    ..lineTo(tipEnd + 3.6, (h + mid) / 2)
    ..close();

  // Ferrule band and the rounded eraser.
  final end = Path()
    ..addRect(const Rect.fromLTRB(81.0, 0, 86.5, h))
    ..addRRect(
      RRect.fromLTRBAndCorners(
        91.0,
        0,
        100,
        h,
        topRight: const Radius.circular(0.24 * h),
        bottomRight: const Radius.circular(0.24 * h),
      ),
    );

  final whole = Path.combine(
    PathOperation.union,
    Path.combine(PathOperation.union, tip, body),
    end,
  );
  // point towards the bottom left
  final r = Matrix4.rotationZ(-math.pi / 4).storage;
  return whole.transform(r);
}

// ------------------------------------------------------------------ gear
//
// Outline cog with 12 trapezoid teeth and a centre ring (fitted to the
// original's tab icon, in its 3.5x pixels).
Path _gear() {
  const r0 = 47.5,
      r1 = 56.5,
      root = 10 * math.pi / 180,
      tip = 8 * math.pi / 180;
  final p = Path();
  for (var k = 0; k < 12; k++) {
    final a = k * math.pi / 6;
    final pts = [(a - root, r0), (a - tip, r1), (a + tip, r1), (a + root, r0)];
    for (var i = 0; i < pts.length; i++) {
      final (ang, rad) = pts[i];
      final o = Offset(rad * math.cos(ang), rad * math.sin(ang));
      if (k == 0 && i == 0) {
        p.moveTo(o.dx, o.dy);
      } else {
        p.lineTo(o.dx, o.dy);
      }
    }
  }
  p.close();
  p.addOval(Rect.fromCircle(center: Offset.zero, radius: 22.3));
  return p;
}

// ------------------------------------------------------------------ list
//
// Three ring bullets with lines, in a 113 x 115 unit box.
Path _list() {
  final p = Path()..fillType = PathFillType.evenOdd;
  const cx = 11.25;
  const outer = 11.25;
  const ring = 3.6;
  const lineLeft = 34.5;
  const lineRight = 113.0;
  const line = 4.2;
  for (final cy in const [11.25, 57.5, 103.75]) {
    p
      ..addOval(
        Rect.fromCircle(
          center: const Offset(cx, 0) + Offset(0, cy),
          radius: outer,
        ),
      )
      ..addOval(
        Rect.fromCircle(
          center: const Offset(cx, 0) + Offset(0, cy),
          radius: outer - ring,
        ),
      )
      ..addRect(
        Rect.fromLTRB(lineLeft, cy - line / 2, lineRight, cy + line / 2),
      );
  }
  return p;
}

// --------------------------------------------------------------- chevron
//
// Thin iOS-style "back" chevron, 48 x 92 units, stroke 4.5.
Path _chevron() {
  const w = 48.0, h = 92.0, t = 4.5;
  // outline of a stroked polyline (miter at the point)
  final k = t / 2 / math.sin(math.atan2(w, h / 2));
  return Path()
    ..moveTo(w, 0)
    ..lineTo(w, t * 0.95)
    ..lineTo(k * 1.6 + 0.2, h / 2)
    ..lineTo(w, h - t * 0.95)
    ..lineTo(w, h)
    ..lineTo(0, h / 2)
    ..close();
}

// -------------------------------------------------------- quality badge
//
// Font Awesome "certificate" seal with a thumbs-up knocked out of it.
Path _quality() {
  const g = GlyphData.certificate;
  final seal = g.path;
  final w = g.width, h = g.height;
  Offset at(double x, double y) => Offset(x * w, y * h);

  final thumb = Path()
    // cuff
    ..addRRect(
      RRect.fromRectAndRadius(
        Rect.fromPoints(at(0.255, 0.445), at(0.365, 0.695)),
        Radius.circular(0.012 * w),
      ),
    )
    // fist
    ..addRRect(
      RRect.fromRectAndRadius(
        Rect.fromPoints(at(0.395, 0.425), at(0.695, 0.695)),
        Radius.circular(0.045 * w),
      ),
    );
  // finger knuckles on the right-hand side
  for (final y in const [0.47, 0.54, 0.61, 0.665]) {
    thumb.addOval(Rect.fromCircle(center: at(0.69, y), radius: 0.035 * w));
  }
  // the thumb itself
  thumb
    ..moveTo(0.405 * w, 0.46 * h)
    ..lineTo(0.47 * w, 0.265 * h)
    ..quadraticBezierTo(0.49 * w, 0.195 * h, 0.545 * w, 0.215 * h)
    ..quadraticBezierTo(0.595 * w, 0.24 * h, 0.575 * w, 0.30 * h)
    ..lineTo(0.545 * w, 0.43 * h)
    ..close();
  return Path.combine(PathOperation.difference, seal, thumb);
}

/// Paints [shape] so that its ink exactly fills the widget.
class InkIcon extends StatelessWidget {
  const InkIcon(
    this.shape, {
    super.key,
    required this.size,
    required this.color,
  });

  final IconShape shape;
  final Size size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: size, painter: _InkIconPainter(shape, color));
  }
}

class _InkIconPainter extends CustomPainter {
  _InkIconPainter(this.shape, this.color);

  final IconShape shape;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) =>
      shape.paint(canvas, Offset.zero & size, color);

  @override
  bool shouldRepaint(_InkIconPainter old) =>
      old.shape != shape || old.color != color;
}
