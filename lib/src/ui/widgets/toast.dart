import 'dart:async';

import 'package:flutter/widgets.dart';

import '../spec.dart';

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
