// The upgrades, driven through the screens like a user would.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_recorder/src/core/recording_file.dart';
import 'package:voice_recorder/src/core/settings.dart';
import 'package:voice_recorder/src/ui/widgets/frame.dart';

import '../support/fakes.dart';
import '../support/harness.dart';
import '../support/ui.dart';

const _kris = 'kris n evan got back then zach.mp3';

/// The names in the list, top to bottom.
List<String> _rows(WidgetTester tester) => [
  for (final e in find.byType(AText).evaluate())
    if ((e.widget as AText).text.endsWith('.mp3')) (e.widget as AText).text,
];

void main() {
  group('Recorder', () {
    testWidgets('a recording can be paused and resumed', (tester) async {
      useReferenceDevice(tester);
      final t = await pumpReferenceApp(tester);
      final app = t.controller;

      await tester.tap(labeled('Record'));
      await pumpUntil(tester, () => app.isRecording && !app.isBusy);
      await tester.tap(labeled('Pause recording'));
      await tester.pump();
      expect(app.isPaused, isTrue);
      expect(t.engine.pauses, 1);
      expect(labeled('Resume recording'), findsOneWidget);

      await tester.tap(labeled('Resume recording'));
      await tester.pump();
      expect(app.isPaused, isFalse);
      expect(t.engine.resumes, 1);

      await tester.tap(labeled('Stop recording'));
      await pumpUntil(tester, () => !app.isRecording && !app.isBusy);
      await tester.pumpAndSettle();
      expect(t.store.saved, hasLength(1));
      expect(labeled('Play'), findsOneWidget);
    });

    testWidgets('the home-screen shortcut starts a recording', (tester) async {
      String? action = 'record';
      const channel = MethodChannel('com.spencerchase.voicerecorder/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'takeLaunchAction') return null;
        final a = action;
        action = null;
        return a;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      useReferenceDevice(tester);
      final t = await pumpReferenceApp(tester);
      await pumpUntil(
        tester,
        () => t.controller.isRecording && !t.controller.isBusy,
      );
      expect(labeled('Stop recording'), findsOneWidget);
      await tester.tap(labeled('Stop recording'));
      await pumpUntil(tester, () => !t.controller.isBusy);
      await tester.pumpAndSettle();
    });
  });

  group('Recording list', () {
    Future<TestApp> openList(WidgetTester tester) async {
      useReferenceDevice(tester);
      final t = await pumpReferenceApp(tester);
      await tester.tap(labeled('Recording list'));
      await tester.pumpAndSettle();
      return t;
    }

    testWidgets('search finds recordings by name or date', (tester) async {
      await openList(tester);
      await tester.tap(labeled('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), 'KRIS');
      await tester.pumpAndSettle();
      expect(_rows(tester), [_kris, 'lunch w kris team convo .mp3']);

      await tester.enterText(find.byType(EditableText), '2026-09-18');
      await tester.pumpAndSettle();
      expect(_rows(tester), hasLength(4));

      await tester.enterText(find.byType(EditableText), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('No recordings match'), findsOneWidget);

      // Back leaves the search (not the list), with everything shown again.
      await tester.tap(labeled('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Recording list'), findsOneWidget);
      expect(_rows(tester), hasLength(10));
    });

    testWidgets('sort order', (tester) async {
      final t = await openList(tester);
      await tester.tap(labeled('Sort'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Oldest first'));
      await tester.pumpAndSettle();
      expect(t.controller.settings.sortOrder, SortOrder.oldest);
      expect(_rows(tester).first, '2026_09_16_15_48_15.mp3');
    });

    testWidgets('long press selects several to delete; undo brings them back', (
      tester,
    ) async {
      final t = await openList(tester);
      await tester.longPress(find.text('2026_09_20_17_26_27.mp3'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.text('2026_09_18_21_23_04.mp3'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);

      await tester.tap(labeled('Rename'));
      await tester.pump();
      expect(find.text('Select one file to rename'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));

      await tester.tap(labeled('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Are you sure to delete 2 files?'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Recording list'), findsOneWidget); // selection over
      expect(_rows(tester), hasLength(8));
      expect(
        find.text('2 recordings moved to Recently deleted'),
        findsOneWidget,
      );

      await tester.tap(labeled('Undo'));
      await tester.pumpAndSettle();
      expect(_rows(tester), hasLength(10));
      expect(await tester.runAsync(t.store.listTrash), isEmpty);
    });

    testWidgets('select all and share them together', (tester) async {
      final t = await openList(tester);
      await tester.longPress(find.text(_kris));
      await tester.pumpAndSettle();
      await tester.tap(labeled('Select all'));
      await tester.pumpAndSettle();
      expect(find.text('10 selected'), findsOneWidget);
      await tester.tap(labeled('Share'));
      await tester.pump();
      expect(t.store.shared, hasLength(10));
      // Back ends the selection first.
      await tester.tap(labeled('Cancel selection'));
      await tester.pumpAndSettle();
      expect(find.text('Recording list'), findsOneWidget);
    });

    testWidgets('the open row has skip and speed buttons', (tester) async {
      final t = await openList(tester);
      await tester.tap(find.text(_kris));
      await tester.pumpAndSettle();
      await tester.tap(labeled('Forward 10 seconds'));
      await tester.pumpAndSettle();
      expect(t.playback.fileId, 'mem://$_kris');
      expect(find.text('00:10'), findsOneWidget);
      await tester.tap(labeled('Back 10 seconds'));
      await tester.pumpAndSettle();
      expect(find.text('00:00'), findsOneWidget);

      await tester.tap(labeled('Playback speed 1x'));
      await tester.pumpAndSettle();
      expect(labeled('Playback speed 1.25x'), findsOneWidget);
      expect(t.playback.speed, 1.25);
    });

    testWidgets('toasts are plain white text', (tester) async {
      await openList(tester);
      await tester.tap(labeled('Rename')); // nothing selected
      await tester.pump();
      final rich = tester.widget<RichText>(
        find.descendant(
          of: find.text('Please select a file'),
          matching: find.byType(RichText),
        ),
      );
      // Not the yellow, underlined text Flutter shows without a style.
      expect(rich.text.style!.decoration, TextDecoration.none);
      expect(rich.text.style!.fontWeight, FontWeight.w400);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('deleting from search results keeps the keyboard down', (
      tester,
    ) async {
      await openList(tester);
      await tester.tap(labeled('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), 'kris');
      await tester.pumpAndSettle();
      await tester.longPress(find.text(_kris));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.tap(labeled('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      // Back to the search results, without the keyboard over the undo toast.
      expect(find.text('lunch w kris team convo .mp3'), findsOneWidget);
      expect(tester.testTextInput.isVisible, isFalse);
      await waitOutUndo(tester);
    });

    testWidgets('lengths show up once read', (tester) async {
      useReferenceDevice(tester);
      final files = referenceRecordings();
      final t = await pumpReferenceApp(tester, files: files);
      // 100 frames of 160 kbit/s MP3: 2.6 s.
      t.store.contents['mem://2026_09_20_17_26_27.mp3'] = [
        for (var i = 0; i < 100; i++) ...[
          0xFF,
          0xFB,
          0xA0,
          0xC0,
          ...List.filled(518, 0),
        ],
      ];
      await tester.tap(labeled('Recording list'));
      await tester.pumpAndSettle();
      expect(find.text('2026-09-20 · 00:02'), findsOneWidget);
    });
  });

  group('Settings', () {
    Future<TestApp> openSettings(WidgetTester tester) async {
      useReferenceDevice(tester);
      final t = await pumpReferenceApp(tester);
      await tester.tap(labeled('Settings'));
      await tester.pumpAndSettle();
      return t;
    }

    Finder row(String title) => find.byWidgetPredicate(
      (w) =>
          w is PressableArea && (w.semanticLabel?.startsWith(title) ?? false),
    );

    testWidgets('switches and playback speed', (tester) async {
      final t = await openSettings(tester);
      final settings = t.controller.settings;

      expect(settings.noiseReduction, isFalse);
      await tester.tap(row('Noise reduction'));
      await tester.pumpAndSettle();
      expect(settings.noiseReduction, isTrue);

      expect(settings.lockScreenControls, isTrue);
      await tester.tap(row('Lock screen controls'));
      await tester.pumpAndSettle();
      expect(settings.lockScreenControls, isFalse);
      expect(
        find.text('Playback stops when you leave the app or lock the phone'),
        findsOneWidget,
      );

      await tester.tap(row('Playback speed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1.5x'));
      await tester.pumpAndSettle();
      expect(settings.playbackSpeed, 1.5);
    });

    testWidgets('Recently deleted: restore and delete for good', (
      tester,
    ) async {
      useReferenceDevice(tester);
      final t = await pumpReferenceApp(tester);
      await tester.runAsync(
        () => t.controller.delete([
          t.store.files.firstWhere((f) => f.name == _kris),
          t.store.files.firstWhere((f) => f.name == '2026_09_17_09_27_00.mp3'),
        ]),
      );
      await tester.tap(labeled('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('2 recordings, kept for 30 days'), findsOneWidget);

      await tester.tap(row('Recently deleted'));
      await tester.pumpAndSettle();
      expect(find.text(_kris), findsOneWidget);
      expect(find.text('30 days left'), findsNWidgets(2));

      await tester.tap(find.text(_kris));
      await tester.pumpAndSettle();
      await tester.tap(labeled('Restore'));
      await tester.pumpAndSettle();
      expect(find.text(_kris), findsNothing);
      expect(
        (await tester.runAsync(t.store.list))!.map((f) => f.name),
        contains(_kris),
      );

      await tester.tap(find.text('2026_09_17_09_27_00.mp3'));
      await tester.pumpAndSettle();
      await tester.tap(labeled('Delete forever'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(t.store.deletedForGood, hasLength(1));
      expect(find.textContaining('No recently deleted'), findsOneWidget);

      await tester.tap(labeled('Back'));
      await tester.pumpAndSettle();
      expect(
        find.text('Deleted recordings are kept for 30 days'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3)); // toasts
    });
  });

  testWidgets('Settings counts again after an undo', (tester) async {
    useReferenceDevice(tester);
    await pumpReferenceApp(tester);
    await tester.tap(labeled('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(labeled('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('1 recording, kept for 30 days'), findsOneWidget);
    // The undo toast is still up over Settings.
    await tester.tap(labeled('Undo'));
    await tester.pumpAndSettle();
    expect(
      find.text('Deleted recordings are kept for 30 days'),
      findsOneWidget,
    );
  });

  test('a trashed file keeps its name for later', () {
    final at = DateTime(2026, 9, 25, 10);
    final hidden = TrashedRecording.hiddenName('2026_09_18_21_23_04.mp3', at);
    final t = TrashedRecording.parse(
      RecordingFile(id: 'x', name: hidden, size: 1, modified: at),
    )!;
    expect(t.originalName, '2026_09_18_21_23_04.mp3');
    expect(t.daysLeft(at), 30);
    expect(t.daysLeft(at.add(const Duration(hours: 1))), 30);
    expect(t.daysLeft(at.add(const Duration(days: 29, hours: 23))), 1);
    expect(t.daysLeft(at.add(const Duration(days: 30))), 0);
    expect(t.expired(at.add(const Duration(days: 30))), isTrue);
  });
}
