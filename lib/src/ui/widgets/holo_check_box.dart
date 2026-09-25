import 'package:flutter/widgets.dart';

import '../spec.dart';

/// A Holo (dark) check box: a light square, with a blue tick when on.
class HoloCheckBox extends StatelessWidget {
  const HoloCheckBox({super.key, required this.checked});

  final bool checked;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 24,
    child: CustomPaint(painter: _CheckBoxPainter(checked)),
  );
}

class _CheckBoxPainter extends CustomPainter {
  _CheckBoxPainter(this.checked);

  final bool checked;

  @override
  void paint(Canvas canvas, Size size) {
    final box = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: 17,
      height: 17,
    );
    canvas
      ..drawRect(box, Paint()..color = const Color(0x33000000))
      ..drawRect(
        box,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = const Color(0xFFD8D8D8),
      );
    if (!checked) return;
    final tick = Path()
      ..moveTo(box.left + 3.2, box.center.dy + 0.2)
      ..lineTo(box.left + 7.2, box.bottom - 3.6)
      ..lineTo(box.right + 2.6, box.top - 3.2);
    canvas.drawPath(
      tick,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = Spec.holoBlue,
    );
  }

  @override
  bool shouldRepaint(_CheckBoxPainter old) => old.checked != checked;
}
