import 'dart:math' as math;

import 'package:flutter/material.dart'
    show Material, MaterialType, TextField, InputDecoration, InputBorder;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../spec.dart';
import '../widgets/frame.dart';

/// Shows [builder] centred over a 60% black scrim, like an Android dialog.
Future<T?> showSpecDialog<T>(
  BuildContext context,
  WidgetBuilder builder, {
  bool dismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: 'Dismiss',
    barrierColor: Spec.dialogScrim,
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (ctx, _, _) =>
        PlainText(child: ScreenFrameInsets(child: builder(ctx))),
    transitionBuilder: (ctx, anim, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
      child: child,
    ),
  );
}

/// Centres a dialog in the area between the system bars (and above the
/// keyboard).
class ScreenFrameInsets extends StatelessWidget {
  const ScreenFrameInsets({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final bottom = math.max(mq.viewPadding.bottom, mq.viewInsets.bottom);
    return Padding(
      padding: EdgeInsets.only(top: mq.viewPadding.top, bottom: bottom),
      child: Center(child: child),
    );
  }
}

// ======================================================================
// Holo Light alert dialog (delete confirmation, pickers, messages)
// ======================================================================

class HoloDialog extends StatelessWidget {
  const HoloDialog({
    super.key,
    required this.title,
    this.icon,
    this.message,
    this.body,
    this.buttons = const [],
  });

  final String title;
  final Widget? icon;
  final String? message;

