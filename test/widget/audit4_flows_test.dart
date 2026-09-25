// The screens after the fourth audit: long jobs with progress, the list's
// empty states, Recently deleted's buttons, and the rename dialog.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_recorder/src/core/recording_file.dart';
import 'package:voice_recorder/src/ui/widgets/frame.dart';

import '../support/harness.dart';
import '../support/ui.dart';

/// [n] recordings with timestamp names, a minute apart.
List<RecordingFile> _many(int n) => [
  for (var i = 0; i < n; i++)
    RecordingFile(
      id: 'mem://2026_09_01_10_${i.toString().padLeft(2, '0')}_00.mp3',
      name: '2026_09_01_10_${i.toString().padLeft(2, '0')}_00.mp3',
      size: 1000,
      modified: DateTime(2026, 9, 1, 10, i),
    ),
];

Future<TestApp> _openList(
  WidgetTester tester, {
  List<RecordingFile>? files,
}) async {
  useReferenceDevice(tester);
  final t = await pumpReferenceApp(tester, files: files, current: null);
  await tester.tap(labeled('Recording list'));
  await tester.pumpAndSettle();
  return t;
}

void main() {
  testWidgets('deleting many shows how far it has got, and undo too', (
    tester,
  ) async {
    final t = await _openList(tester, files: _many(30));
    await tester.longPress(find.text('2026_09_01_10_29_00.mp3'));
    await tester.pumpAndSettle();
    await tester.tap(labeled('Select all'));
    await tester.pumpAndSettle();
    expect(find.text('30 selected'), findsOneWidget);
    await tester.tap(labeled('Delete'));
    await tester.pumpAndSettle();
    t.store.slow = Completer<void>();
    await tester.tap(find.text('OK'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Deleting'), findsOneWidget);
    expect(
      find.text('Moving 0 of 30 recordings to Recently deleted…'),
      findsOneWidget,
    );
    t.store.slow!.complete();
    t.store.slow = null;
    await tester.pumpAndSettle();
    expect(find.text('Deleting'), findsNothing);
    expect(t.controller.files, isEmpty);
    expect(
      find.text('30 recordings moved to Recently deleted'),
      findsOneWidget,
    );

    await tester.tap(labeled('Undo'));
    await tester.pumpAndSettle();
    expect(t.controller.files, hasLength(30));
  });

  testWidgets('a long job can be cancelled', (tester) async {
    final t = await _openList(tester, files: _many(30));
    await tester.longPress(find.text('2026_09_01_10_29_00.mp3'));
    await tester.pumpAndSettle();
    await tester.tap(labeled('Select all'));
    await tester.pumpAndSettle();
    await tester.tap(labeled('Delete'));
    await tester.pumpAndSettle();
    t.store.slow = Completer<void>();
    await tester.tap(find.text('OK'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(labeled('Cancel').last);
    await tester.pump();
    t.store.slow!.complete();
    t.store.slow = null;
    await tester.pumpAndSettle();
    // The one under way finished; the rest stayed.
    expect(t.controller.files, hasLength(29));
    await waitOutUndo(tester);
  });

  group('an empty list says why', () {
    testWidgets('a folder that can no longer be reached', (tester) async {
      useReferenceDevice(tester);
      final t = await pumpReferenceApp(tester, current: null);
      t.store.ready = false;
      await tester.tap(labeled('Recording list'));
      await tester.pumpAndSettle();
      // Asked for right away; cancelled here.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          "The recordings folder can't be reached.\n\nTap here to choose it "
          'again.',
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.textContaining("The recordings folder can't be reached."),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      // Choosing it also saves recordings kept in the app (real files).
      await pumpUntil(tester, () => t.controller.files.isNotEmpty);
      await tester.pumpAndSettle();
      expect(t.store.folderChoices, 1);
      expect(find.text('kris n evan got back then zach.mp3'), findsOneWidget);
    });

    testWidgets('a folder that fails to be read, then works', (tester) async {
      useReferenceDevice(tester);
      final t = await pumpReferenceApp(tester, files: [], current: null);
      t.store.failLists = true;
      await tester.tap(labeled('Recording list'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining("Can't open the recordings folder."),
        findsOneWidget,
      );
      t.store
        ..failLists = false
        ..files.addAll(_many(1));
      await tester.tap(
        find.textContaining("Can't open the recordings folder."),
      );
      await tester.pumpAndSettle();
      expect(find.text('2026_09_01_10_00_00.mp3'), findsOneWidget);
    });

    testWidgets('no recordings yet', (tester) async {
      await _openList(tester, files: []);
      expect(
        find.text(
          'No recordings in this folder yet:\n/storage/emulated/0/Recorders'
          '\n\nTo use another folder, choose it in Settings > Folder.',
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('Recently deleted: all at once, or the one selected', (
    tester,
  ) async {
    final t = await _openList(tester, files: _many(3));
    await tester.longPress(find.text('2026_09_01_10_00_00.mp3'));
    await tester.pumpAndSettle();
    await tester.tap(labeled('Select all'));
    await tester.pumpAndSettle();
    await tester.tap(labeled('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await waitOutUndo(tester);
    await tester.tap(labeled('Back'));
    await tester.pumpAndSettle();
    await tester.tap(labeled('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recently deleted'));
    await tester.pumpAndSettle();

    // Nothing selected: the buttons act on all of them.
    expect(labeled('Restore all'), findsOneWidget);
    expect(labeled('Delete all'), findsOneWidget);
    await tester.tap(find.text('2026_09_01_10_02_00.mp3'));
    await tester.pumpAndSettle();
    expect(labeled('Restore'), findsOneWidget);
    expect(labeled('Delete forever'), findsOneWidget);
    await tester.tap(labeled('Delete forever'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        '"2026_09_01_10_02_00.mp3" will be deleted forever. This can\'t be '
        'undone.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('2026_09_01_10_02_00.mp3'), findsNothing);

    await tester.tap(labeled('Restore all'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'All 2 recordings in Recently deleted will go back to the list.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Restore all').last);
    await tester.pumpAndSettle();
    expect(find.text('Restored 2 recordings'), findsOneWidget);
    expect(t.controller.files, hasLength(2));
    expect(find.textContaining('No recently deleted recordings.'), findsOne);
    // Nothing left to act on.
    expect(enabled(tester, 'Restore all'), isFalse);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('rename: OK needs a name', (tester) async {
    useReferenceDevice(tester);
    await pumpReferenceApp(tester);
    await tester.tap(labeled('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), '   ');
    await tester.pump();
    expect(enabled(tester, 'OK'), isFalse);
    await tester.enterText(find.byType(EditableText), 'team call');
    await tester.pump();
    expect(enabled(tester, 'OK'), isTrue);
    await tester.tap(labeled('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Enter new file name'), findsNothing);
    expect(find.textContaining('team call.mp3'), findsOneWidget);
    expect(find.byType(AText), findsWidgets);
  });
}
