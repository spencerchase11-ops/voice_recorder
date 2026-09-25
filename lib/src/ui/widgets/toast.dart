import 'dart:async';

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

OverlayEntry? _toast;
Timer? _toastTimer;

/// An Android-style toast; [long] keeps it up longer, for longer messages.
/// A newer one replaces it.
void showToast(BuildContext context, String message, {bool long = false}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _removeToast();
  final entry = OverlayEntry(
    builder: (ctx) => Positioned(
      left: 24,
      right: 24,
      // Above the undo toast, when both show.
      bottom: _toastBottom(ctx, _actionToast == null ? 88 : 144),
      child: IgnorePointer(
        child: Center(
          child: PlainText(
            child: Semantics(
              liveRegion: true,
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
  );
  overlay.insert(entry);
  _toast = entry;
  _toastTimer = Timer(Duration(milliseconds: long ? 3500 : 2000), _removeToast);
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

/// A toast with a button, e.g. "Moved to Recently deleted   UNDO". It stays
/// for [duration] or until the button is pressed; a newer one replaces it.
void showActionToast(
  BuildContext context,
  String message, {
  required String action,
  required VoidCallback onAction,
  Duration duration = const Duration(seconds: 6),
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  hideActionToast();
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
      child: Center(
        child: PlainText(
          child: Container(
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
  );
  overlay.insert(entry);
  _actionToast = entry;
  _hideAction = remove;
  _actionTimer = Timer(duration, remove);
  _announce(context, message);
}

/// Removes the showing action toast.
VoidCallback? _hideAction;

/// Removes the action toast, if one is showing.
void hideActionToast() {
  final hide = _hideAction;
  _hideAction = null;
  hide?.call();
}
