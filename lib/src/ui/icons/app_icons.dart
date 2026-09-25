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
}

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