  /// Custom content (e.g. a single-choice list) instead of [message].
  final Widget? body;
  final List<HoloButton> buttons;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width - 2 * Spec.holoInset;
    return Container(
      width: math.min(width, 520),
      decoration: BoxDecoration(
        color: Spec.holoBackground,
        borderRadius: BorderRadius.circular(Spec.holoRadius),
        border: Border.all(color: Spec.holoEdge, width: 0.3),
        boxShadow: const [
          BoxShadow(color: Color(0x66000000), blurRadius: 3, spreadRadius: 0.5),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: Spec.holoTitleHeight,
            child: Stack(
              children: [
                if (icon != null)
                  Positioned(
                    left: Spec.holoIconLeft,
                    top: 0,
                    bottom: Spec.holoIconRaise,
                    child: Center(
                      child: SizedBox.fromSize(
                        size: Spec.holoIconSize,
                        child: icon,
                      ),
                    ),
                  ),
                Positioned(
                  left: icon != null ? Spec.holoTitleLeft : 16.3,
                  right: 16,
                  top: 0,
                  bottom: 0,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: AText(
                      title,
                      style: Spec.holoTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(height: Spec.holoTitleRule, color: Spec.holoBlue),
          if (body != null)
            Flexible(child: body!)
          else if (message != null)
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  Spec.holoMessageInset,
                  Spec.holoMessagePaddingTop,
                  Spec.holoMessageInset,
                  Spec.holoMessagePaddingBottom,
                ),
                child: AText(message!, style: Spec.holoMessage),
              ),
            ),
          if (buttons.isNotEmpty) ...[
            Container(height: Spec.holoDividerWidth, color: Spec.holoDivider),
            SizedBox(
              height: Spec.holoButtonBarHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < buttons.length; i++) ...[
                    if (i > 0)
                      Container(
                        width: Spec.holoDividerWidth,
                        color: Spec.holoDivider,
                      ),
                    Expanded(child: buttons[i]),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class HoloButton extends StatelessWidget {
  const HoloButton(this.label, {super.key, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableArea(
      onTap: onTap,
      semanticLabel: label,
      child: Center(child: AText(label, style: Spec.holoButton, maxLines: 1)),
    );
  }
}

/// The light-grey warning triangle Holo Light shows in alert dialogs.
class HoloWarningIcon extends StatelessWidget {
  const HoloWarningIcon({super.key});

  @override
  Widget build(BuildContext context) =>
      const CustomPaint(painter: _WarningPainter());
}

class _WarningPainter extends CustomPainter {
  const _WarningPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    const rr = 3.2;
    final tri = Path()
      ..moveTo(w / 2 - rr * 0.7, rr * 0.55)
      ..quadraticBezierTo(w / 2, -rr * 0.35, w / 2 + rr * 0.7, rr * 0.55)
      ..lineTo(w - rr * 0.35, h - rr * 1.1)
      ..quadraticBezierTo(w + rr * 0.2, h, w - rr * 1.2, h)
      ..lineTo(rr * 1.2, h)
      ..quadraticBezierTo(-rr * 0.2, h, rr * 0.35, h - rr * 1.1)
      ..close();
    // soft bottom shadow
    canvas.drawPath(
      tri.shift(const Offset(0, 0.9)),
      Paint()
        ..color = const Color(0x33000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.8),
    );
    canvas.drawPath(
      tri,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFAFAFA), Color(0xFFEDEDED), Color(0xFFDDDDDD)],
          stops: [0, 0.6, 1],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      tri,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..color = const Color(0x22000000),
    );
    // embossed exclamation mark
    final bar = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(w / 2, h * 0.47),
        width: w * 0.085,
        height: h * 0.36,
      ),
      Radius.circular(w * 0.045),
    );
    final dot = Rect.fromCircle(
      center: Offset(w / 2, h * 0.79),
      radius: w * 0.058,
    );
    final emboss = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = const Color(0x2E000000);
    final fill = Paint()..color = const Color(0xFFF6F6F6);
    canvas
      ..drawRRect(bar.shift(const Offset(0, 0.5)), emboss)
      ..drawOval(dot.shift(const Offset(0, 0.5)), emboss)
      ..drawRRect(bar, fill)
      ..drawOval(dot, fill);
  }

  @override
  bool shouldRepaint(_WarningPainter oldDelegate) => false;
}

/// "Are you sure to delete file? /name.mp3" - returns true on OK. With
/// several files ([count]), asks about all of them instead.
Future<bool> showDeleteDialog(
  BuildContext context,
  String fileName, {
  int count = 1,
}) async {
  final ok = await showSpecDialog<bool>(
    context,
    (ctx) => HoloDialog(
      title: count == 1 ? 'Delete file' : 'Delete files',
      icon: const HoloWarningIcon(),
      message: count == 1
          ? 'Are you sure to delete file? /$fileName'
          : 'Are you sure to delete $count files?',
      buttons: [
        HoloButton('Cancel', onTap: () => Navigator.of(ctx).pop(false)),
        HoloButton('OK', onTap: () => Navigator.of(ctx).pop(true)),
      ],
    ),
  );
  return ok ?? false;
}

/// A Holo question with Cancel and OK buttons; true on OK.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String ok = 'OK',
}) async {
  final answer = await showSpecDialog<bool>(
    context,
    (ctx) => HoloDialog(
      title: title,
      icon: const HoloWarningIcon(),
      message: message,
      buttons: [
        HoloButton('Cancel', onTap: () => Navigator.of(ctx).pop(false)),
        HoloButton(ok, onTap: () => Navigator.of(ctx).pop(true)),
      ],
    ),
  );
  return answer ?? false;
}

/// A Holo message with a single OK button.
Future<void> showMessageDialog(
  BuildContext context, {
  required String title,
  required String message,
}) {
  return showSpecDialog<void>(
    context,
    (ctx) => HoloDialog(
      title: title,
      message: message,
      buttons: [HoloButton('OK', onTap: () => Navigator.of(ctx).pop())],
    ),
  );
}

/// Holo single-choice list; returns the chosen index.
Future<int?> showChoiceDialog(
  BuildContext context, {
  required String title,
  required List<String> items,
  required int selected,
}) {
  return showSpecDialog<int>(
    context,
    (ctx) => HoloDialog(
      title: title,
      body: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0)
                Container(
                  height: Spec.holoDividerWidth,
                  color: Spec.holoDivider,
                ),
              PressableArea(
                onTap: () => Navigator.of(ctx).pop(i),
                semanticLabel: items[i],
                child: SizedBox(
                  height: 48,
                  child: Row(
                    children: [
                      const SizedBox(width: Spec.holoMessageInset),
                      Expanded(
                        child: AText(
                          items[i],
                          style: Spec.holoMessage,
                          maxLines: 1,
                        ),
                      ),
                      _HoloRadio(checked: i == selected),
                      const SizedBox(width: 12),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      buttons: [HoloButton('Cancel', onTap: () => Navigator.of(ctx).pop())],
    ),
  );
}

class _HoloRadio extends StatelessWidget {
  const _HoloRadio({required this.checked});

  final bool checked;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 32,
    child: CustomPaint(painter: _RadioPainter(checked)),
  );
}

class _RadioPainter extends CustomPainter {
  _RadioPainter(this.checked);

  final bool checked;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    canvas.drawCircle(
      c,
      8.2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = const Color(0xFF9E9E9E),
    );
    if (checked) canvas.drawCircle(c, 4.6, Paint()..color = Spec.holoBlue);
  }

  @override
  bool shouldRepaint(_RadioPainter old) => old.checked != checked;
}

// ======================================================================
// iOS-style rename dialog
// ======================================================================

/// "Enter new file name" - returns the new base name (without extension).
Future<String?> showRenameDialog(BuildContext context, String currentBaseName) {
  return showSpecDialog<String>(
    context,
    (ctx) => _RenameDialog(initial: currentBaseName),
  );
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_text.text);

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width - 2 * Spec.renameInset;
    final fieldText = MediaQuery.textScalerOf(context)
        .scale(Spec.renameField.fontSize!);
    return Container(
      width: math.min(width, 480),
      decoration: BoxDecoration(
        color: Spec.renameBackground,
        borderRadius: BorderRadius.circular(Spec.renameRadius),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: Spec.renameTitleTop),
          const AText(
            'Enter new file name',
            style: Spec.renameTitle,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: Spec.renameFieldGap),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spec.renameFieldInset,
            ),
            child: Container(
              height: math.max(Spec.renameFieldHeight, fieldText * 1.6),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFFFF),
                border: Border.all(color: Spec.renameFieldBorder, width: 0.6),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: Spec.renameFieldPadding,
              ),
              alignment: Alignment.centerLeft,
              child: Material(
                type: MaterialType.transparency,
                child: TextField(
                  controller: _text,
                  // The original opened without the keyboard; tap to edit.
                  autofocus: false,
                  style: Spec.renameField,
                  cursorColor: const Color(0xFF007AFF),
                  cursorWidth: 1.5,
                  maxLines: 1,
                  textInputAction: TextInputAction.done,
                  inputFormatters: [
                    FilteringTextInputFormatter.deny(RegExp(r'[\\/:*?"<>|]')),
                  ],
                  onSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: Spec.renameRuleGap),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spec.renameFieldInset,
            ),
            child: Container(height: 0.3, color: Spec.renameRule),
          ),
          SizedBox(
            height: Spec.renameButtonHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spec.renameFieldInset,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _IosButton(
                      'Cancel',
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ),
                  Container(width: 0.3, color: Spec.renameRule),
                  Expanded(child: _IosButton('OK', onTap: _submit)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IosButton extends StatelessWidget {
  const _IosButton(this.label, {required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => PressableArea(
    onTap: onTap,
    semanticLabel: label,
    highlight: const Color(0x14000000),
    child: Center(child: AText(label, style: Spec.renameButton, maxLines: 1)),
  );
}
