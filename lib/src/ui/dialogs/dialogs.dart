import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart'
    show Material, MaterialType, TextField, InputDecoration, InputBorder;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../core/format.dart';
import '../spec.dart';
import '../widgets/frame.dart';
import '../widgets/toast.dart';

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
    transitionBuilder: _fade,
  );
}

Widget _fade(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondary,
  Widget child,
) => FadeTransition(
  opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
  child: child,
);

/// A Holo message with an OK button.
Future<void> showMessageDialog(
  BuildContext context, {
  required String title,
  required String message,
}) => showSpecDialog<void>(
  context,
  (ctx) => HoloDialog(
    title: title,
    message: message,
    buttons: [HoloButton('OK', onTap: () => Navigator.of(ctx).pop())],
  ),
);

/// How far a long job has got: [done] of [total] (a total of 0 while the
/// job is still finding out).
typedef JobState = ({int done, int total});

/// A Holo dialog following a long job, which only the job's end closes.
/// [label] says what is happening, from [state]. With [onCancel], a Cancel
/// button asks the job to stop (it says "Stopping…" until it has).
class ProgressDialogRoute extends RawDialogRoute<void> {
  ProgressDialogRoute({
    required String title,
    required ValueListenable<JobState> state,
    required String Function(JobState state) label,
    VoidCallback? onCancel,
  }) : this._(title, state, label, onCancel, ValueNotifier(false));

  ProgressDialogRoute._(
    String title,
    ValueListenable<JobState> state,
    String Function(JobState state) label,
    VoidCallback? onCancel,
    ValueNotifier<bool> stopping,
  ) : super(
        barrierDismissible: false,
        barrierColor: Spec.dialogScrim,
        transitionDuration: const Duration(milliseconds: 150),
        transitionBuilder: _fade,
        pageBuilder: (ctx, _, _) => PopScope(
          canPop: false,
          child: PlainText(
            child: ScreenFrameInsets(
              child: ListenableBuilder(
                listenable: Listenable.merge([state, stopping]),
                builder: (ctx, _) {
                  final s = state.value;
                  return HoloDialog(
                    title: title,
                    body: _ProgressBody(
                      label: stopping.value ? 'Stopping…' : label(s),
                      value: s.total == 0 ? 0 : s.done / s.total,
                    ),
                    buttons: [
                      if (onCancel != null && !stopping.value)
                        HoloButton(
                          'Cancel',
                          onTap: () {
                            stopping.value = true;
                            onCancel();
                          },
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );

  @override
  TickerFuture didPush() {
    // An Undo toast stays above dialogs: tapping it now would start a
    // second job alongside this one.
    hideActionToast();
    return super.didPush();
  }
}

class _ProgressBody extends StatelessWidget {
  const _ProgressBody({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spec.holoMessageInset,
        Spec.holoMessagePaddingTop + 4,
        Spec.holoMessageInset,
        Spec.holoMessagePaddingBottom + 8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            liveRegion: true,
            child: AText(label, style: Spec.holoMessage),
          ),
          const SizedBox(height: 14),
          // Holo Light's horizontal progress bar.
          Container(
            height: 4,
            color: const Color(0xFFD5D5D5),
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: value.clamp(0.0, 1.0),
              child: Container(color: Spec.holoBlue),
            ),
          ),
        ],
      ),
    );
  }
}

/// Carries out a job on many recordings behind a [ProgressDialogRoute]
/// (only when there are more than [quietUpTo]; short jobs just run). The
/// job reports its progress, and checks whether the user cancelled.
Future<T> runWithProgress<T>(
  BuildContext context, {
  required String title,
  required int total,
  required String Function(JobState state) label,
  required Future<T> Function(
    void Function(int done, int total) onProgress,
    bool Function() cancelled,
  )
  job,
  bool cancellable = true,
  int quietUpTo = 20,
}) async {
  var stop = false;
  if (total <= quietUpTo) return job((_, _) {}, () => stop);
  final navigator = Navigator.of(context, rootNavigator: true);
  final state = ValueNotifier<JobState>((done: 0, total: total));
  final route = ProgressDialogRoute(
    title: title,
    state: state,
    label: label,
    onCancel: cancellable ? () => stop = true : null,
  );
  unawaited(navigator.push(route));
  try {
    return await job(
      (done, total) => state.value = (done: done, total: total),
      () => stop,
    );
  } finally {
    if (route.isActive) navigator.removeRoute(route);
    WidgetsBinding.instance.addPostFrameCallback((_) => state.dispose());
  }
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
          : 'Are you sure to delete ${formatCount(count)} files?',
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

  /// OK needs a name: one that is empty once cleaned up would be refused.
  bool get _hasName => sanitizeFileName(_text.text).isNotEmpty;

  void _submit() {
    if (_hasName) Navigator.of(context).pop(_text.text);
  }

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
                    // File names are limited (the folder cuts longer ones);
                    // a longer name made elsewhere isn't cut by editing it.
                    LengthLimitingTextInputFormatter(
                      math.max(maxNameLength, widget.initial.length),
                    ),
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
                  Expanded(
                    child: ListenableBuilder(
                      listenable: _text,
                      builder: (context, _) =>
                          _IosButton('OK', onTap: _hasName ? _submit : null),
                    ),
                  ),
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

  /// Null greys the button out.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => PressableArea(
    onTap: onTap,
    semanticLabel: label,
    highlight: const Color(0x14000000),
    child: Center(
      child: Opacity(
        opacity: onTap == null ? 0.35 : 1,
        child: AText(label, style: Spec.renameButton, maxLines: 1),
      ),
    ),
  );
}
