import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../spec.dart';
import 'frame.dart';

/// Distance of a toast's bottom edge from the screen's: above the action
/// bar, or just above the keyboard while it is up.
double _toastBottom(BuildContext context, double aboveBar) {
  final keyboard = MediaQuery.viewInsetsOf(context).bottom;
  return keyboard > 0
      ? keyboard + 16
      : MediaQuery.viewPaddingOf(context).bottom + aboveBar;
}

/// Reads [message] out with a screen reader (iOS; on Android the toast is a
/// live region, which TalkBack reads when it appears).
void _announce(BuildContext context, String message) {
  if (!MediaQuery.supportsAnnounceOf(context)) return;
  unawaited(
    SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      TextDirection.ltr,
    ),
  );
}

/// The app's top overlay, also from the root navigator's own context (a
/// toast after the screen that asked for it has closed).
OverlayState? _overlay(BuildContext context) =>
    Overlay.maybeOf(context, rootOverlay: true) ??
    Navigator.maybeOf(context, rootNavigator: true)?.overlay;

OverlayEntry? _toast;
Timer? _toastTimer;

/// How long a toast stays: Android's short or long toast, and longer for a
/// long message (time to read it).
Duration toastDuration(String message, {bool long = false}) {
  final reading = 1000 + 50 * message.length;
  return Duration(
    milliseconds: math.max(long ? 3500 : 2000, math.min(reading, 7000)),
  );
}

/// An Android-style toast; [long] keeps it up longer, for longer messages.
/// A newer one replaces it.
void showToast(BuildContext context, String message, {bool long = false}) {
  final overlay = _overlay(context);
  if (overlay == null) return;
  _removeToast();
  final entry = OverlayEntry(
    builder: (ctx) => Positioned(
      left: 24,
      right: 24,
      // Above the undo toast, when both show.
      bottom: _toastBottom(ctx, _actionToast == null ? 88 : _aboveAction()),
      // At most 2x, as the dialogs: larger, its words split on a narrow
      // phone.
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 2,
        child: IgnorePointer(
          child: Center(
            child: PlainText(
              child: Semantics(
                // Announced where the platform can (iOS); read out as it
                // shows where it can't (Android). Both: VoiceOver says it
                // twice.
                liveRegion: !MediaQuery.supportsAnnounceOf(ctx),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xE6333333),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: Spec.font,
                      fontSize: 14,
                      color: Color(0xFFFFFFFF),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  _toast = entry;
  _toastTimer = Timer(toastDuration(message, long: long), _removeToast);
  _announce(context, message);
}

void _removeToast() {
  final e = _toast;
  _toast = null;
  _toastTimer?.cancel();
  _toastTimer = null;
  e
    ?..remove()
    ..dispose();
}

OverlayEntry? _actionToast;
Timer? _actionTimer;

/// The showing action toast's box, to stack a plain toast above it.
GlobalKey? _actionBox;

/// A plain toast's distance above the bottom while the action toast
/// shows: 20 above its top (144 for a one-line one; at large text it
/// wraps, taller).
double _aboveAction() {
  final box = _actionBox?.currentContext?.findRenderObject();
  final height = box is RenderBox && box.hasSize ? box.size.height : 44.0;
  return 80 + height + 20;
}

/// A toast with a button, e.g. "Moved to Recently deleted   UNDO". It stays
/// for [duration] or until the button is pressed; a newer one replaces it.
void showActionToast(
  BuildContext context,
  String message, {
  required String action,
  required VoidCallback onAction,
  Duration duration = const Duration(seconds: 6),
}) {
  final overlay = _overlay(context);
  if (overlay == null) return;
  hideActionToast();
  // With a screen reader on, finding the button takes longer than
  // [duration]: it stays until used or replaced, as Flutter's snack bars
  // do, and it is said that the button is there.
  final reader = MediaQuery.accessibleNavigationOf(context);
  final spoken = reader ? '$message. $action available' : message;
  final box = _actionBox = GlobalKey();
  late OverlayEntry entry;
  var removed = false;
  void remove() {
    if (removed) return;
    removed = true;
    if (_actionToast == entry) {
      _actionToast = null;
      _hideAction = null;
      _actionTimer?.cancel();
      _actionTimer = null;
    }
    entry
      ..remove()
      ..dispose();
  }

  entry = OverlayEntry(
    builder: (ctx) => Positioned(
      left: 16,
      right: 16,
      bottom: _toastBottom(ctx, 80),
      // At most 2x, as the dialogs: larger, its words split on a narrow
      // phone.
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 2,
        child: Center(
          child: PlainText(
            child: Container(
              key: box,
              constraints: const BoxConstraints(maxWidth: 480),
              padding: const EdgeInsets.only(left: 16),
              decoration: BoxDecoration(
                color: const Color(0xF2333333),
                borderRadius: BorderRadius.circular(4),
                boxShadow: const [
                  BoxShadow(color: Color(0x66000000), blurRadius: 4),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Semantics(
                        // As the plain toast's.
                        liveRegion: !MediaQuery.supportsAnnounceOf(ctx),
                        label: spoken,
                        excludeSemantics: true,
                        child: Text(
                          message,
                          style: const TextStyle(
                            fontFamily: Spec.font,
                            fontSize: 14,
                            color: Color(0xFFFFFFFF),
                          ),
                        ),
                      ),
                    ),
                  ),
                  PressableArea(
                    semanticLabel: action,
                    highlight: const Color(0x33FFFFFF),
                    onTap: () {
                      remove();
                      onAction();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      child: Text(
                        action.toUpperCase(),
                        style: const TextStyle(
                          fontFamily: Spec.font,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Spec.holoBlue,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  _actionToast = entry;
  _hideAction = remove;
  // A plain toast showing already moves above it, once its height is
  // known.
  WidgetsBinding.instance.addPostFrameCallback((_) => _toast?.markNeedsBuild());
  if (!reader) _actionTimer = Timer(duration, remove);
  _announce(context, spoken);
}

/// Removes the showing action toast.
VoidCallback? _hideAction;

/// Removes the action toast, if one is showing.
void hideActionToast() {
  final hide = _hideAction;
  _hideAction = null;
  hide?.call();
}
