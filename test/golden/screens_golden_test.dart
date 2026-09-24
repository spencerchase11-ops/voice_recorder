// Renders every screen in the state of the reference screenshots.
//
// Regenerate with:  flutter test --update-goldens test/golden
// Compare with the originals:  python3 tool/compare_goldens.py
@Tags(['golden'])
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_recorder/src/ui/dialogs/dialogs.dart';
import 'package:voice_recorder/src/ui/screens/recording_list_screen.dart';
import 'package:voice_recorder/src/ui/screens/settings_screen.dart';

import '../support/harness.dart';

void main() {
  testWidgets('recorder', (tester) async {
    useReferenceDevice(tester);
    await pumpReferenceApp(tester);
    await expectLater(
      find.byType(WidgetsApp),
      matchesGoldenFile('goldens/recorder.png'),
    );
  });

  testWidgets('delete dialog', (tester) async {
    useReferenceDevice(tester);
    await pumpReferenceApp(tester);
    final context = tester.element(find.text('Recorder').first);
    showDeleteDialog(context, 'kris n evan got back then zach.mp3');
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(WidgetsApp),
      matchesGoldenFile('goldens/delete_dialog.png'),
    );
  });

  testWidgets('rename dialog', (tester) async {
    useReferenceDevice(tester);
    await pumpReferenceApp(tester);
    final context = tester.element(find.text('Recorder').first);
    showRenameDialog(context, 'kris n evan got back then zach');
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(WidgetsApp),
      matchesGoldenFile('goldens/rename_dialog.png'),
    );
  });

  testWidgets('recording list', (tester) async {
    useReferenceDevice(tester);
    await pumpReferenceApp(tester);
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.push(
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => const RecordingListScreen(
          initialSelection: 'mem://kris n evan got back then zach.mp3',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(WidgetsApp),
      matchesGoldenFile('goldens/recording_list.png'),
    );
  });

  testWidgets('settings', (tester) async {
    useReferenceDevice(tester);
    await pumpReferenceApp(tester);
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.push(
      PageRouteBuilder<void>(pageBuilder: (_, _, _) => const SettingsScreen()),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(WidgetsApp),
      matchesGoldenFile('goldens/settings.png'),
    );
  });
}
