// Where the screens meet the system bars: the original's black status bar
// everywhere, its light navigation bar on Android, and on iPhone the bottom
// bar going on under the home indicator.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_recorder/src/ui/screens/settings_screen.dart';
import 'package:voice_recorder/src/ui/spec.dart';
import 'package:voice_recorder/src/ui/widgets/frame.dart';
import 'package:voice_recorder/src/ui/widgets/red_bars.dart';

import '../support/harness.dart';

const _statusBar = 62.0;
const _homeIndicator = 34.0;

/// An iPhone with a Dynamic Island (iPhone 18 Pro Max): 440 x 956 pt.
void useIPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1320, 2868);
  tester.view.devicePixelRatio = 3;
  const padding = FakeViewPadding(
    top: _statusBar * 3,
    bottom: _homeIndicator * 3,
  );
  tester.view.padding = padding;
  tester.view.viewPadding = padding;
  addTearDown(tester.view.reset);
}

Future<void> openSettings(WidgetTester tester) async {
  tester
      .state<NavigatorState>(find.byType(Navigator))
      .push(
        PageRouteBuilder<void>(
          pageBuilder: (_, _, _) => const SettingsScreen(),
        ),
      );
  await tester.pumpAndSettle();
}

void main() {
  final iPhone = TargetPlatformVariant.only(TargetPlatform.iOS);

  testWidgets('on iPhone the bottom bar reaches the screen edge', (
    tester,
  ) async {
    useIPhone(tester);
    await pumpReferenceApp(tester);
    final screen = tester.getRect(find.byType(WidgetsApp));

    // The header stays under the black status bar, as in the original.
    final header = tester.getRect(find.byType(RedHeader));
    expect(header.top, moreOrLessEquals(_statusBar));
    expect(header.height, moreOrLessEquals(Spec.headerHeight));

    final footer = tester.getRect(find.byType(RedFooter));
    expect(footer.bottom, moreOrLessEquals(screen.bottom));
    expect(footer.height, moreOrLessEquals(Spec.tabBarHeight + _homeIndicator));
    // The tabs keep their height, above the home indicator.
    final tab = tester.getRect(find.text('Recording list'));
    expect(tab.bottom, lessThan(screen.bottom - _homeIndicator));
    expect(tab.top, greaterThan(footer.top));
  }, variant: iPhone);

  testWidgets('on iPhone the settings page goes under the home indicator', (
    tester,
  ) async {
    useIPhone(tester);
    await pumpReferenceApp(tester);
    await openSettings(tester);
    final screen = tester.getRect(find.byType(WidgetsApp));

    expect(
      tester.getRect(find.byType(RedHeader)).top,
      moreOrLessEquals(_statusBar),
    );
    expect(
      tester.getRect(find.byType(BrushedMetal)).bottom,
      moreOrLessEquals(screen.bottom),
    );
    // Its list can scroll the last row clear of the home indicator.
    expect(
      tester.widget<ListView>(find.byType(ListView)).padding,
      const EdgeInsets.only(bottom: _homeIndicator),
    );
  }, variant: iPhone);

  testWidgets('on Android the system bars look like the original', (
    tester,
  ) async {
    useReferenceDevice(tester);
    await pumpReferenceApp(tester);
    const statusBar = 150 / 3.5, navigationBar = 56 / 3.5;
    final screen = tester.getRect(find.byType(WidgetsApp));

    final header = tester.getRect(find.byType(RedHeader));
    expect(header.top, moreOrLessEquals(statusBar));
    expect(header.height, moreOrLessEquals(Spec.headerHeight));
    final footer = tester.getRect(find.byType(RedFooter));
    expect(footer.bottom, moreOrLessEquals(screen.bottom - navigationBar));
    expect(footer.height, moreOrLessEquals(Spec.tabBarHeight));

    await openSettings(tester);
    expect(
      tester.getRect(find.byType(BrushedMetal)).bottom,
      moreOrLessEquals(screen.bottom - navigationBar),
    );
    expect(
      tester.widget<ListView>(find.byType(ListView)).padding,
      EdgeInsets.zero,
    );
  });
}
