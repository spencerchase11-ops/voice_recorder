import 'package:flutter/widgets.dart';

import '../spec.dart';
import 'frame.dart';

/// The red title bar at the top of every screen.
class RedHeader extends StatelessWidget {
  const RedHeader({super.key, required this.title, this.children = const []});

  final String title;

  /// Icons and buttons, positioned in header coordinates (0..width, 0..48).
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: Spec.headerHeight,
      child: DecoratedBox(
        decoration: const BoxDecoration(gradient: Spec.headerGradient),
        child: Stack(
          children: [
            Center(
              child: AText(
                title,
                style: Spec.headerTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// A red bar at the bottom split into equal cells by dark dividers.
class RedFooter extends StatelessWidget {
  const RedFooter({super.key, required this.height, required this.cells});

  final double height;
  final List<Widget> cells;

  @override
  Widget build(BuildContext context) {
    // On iPhone the bar goes on under the home indicator, its shading drawn
    // out to the screen's edge; the cells keep their height.
    final bottom = ScreenFrame.homeIndicatorOf(context);
    return SizedBox(
      height: height + bottom,
      child: DecoratedBox(
        decoration: const BoxDecoration(gradient: Spec.footerGradient),
        child: Padding(
          padding: EdgeInsets.only(bottom: bottom),
          child: CustomPaint(
            foregroundPainter: _DividerPainter(cells.length),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final c in cells) Expanded(child: c)],
            ),
          ),
        ),
      ),
    );
  }
}

class _DividerPainter extends CustomPainter {
  _DividerPainter(this.count);

  final int count;

  @override
  void paint(Canvas canvas, Size size) {
    final dark = Paint()..color = Spec.barDividerColor;
    final light = Paint()..color = const Color(0x16FFFFFF);
    for (var i = 1; i < count; i++) {
      final x = size.width * i / count;
      const w = Spec.barDividerWidth;
      canvas
        ..drawRect(Rect.fromLTWH(x - w / 2 - 0.3, 0, 0.3, size.height), light)
        ..drawRect(Rect.fromLTWH(x - w / 2, 0, w, size.height), dark)
        ..drawRect(Rect.fromLTWH(x + w / 2, 0, 0.3, size.height), light);
    }
  }

  @override
  bool shouldRepaint(_DividerPainter old) => old.count != count;
}

/// A header/footer button: an invisible 48 dp touch target with a white
/// pressed highlight around an icon positioned by its measured centre. The
/// icon is dimmed while the button can't be used (during a recording).
class BarButton extends StatelessWidget {
  const BarButton({
    super.key,
    required this.center,
    required this.child,
    required this.onTap,
    this.touchSize = const Size(48, 48),
    this.semanticLabel,
  });

  final Offset center;
  final Widget child;
  final VoidCallback? onTap;
  final Size touchSize;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: center.dx - touchSize.width / 2,
      top: center.dy - touchSize.height / 2,
      width: touchSize.width,
      height: touchSize.height,
      child: PressableArea(
        onTap: onTap,
        semanticLabel: semanticLabel,
        highlight: const Color(0x33FFFFFF),
        child: Center(
          child: Opacity(opacity: onTap == null ? 0.4 : 1, child: child),
        ),
      ),
    );
  }
}
