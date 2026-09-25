import 'package:flutter/material.dart' show Material, MaterialType;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../spec.dart';

/// Paints the system-bar areas the way the original looked (black status
/// bar, light navigation bar) now that apps draw edge to edge.
class ScreenFrame extends StatelessWidget {
  const ScreenFrame({super.key, required this.child});

  final Widget child;

  static const overlayStyle = SystemUiOverlayStyle(
    statusBarColor: Color(0x00000000),
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: Spec.navigationBarColor,
    systemNavigationBarIconBrightness: Brightness.dark,
    systemNavigationBarDividerColor: Spec.navigationBarColor,
    systemNavigationBarContrastEnforced: false,
    systemStatusBarContrastEnforced: false,
  );

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.viewPaddingOf(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: PlainText(
        child: ColoredBox(
          color: Spec.statusBarColor,
          child: Column(
            children: [
              SizedBox(height: pad.top),
              Expanded(
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  removeBottom: true,
                  child: MediaQuery.removeViewPadding(
                    context: context,
                    removeTop: true,
                    removeBottom: true,
                    child: child,
                  ),
                ),
              ),
              if (pad.bottom > 0)
                Container(height: pad.bottom, color: Spec.navigationBarColor),
            ],
          ),
        ),
      ),
    );
  }
}

/// Resets the inherited text style (no Material/Scaffold ancestors are used)
/// and provides a transparent Material for text fields.
class PlainText extends StatelessWidget {
  const PlainText({super.key, required this.child});

  final Widget child;

  static const style = TextStyle(
    fontFamily: Spec.font,
    fontWeight: FontWeight.w400,
    fontStyle: FontStyle.normal,
    color: Color(0xFFFFFFFF),
    decoration: TextDecoration.none,
    letterSpacing: 0,
    wordSpacing: 0,
  );

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: DefaultTextStyle(style: style, child: child),
    );
  }
}

/// The brushed-metal page background. The tile repeats vertically and is
/// scaled to the screen width, so its lighter band stays left of centre.
class BrushedMetal extends StatelessWidget {
  const BrushedMetal({super.key, this.child});

  final Widget? child;

  static const image = DecorationImage(
    image: AssetImage(Spec.metalTexture),
    fit: BoxFit.fitWidth,
    repeat: ImageRepeat.repeatY,
    alignment: Alignment.topCenter,
    filterQuality: FilterQuality.medium,
  );

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: Color(0xFF555555), image: image),
      child: child ?? const SizedBox.expand(),
    );
  }
}

/// Font metrics of Roboto rounded the way Android's `Paint.FontMetricsInt`
/// rounds them (in physical pixels), which is what TextView layout uses.
class AndroidFontMetrics {
  AndroidFontMetrics._(
    this.dpr,
    this.fontSize,
    this.topPx,
    this.ascentPx,
    this.descentPx,
    this.bottomPx,
  );

  factory AndroidFontMetrics.of(BuildContext context, TextStyle style) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final fs = MediaQuery.textScalerOf(context).scale(style.fontSize!);
    final px = fs * dpr;
    // Roboto: yMax 2163, ascender 1900, descender 500, |yMin| 555 (per 2048).
    return AndroidFontMetrics._(
      dpr,
      fs,
      (px * 2163 / 2048).ceilToDouble(),
      (px * 1900 / 2048).ceilToDouble(),
      (px * 500 / 2048).ceilToDouble(),
      (px * 555 / 2048).ceilToDouble(),
    );
  }

  final double dpr;

  /// Scaled font size in logical pixels.
  final double fontSize;
  final double topPx, ascentPx, descentPx, bottomPx;

  /// Distance between baselines of consecutive lines.
  double get lineHeight => (ascentPx + descentPx) / dpr;

  /// Baseline of the first line, from the top of the TextView.
  double get firstBaseline => topPx / dpr;

  /// Height of a TextView with [lines] lines (`includeFontPadding` on).
  double height([int lines = 1]) =>
      (topPx + bottomPx + (lines - 1) * (ascentPx + descentPx)) / dpr;
}

/// Text laid out like an Android TextView with `includeFontPadding`: the same
/// height and baseline positions as the original app, for any font scale.
class AText extends StatelessWidget {
  const AText(
    this.text, {
    super.key,
    required this.style,
    this.maxLines,
    this.textAlign,
    this.overflow,
    this.softWrap,
  });

  final String text;
  final TextStyle style;
  final int? maxLines;
  final TextAlign? textAlign;
  final TextOverflow? overflow;
  final bool? softWrap;

  /// Height of an [AText] with [lines] lines.
  static double boxHeight(
    BuildContext context,
    TextStyle style, [
    int lines = 1,
  ]) => AndroidFontMetrics.of(context, style).height(lines);

  static const _behavior = TextHeightBehavior(
    leadingDistribution: TextLeadingDistribution.even,
  );

  @override
  Widget build(BuildContext context) {
    final m = AndroidFontMetrics.of(context, style);
    final lineStyle = style.copyWith(height: m.lineHeight / m.fontSize);
    final fill =
        textAlign != null &&
        textAlign != TextAlign.left &&
        textAlign != TextAlign.start;

    Widget box(int lines) {
      Widget t = Text(
        text,
        style: lineStyle,
        maxLines: maxLines,
        textAlign: textAlign,
        overflow: overflow,
        softWrap: softWrap,
        textHeightBehavior: _behavior,
      );
      if (fill) t = SizedBox(width: double.infinity, child: t);
      return SizedBox(
        height: m.height(lines),
        child: Baseline(
          baseline: m.firstBaseline,
          baselineType: TextBaseline.alphabetic,
          child: t,
        ),
      );
    }

    if (maxLines == 1) return box(1);
    return LayoutBuilder(
      builder: (context, c) {
        final tp = TextPainter(
          text: TextSpan(text: text, style: lineStyle),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: maxLines,
          textHeightBehavior: _behavior,
        )..layout(maxWidth: c.maxWidth.isFinite ? c.maxWidth : double.infinity);
        final lines = tp.computeLineMetrics().length.clamp(1, 1 << 20);
        tp.dispose();
        return box(lines);
      },
    );
  }
}

/// A tappable area that shows the Holo pressed highlight.
class PressableArea extends StatefulWidget {
  const PressableArea({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.highlight = const Color(0x6633B5E5),
    this.semanticLabel,
    this.selected,
    this.checked,
    this.excludeSemantics = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color highlight;
  final String? semanticLabel;

  /// For accessibility: whether this item is ticked (selection mode) or the
  /// open one.
  final bool? selected;

  /// For accessibility: the state of an on/off row.
  final bool? checked;

  /// The [semanticLabel] says all the child's texts do, which would be read
  /// out twice otherwise. False for rows with buttons of their own inside.
  final bool excludeSemantics;

  @override
  State<PressableArea> createState() => _PressableAreaState();
}

class _PressableAreaState extends State<PressableArea> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    // The gestures' tap and long-press actions and these properties make one
    // node for screen readers.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _set(true) : null,
      onTapUp: enabled ? (_) => _set(false) : null,
      onTapCancel: enabled ? () => _set(false) : null,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              _set(false);
              widget.onLongPress!();
            },
      child: Semantics(
        button: true,
        enabled: enabled,
        selected: widget.selected,
        checked: widget.checked,
        label: widget.semanticLabel,
        excludeSemantics:
            widget.excludeSemantics && widget.semanticLabel != null,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            widget.child,
            if (_down)
              Positioned.fill(child: ColoredBox(color: widget.highlight)),
          ],
        ),
      ),
    );
  }
}
