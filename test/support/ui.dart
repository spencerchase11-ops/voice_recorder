// Helpers for tests that drive the screens.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_recorder/src/ui/widgets/frame.dart';
import 'package:voice_recorder/src/ui/widgets/recorder_widgets.dart';

/// Records the methods called on the app's native channel.
List<String> mockNativeChannel() {
  final calls = <String>[];
  const channel = MethodChannel('com.spencerchase.voicerecorder/native');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    // Asked on every start and return to the app (home-screen shortcut).
    if (call.method != 'takeLaunchAction') calls.add(call.method);
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  return calls;
}

/// Lets the undo toast of a delete run out.
Future<void> waitOutUndo(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 7));
  await tester.pumpAndSettle();
}

/// A button by its accessibility label.
Finder labeled(String label) => find.byWidgetPredicate(
  (w) =>
      (w is PressableArea && w.semanticLabel == label) ||
      (w is GlossyButton && w.semanticLabel == label),
);

bool enabled(WidgetTester tester, String label) {
  final w = tester.widget(labeled(label));
  return w is PressableArea
      ? w.onTap != null
      : (w as GlossyButton).onTap != null;
}

/// Lets real file I/O started by the app finish, pumping frames in between.
Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(done(), isTrue, reason: 'condition not reached');
  await tester.pump();
}
