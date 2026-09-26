// Leaving Settings: an iPhone has no Back button, so its header has an "up"
// button; Android keeps the original header and uses the system Back button.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_recorder/src/ui/icons/app_icons.dart';
import 'package:voice_recorder/src/ui/screens/recorder_screen.dart';
import 'package:voice_recorder/src/ui/screens/settings_screen.dart';
import 'package:voice_recorder/src/ui/widgets/red_bars.dart';

import '../support/harness.dart';
import '../support/ui.dart';

Future<void> openSettings(WidgetTester tester) async {
  await tester.tap(labeled('Settings'));
  await tester.pumpAndSettle();
  expect(find.byType(SettingsScreen), findsOneWidget);
}

void main() {
  testWidgets('on iPhone the Settings header goes back to the recorder', (
    tester,
  ) async {
    useReferenceDevice(tester);
    await pumpReferenceApp(tester);
    await openSettings(tester);

    // The caret and the app icon make one button at the header's left end.
    final up = tester.getRect(labeled('Back'));
    expect(up.left, 0);
    expect(up.width, greaterThanOrEqualTo(48));
    final caret = backArrowInHeader(tester);
    final icon = tester.getRect(
      find.descendant(of: labeled('Back'), matching: find.byType(Image)),
    );
    expect(icon.left, greaterThan(caret.right));
    expect(icon.right, lessThanOrEqualTo(up.right));

    await tester.tap(labeled('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.byType(RecorderScreen), findsOneWidget);

    // The caret is the same back arrow, in the same place, as the list's.
    await tester.tap(labeled('Recording list'));
    await tester.pumpAndSettle();
    expect(backArrowInHeader(tester), rectMoreOrLessEquals(caret));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('on Android the Settings header keeps the original icon', (
    tester,
  ) async {
    useReferenceDevice(tester);
    await pumpReferenceApp(tester);
    await openSettings(tester);
    expect(labeled('Back'), findsNothing);
    final header = tester.getRect(find.byType(RedHeader));
    final icon = tester.getRect(
      find.descendant(of: find.byType(RedHeader), matching: find.byType(Image)),
    );
    expect(
      icon,
      rectMoreOrLessEquals(Rect.fromLTWH(10.9, header.top + 6.6, 34.3, 34.3)),
    );
  });
}

/// The visible header's back arrow, relative to the header.
Rect backArrowInHeader(WidgetTester tester) {
  final header = tester.getRect(find.byType(RedHeader));
  final arrow = tester.getRect(
    find.descendant(of: labeled('Back'), matching: find.byType(InkIcon)),
  );
  return arrow.shift(-header.topLeft);
}
