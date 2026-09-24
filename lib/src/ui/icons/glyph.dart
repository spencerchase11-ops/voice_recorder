import 'dart:typed_data';
import 'dart:ui';

/// A vector icon outline in its own coordinate space.
///
/// The outline's ink bounding box spans (0, 0) to ([width], [height]), so a
/// glyph can be scaled to the exact ink size measured from the reference
/// screenshots.
class Glyph {
  const Glyph(this.width, this.height, this.data);

  final double width;
  final double height;

  /// SVG path data (absolute or relative M, L, H, V, Q, T, C, S, Z commands).
  final String data;

  static final Map<String, Path> _cache = {};

  Path get path => _cache[data] ??= parseSvgPath(data);

  /// Returns the outline scaled to fill [ink] exactly.
  Path fit(Rect ink) {
    final m = Float64List(16)
      ..[0] = ink.width / width
      ..[5] = ink.height / height
      ..[10] = 1
      ..[12] = ink.left
      ..[13] = ink.top
      ..[15] = 1;
    return path.transform(m);
  }
}

/// Minimal SVG path-data parser (enough for font outlines and our own icons).
Path parseSvgPath(String d) {
  final path = Path()..fillType = PathFillType.nonZero;
  final tokens = _tokenize(d);
  var i = 0;
  var cmd = '';
  var cx = 0.0, cy = 0.0; // current point
  var sx = 0.0, sy = 0.0; // sub-path start
  var lcx = 0.0, lcy = 0.0; // last control point (for S/T)
  var lastCmd = '';

  double next() => tokens[i++] as double;

  while (i < tokens.length) {
    final t = tokens[i];
    if (t is String) {
      cmd = t;
      i++;
      if (cmd == 'Z' || cmd == 'z') {
        path.close();
        cx = sx;
        cy = sy;
        lastCmd = cmd;
        continue;
      }
    }
    final rel = cmd.toLowerCase() == cmd;
    final ox = rel ? cx : 0.0;
    final oy = rel ? cy : 0.0;
    switch (cmd.toUpperCase()) {
      case 'M':
        cx = ox + next();
        cy = oy + next();
        path.moveTo(cx, cy);
        sx = cx;
        sy = cy;
        // subsequent pairs are implicit line-tos
        cmd = rel ? 'l' : 'L';
      case 'L':
        cx = ox + next();
        cy = oy + next();
        path.lineTo(cx, cy);
      case 'H':
        cx = ox + next();
        path.lineTo(cx, cy);
      case 'V':
        cy = oy + next();
        path.lineTo(cx, cy);
      case 'Q':
        final x1 = ox + next(), y1 = oy + next();
        cx = ox + next();
        cy = oy + next();
        path.quadraticBezierTo(x1, y1, cx, cy);
        lcx = x1;
        lcy = y1;
      case 'T':
        final reflect =
            lastCmd.toUpperCase() == 'Q' || lastCmd.toUpperCase() == 'T';
        final x1 = reflect ? 2 * cx - lcx : cx;
        final y1 = reflect ? 2 * cy - lcy : cy;
        cx = ox + next();
        cy = oy + next();
        path.quadraticBezierTo(x1, y1, cx, cy);
        lcx = x1;
        lcy = y1;
      case 'C':
        final x1 = ox + next(), y1 = oy + next();
        final x2 = ox + next(), y2 = oy + next();
        cx = ox + next();
        cy = oy + next();
        path.cubicTo(x1, y1, x2, y2, cx, cy);
        lcx = x2;
        lcy = y2;
      case 'S':
        final reflect =
            lastCmd.toUpperCase() == 'C' || lastCmd.toUpperCase() == 'S';
        final x1 = reflect ? 2 * cx - lcx : cx;
        final y1 = reflect ? 2 * cy - lcy : cy;
        final x2 = ox + next(), y2 = oy + next();
        cx = ox + next();
        cy = oy + next();
        path.cubicTo(x1, y1, x2, y2, cx, cy);
        lcx = x2;
        lcy = y2;
      default:
        throw FormatException('Unsupported path command "$cmd"', d);
    }
    lastCmd = cmd;
  }
  return path;
}

List<Object> _tokenize(String d) {
  final out = <Object>[];
  final re = RegExp(
    r'[MmLlHhVvQqTtCcSsZz]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?',
  );
  for (final m in re.allMatches(d)) {
    final s = m.group(0)!;
    final c = s.codeUnitAt(0);
    final isCmd = (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
    out.add(isCmd && s != 'e' && s != 'E' ? s : double.parse(s));
  }
  return out;
}
