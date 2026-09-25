import 'dart:async';

import 'package:flutter/widgets.dart';

import '../spec.dart';
import 'frame.dart';

/// An Android-style toast; [long] keeps it up longer, for longer messages.
void showToast(BuildContext context, String message, {bool long = false}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => Positioned(
      left: 24,
      right: 24,
      bottom: MediaQuery.viewPaddingOf(ctx).bottom + 88,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
  );
  overlay.insert(entry);
  Timer(Duration(milliseconds: long ? 3500 : 2000), entry.remove);
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
  void remove() {
    if (_actionToast == entry) {
      _actionToast = null;
      _actionTimer?.cancel();
      _actionTimer = null;
    }
    if (entry.mounted) entry.remove();
  }

  entry = OverlayEntry(
    builder: (ctx) => Positioned(
      left: 16,
      right: 16,
      bottom: MediaQuery.viewPaddingOf(ctx).bottom + 80,
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
  _actionToast = entry;
  overlay.insert(entry);
  _actionTimer = Timer(duration, remove);
}

/// Removes the action toast, if one is showing.
void hideActionToast() {
  final e = _actionToast;
  _actionToast = null;
  _actionTimer?.cancel();
  _actionTimer = null;
  if (e != null && e.mounted) e.remove();
}
