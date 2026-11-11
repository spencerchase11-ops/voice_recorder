// A recording's own page, opened by tapping its row in the list.
import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_recorder/src/core/format.dart';
import 'package:voice_recorder/src/core/recording_file.dart';
import 'package:voice_recorder/src/platform/native_bridge.dart';
import 'package:voice_recorder/src/ui/icons/app_icons.dart';
import 'package:voice_recorder/src/ui/screens/recording_screen.dart';
import 'package:voice_recorder/src/ui/spec.dart';
import 'package:voice_recorder/src/ui/widgets/frame.dart';
import 'package:voice_recorder/src/ui/widgets/red_bars.dart';
import 'package:voice_recorder/src/ui/widgets/toast.dart';
import 'package:voice_recorder/src/ui/screens/recording_list_screen.dart';

import '../support/fakes.dart';
import '../support/harness.dart';
import '../support/ui.dart';

const _kris = 'kris n evan got back then zach.mp3';
const _second = '2026_09_20_17_26_27.mp3';
const _third = '2026_09_18_21_23_04.mp3';

String _rec(int i) => 'rec ${i.toString().padLeft(2, '0')}.mp3';

/// One of the page's player controls, by what a screen reader says.
Finder _control(String label) => find.bySemanticsLabel(label);

/// The list's open (orange) row.
String? _openRow(WidgetTester tester) {
  final open = find.byWidgetPredicate(
    (w) => w is PressableArea && w.selected == true,
  );
  if (open.evaluate().isEmpty) return null;
  return tester.widget<PressableArea>(open).semanticLabel;
}

Future<TestApp> _openList(
  WidgetTester tester, {
  List<RecordingFile>? files,
  NativeBridge? native,
}) async {
  useReferenceDevice(tester);
  final t = await pumpReferenceApp(tester, files: files, native: native);
  await tester.tap(labeled('Recording list'));
  await tester.pumpAndSettle();
  return t;
}

Future<void> _openPage(WidgetTester tester, String name) async {
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
  expect(find.byType(RecordingScreen), findsOneWidget);
}

Future<void> _back(WidgetTester tester) async {
  await tester.tap(labeled('Back'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('tapping a row opens its page, which plays it', (tester) async {
    final t = await _openList(tester);
    await _openPage(tester, _kris);
    expect(find.text('Voice Recorder'), findsOneWidget);
    expect(find.text(_kris), findsOneWidget);
    expect(find.text('38.9 MB'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Location: /storage/emulated/0/Recorders/$_kris'),
      findsOneWidget,
    );
    expect(
      find.text(formatLongDate(DateTime(2026, 9, 23, 18, 38))),
      findsOneWidget,
    );
    expect(t.playback.played, ['mem://$_kris']);
    expect(_control('Pause'), findsOneWidget);
    // The length, once known, in the details and beside the seek bar.
    expect(find.text('03:00'), findsNWidgets(2));

    await tester.tap(_control('Pause'));
    await tester.pumpAndSettle();
    expect(t.playback.playing, isFalse);
    expect(_control('Play'), findsOneWidget);
  });

  testWidgets('back returns to the list, the row open and still playing', (
    tester,
  ) async {
    final t = await _openList(tester);
    await _openPage(tester, _kris);
    await _back(tester);
    expect(find.byType(RecordingScreen), findsNothing);
    expect(_openRow(tester), _kris);
    expect(find.byType(HoloSeekBar), findsOneWidget);
    expect(labeled('Pause $_kris'), findsOneWidget);

    // Another row's page plays that one instead.
    const other = '2026_09_20_17_26_27.mp3';
    await _openPage(tester, other);
    expect(t.playback.played, ['mem://$_kris', 'mem://$other']);
    expect(t.playback.fileId, 'mem://$other');
  });

  testWidgets('a quick second activation of the row opens one page', (
    tester,
  ) async {
    await _openList(tester);
    // Twice before the page is shown, as with VoiceOver (the navigator
    // swallows a second touch itself, not a screen reader's action).
    final row = find.semantics.byLabel(RegExp('^${RegExp.escape(_kris)}'));
    tester.semantics.tap(row);
    tester.semantics.tap(row);
    await tester.pumpAndSettle();
    await _back(tester);
    expect(find.byType(RecordingScreen), findsNothing);
    expect(find.byType(RecordingListScreen), findsOneWidget);
  });

  testWidgets('previous and next go through the list; it keeps up', (
    tester,
  ) async {
    final t = await _openList(tester);
    await _openPage(tester, _kris);
    // The newest is first: nothing before it.
    expect(
      tester.getSemantics(_control('Previous recording')),
      isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
    );

    // It was playing, so the next one plays.
    await tester.tap(_control('Next recording'));
    await tester.pumpAndSettle();
    const second = '2026_09_20_17_26_27.mp3';
    expect(find.text(second), findsOneWidget);
    expect(t.playback.played, ['mem://$_kris', 'mem://$second']);

    // Paused: the next one doesn't.
    await tester.tap(_control('Pause'));
    await tester.pumpAndSettle();
    await tester.tap(_control('Next recording'));
    await tester.pumpAndSettle();
    const third = '2026_09_18_21_23_04.mp3';
    expect(find.text(third), findsOneWidget);
    expect(t.playback.played, hasLength(2));
    expect(_control('Play'), findsOneWidget);

    await tester.tap(_control('Previous recording'));
    await tester.pumpAndSettle();
    expect(find.text(second), findsOneWidget);
    await tester.tap(_control('Next recording'));
    await tester.pumpAndSettle();

    await _back(tester);
    expect(_openRow(tester), third);
  });

  testWidgets('previous and next keep to the search results', (tester) async {
    await _openList(tester);
    await tester.tap(labeled('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'kris');
    await tester.pumpAndSettle();
    const lunch = 'lunch w kris team convo .mp3';
    await _openPage(tester, lunch);
    expect(
      tester.getSemantics(_control('Next recording')),
      isSemantics(isEnabled: false),
    );
    await tester.tap(_control('Previous recording'));
    await tester.pumpAndSettle();
    expect(find.text(_kris), findsOneWidget);
  });

  testWidgets('rename on the page; the list and next follow the new name', (
    tester,
  ) async {
    final t = await _openList(tester);
    await _openPage(tester, '2026_09_18_21_23_04.mp3');
    await tester.tap(labeled('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'late night idea');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('late night idea.mp3'), findsOneWidget);
    expect(
      (await tester.runAsync(t.store.list))!.map((f) => f.name),
      contains('late night idea.mp3'),
    );

    // Still in its place in the list's order.
    await tester.tap(_control('Next recording'));
    await tester.pumpAndSettle();
    expect(find.text('2026_09_18_19_52_06.mp3'), findsOneWidget);
    await tester.tap(_control('Previous recording'));
    await tester.pumpAndSettle();
    expect(find.text('late night idea.mp3'), findsOneWidget);

    await _back(tester);
    expect(_openRow(tester), 'late night idea.mp3');
  });

  testWidgets('share on the page shares that recording', (tester) async {
    final t = await _openList(tester);
    await _openPage(tester, '2026_09_18_21_23_04.mp3');
    await tester.tap(labeled('Share'));
    await tester.pump();
    expect(t.store.shared, ['2026_09_18_21_23_04.mp3']);
    await tester.pumpAndSettle();
  });

  testWidgets('delete on the page closes it; Undo brings it back', (
    tester,
  ) async {
    final t = await _openList(tester);
    const name = '2026_09_18_21_23_04.mp3';
    await _openPage(tester, name);
    await tester.tap(labeled('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Are you sure to delete file? /$name'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byType(RecordingScreen), findsNothing);
    expect(find.byType(RecordingListScreen), findsOneWidget);
    expect(find.text(name), findsNothing);
    expect(await tester.runAsync(t.store.list), hasLength(9));

    await tester.tap(labeled('Undo'));
    await tester.pumpAndSettle();
    expect(find.text(name), findsOneWidget);
    await waitOutUndo(tester);
  });

  testWidgets('cancelling the delete keeps the page', (tester) async {
    final t = await _openList(tester);
    await _openPage(tester, _kris);
    await tester.tap(labeled('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(RecordingScreen), findsOneWidget);
    expect(await tester.runAsync(t.store.list), hasLength(10));
  });

  testWidgets('skip buttons move 10 seconds', (tester) async {
    final t = await _openList(tester);
    await _openPage(tester, _kris);
    await tester.tap(_control('Forward 10 seconds'));
    await tester.pumpAndSettle();
    expect(t.playback.position, const Duration(seconds: 10));
    expect(find.text('00:10'), findsOneWidget);
    await tester.tap(_control('Back 10 seconds'));
    await tester.pumpAndSettle();
    expect(t.playback.position, Duration.zero);
  });

  testWidgets('dragging the seek bar seeks once, on release', (tester) async {
    final t = await _openList(tester);
    await _openPage(tester, _kris);
    final bar = tester.getRect(_control('Position'));
    final gesture = await tester.startGesture(
      Offset(bar.left + 40, bar.center.dy),
    );
    await gesture.moveBy(const Offset(60, 0));
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(t.playback.seeks, 0); // not while dragging
    await gesture.up();
    await tester.pumpAndSettle();
    expect(t.playback.seeks, 1);
    expect(t.playback.position, greaterThan(Duration.zero));
    expect(t.playback.playing, isTrue);
  });

  testWidgets('a quick second Next plays the recording shown', (tester) async {
    final t = await _openList(tester);
    await _openPage(tester, _kris);
    // The next one takes a while to open; Next again meanwhile.
    final gate = t.playback.loadGate = Completer<void>();
    await tester.tap(_control('Next recording'));
    await tester.pump();
    await tester.tap(_control('Next recording'));
    await tester.pump();
    gate.complete();
    t.playback.loadGate = null;
    await tester.pumpAndSettle();
    const third = '2026_09_18_21_23_04.mp3';
    expect(find.text(third), findsOneWidget);
    expect(t.playback.fileId, 'mem://$third');
    expect(t.playback.playing, isTrue);
    expect(_control('Pause'), findsOneWidget);
  });

  testWidgets("a screen reader's tap on a seek bar doesn't move it", (
    tester,
  ) async {
    final t = await _openList(tester);
    await _openPage(tester, _kris);

    // Only the slider's own actions: no tap or scroll seeking somewhere.
    void expectSliderOnly() {
      final node = tester.getSemantics(_control('Position'));
      final actions = node.getSemanticsData().actions;
      expect(
        actions,
        SemanticsAction.increase.index | SemanticsAction.decrease.index,
      );
    }

    expectSliderOnly();
    tester.semantics.increase(find.semantics.byLabel('Position'));
    await tester.pumpAndSettle();
    expect(t.playback.seeks, 1);
    expect(t.playback.position, const Duration(seconds: 9)); // 5 % of 3:00

    // The list's seek bar too.
    await _back(tester);
    expect(find.byType(HoloSeekBar), findsOneWidget);
    expectSliderOnly();
  });

  testWidgets('Back while the page deletes leaves the list open', (
    tester,
  ) async {
    final t = await _openList(tester);
    const name = '2026_09_18_21_23_04.mp3';
    await _openPage(tester, name);
    await tester.tap(labeled('Delete'));
    await tester.pumpAndSettle();
    final slow = t.store.slow = Completer<void>();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    // Back, and the delete finishes while the page slides away.
    await tester.tap(labeled('Back'));
    await tester.pump(const Duration(milliseconds: 50));
    slow.complete();
    t.store.slow = null;
    await tester.pumpAndSettle();
    expect(find.byType(RecordingScreen), findsNothing);
    expect(find.byType(RecordingListScreen), findsOneWidget);
    expect(find.text(name), findsNothing);
    await waitOutUndo(tester);
    expect(find.byType(RecordingListScreen), findsOneWidget);
  });

  testWidgets('a rename that finishes after Back still opens the new name', (
    tester,
  ) async {
    final t = await _openList(tester);
    await _openPage(tester, '2026_09_18_21_23_04.mp3');
    await tester.tap(labeled('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'late night idea');
    final slow = t.store.slow = Completer<void>();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await _back(tester);
    expect(find.byType(RecordingScreen), findsNothing);
    slow.complete();
    t.store.slow = null;
    await tester.pumpAndSettle();
    expect(_openRow(tester), 'late night idea.mp3');
  });

  testWidgets('at the largest text, the times let a seek through', (
    tester,
  ) async {
    useReferenceDevice(tester);
    // iPhone's largest accessibility size.
    tester.platformDispatcher.textScaleFactorTestValue = 3.1;
    final t = await pumpReferenceApp(tester);
    await tester.tap(labeled('Recording list'));
    await tester.pumpAndSettle();
    await _openPage(tester, _kris);

    // The player's times (the lowest "03:00" is beside the seek bar).
    final length = find
        .text('03:00')
        .evaluate()
        .reduce(
          (a, b) =>
              tester.getRect(find.byWidget(a.widget)).top >
                  tester.getRect(find.byWidget(b.widget)).top
              ? a
              : b,
        );
    // No larger than Android's largest (2x).
    expect(MediaQuery.textScalerOf(length).scale(14), 28);

    // A touch on the seek bar that the length's text covers.
    final bar = tester.getRect(_control('Position'));
    final text = tester.getRect(find.byWidget(length.widget));
    final spot = Offset(text.center.dx, (text.top + bar.bottom) / 2);
    expect(bar.contains(spot) && text.contains(spot), isTrue);
    await tester.tapAt(spot);
    await tester.pumpAndSettle();
    expect(t.playback.seeks, 1);
    expect(t.playback.position, greaterThan(const Duration(minutes: 2)));
  });

  testWidgets('a tap goes to the nearest header button', (tester) async {
    final t = await _openList(tester);
    await _openPage(tester, '2026_09_18_21_23_04.mp3');
    // Right of the pencil, but nearer it than Share.
    final pencil = tester.getCenter(labeled('Rename'));
    await tester.tapAt(pencil + const Offset(15, 0));
    await tester.pumpAndSettle();
    expect(t.store.shared, isEmpty);
    expect(find.byType(EditableText), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // And right of Share, nearer it than Delete.
    final share = tester.getCenter(labeled('Share'));
    await tester.tapAt(share + const Offset(15, 0));
    await tester.pump();
    expect(t.store.shared, ['2026_09_18_21_23_04.mp3']);
    await tester.pumpAndSettle();
    expect(find.textContaining('Are you sure'), findsNothing);
  });

  testWidgets('Play, then a quick Next, plays the recording shown', (
    tester,
  ) async {
    final t = await _openList(tester);
    await _openPage(tester, _kris);
    await tester.tap(_control('Pause'));
    await tester.pumpAndSettle();
    // The next one takes a while to open: Play, then Next, meanwhile.
    final gate = t.playback.loadGate = Completer<void>();
    await tester.tap(_control('Next recording'));
    await tester.pump();
    await tester.tap(_control('Play'));
    await tester.pump();
    await tester.tap(_control('Next recording'));
    await tester.pump();
    gate.complete();
    t.playback.loadGate = null;
    await tester.pumpAndSettle();
    expect(find.text(_third), findsOneWidget);
    expect(t.playback.fileId, 'mem://$_third');
    expect(t.playback.playing, isTrue);
    expect(_control('Pause'), findsOneWidget);
  });

  testWidgets('a skip while the next one opens keeps it playing', (
    tester,
  ) async {
    final t = await _openList(tester);
    await _openPage(tester, _kris);
    final gate = t.playback.loadGate = Completer<void>();
    await tester.tap(_control('Next recording'));
    await tester.pump();
    await tester.tap(_control('Forward 10 seconds'));
    await tester.pump();
    gate.complete();
    t.playback.loadGate = null;
    await tester.pumpAndSettle();
    expect(t.playback.fileId, 'mem://$_second');
    expect(t.playback.playing, isTrue);
    expect(t.playback.position, const Duration(seconds: 10));
  });

  testWidgets('after Next while paused, the headphones play the one shown', (
    tester,
  ) async {
    final native = FakeNative();
    final t = await _openList(tester, native: native);
    await _openPage(tester, _kris);
    await tester.tap(_control('Pause'));
    await tester.pumpAndSettle();
    await tester.tap(_control('Next recording'));
    await tester.pumpAndSettle();
    // Loaded, paused, from the start.
    expect(t.playback.fileId, 'mem://$_second');
    expect(t.playback.playing, isFalse);
    expect(t.playback.position, Duration.zero);

    // The controller listens in the real zone (it was set up there).
    await tester.runAsync(() async {
      native.eventController.add(const MediaButton('toggle'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(t.playback.fileId, 'mem://$_second');
    expect(t.playback.playing, isTrue);
    expect(_control('Pause'), findsOneWidget);
  });

  testWidgets('after Next while paused, the lock screen shows the one shown', (
    tester,
  ) async {
    final calls = mockNativeChannel();
    await _openList(tester);
    await _openPage(tester, _kris);
    await tester.tap(_control('Pause'));
    await tester.pumpAndSettle();
    calls.clear();
    await tester.tap(_control('Next recording'));
    await tester.pumpAndSettle();
    final media = calls.where((c) => c.contains('MediaSession')).toList();
    expect(media, isNotEmpty);
    expect(media, everyElement('updateMediaSession'));
  });

  testWidgets('a recording left paused is where it was on coming back', (
    tester,
  ) async {
    final t = await _openList(tester);
    await _openPage(tester, _kris);
    await tester.tap(_control('Forward 10 seconds'));
    await tester.pumpAndSettle();
    await tester.tap(_control('Forward 10 seconds'));
    await tester.pumpAndSettle();
    await tester.tap(_control('Pause'));
    await tester.pumpAndSettle();
    await tester.tap(_control('Next recording'));
    await tester.pumpAndSettle();
    expect(t.playback.fileId, 'mem://$_second');
    expect(t.playback.position, Duration.zero);

    await tester.tap(_control('Previous recording'));
    await tester.pumpAndSettle();
    expect(t.playback.fileId, 'mem://$_kris');
    expect(t.playback.playing, isFalse);
    expect(t.playback.position, const Duration(seconds: 20));
    expect(find.text('00:20'), findsOneWidget);
  });

  testWidgets('the page closes when its recording is gone from the folder', (
    tester,
  ) async {
    final calls = mockNativeChannel();
    final t = await _openList(tester);
    await _openPage(tester, _third);
    expect(t.playback.playing, isTrue);
    // Deleted in a file manager; the folder is listed again on coming back.
    t.store.files.removeWhere((f) => f.name == _third);
    await tester.runAsync(t.controller.refreshFiles);
    await tester.pumpAndSettle();
    expect(find.byType(RecordingScreen), findsNothing);
    expect(find.byType(RecordingListScreen), findsOneWidget);
    expect(find.text(_third), findsNothing);
    // It stops, and its lock-screen controls go, as after a delete.
    expect(t.playback.fileId, isNull);
    expect(t.playback.playing, isFalse);
    expect(calls.last, 'clearMediaSession');
  });

  testWidgets('after Cancel, a page whose recording went meanwhile closes', (
    tester,
  ) async {
    final t = await _openList(tester);
    await _openPage(tester, _third);
    await tester.tap(_control('Pause'));
    await tester.pumpAndSettle();
    for (final button in ['Rename', 'Delete']) {
      await tester.tap(labeled(button));
      await tester.pumpAndSettle();
      // Deleted elsewhere while the dialog is open: the page waits for it.
      t.store.files.removeWhere((f) => f.name == _third);
      await tester.runAsync(t.controller.refreshFiles);
      await tester.pumpAndSettle();
      expect(find.byType(RecordingScreen), findsOneWidget, reason: button);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      if (button == 'Rename') {
        expect(find.byType(RecordingScreen), findsNothing);
        // Again, with Delete's dialog this time.
        t.store.files.add(
          referenceRecordings().firstWhere((f) => f.name == _third),
        );
        await tester.runAsync(t.controller.refreshFiles);
        await tester.pumpAndSettle();
        expect(find.text(_third), findsOneWidget);
        await _openPage(tester, _third);
        await tester.tap(_control('Pause'));
        await tester.pumpAndSettle();
      }
    }
    expect(find.byType(RecordingScreen), findsNothing);
  });

  testWidgets('a place from an earlier visit is not brought back later', (
    tester,
  ) async {
    final t = await _openList(tester);
    await _openPage(tester, _kris);
    for (var i = 0; i < 2; i++) {
      await tester.tap(_control('Forward 10 seconds'));
      await tester.pumpAndSettle();
    }
    await tester.tap(_control('Pause'));
    await tester.pumpAndSettle();
    await tester.tap(_control('Next recording'));
    await tester.pumpAndSettle();
    await tester.tap(_control('Play'));
    await tester.pumpAndSettle();
    // Back while playing: it plays from the start.
    await tester.tap(_control('Previous recording'));
    await tester.pumpAndSettle();
    expect(t.playback.fileId, 'mem://$_kris');
    expect(t.playback.position, Duration.zero);
    // Left playing, at 00:10.
    await tester.tap(_control('Forward 10 seconds'));
    await tester.pumpAndSettle();
    await tester.tap(_control('Next recording'));
    await tester.pumpAndSettle();
    await tester.tap(_control('Pause'));
    await tester.pumpAndSettle();
    await tester.tap(_control('Previous recording'));
    await tester.pumpAndSettle();
    // Not at 00:20 from the earlier visit: from the start, as one left
    // playing is.
    expect(t.playback.fileId, 'mem://$_kris');
    expect(t.playback.playing, isFalse);
    expect(t.playback.position, Duration.zero);
  });

  testWidgets('a seek-bar tap while a recording opens at its place wins', (
    tester,
  ) async {
    final t = await _openList(tester);
    await _openPage(tester, _kris);
    for (var i = 0; i < 2; i++) {
      await tester.tap(_control('Forward 10 seconds'));
      await tester.pumpAndSettle();
    }
    await tester.tap(_control('Pause'));
    await tester.pumpAndSettle();
    await tester.tap(_control('Next recording'));
    await tester.pumpAndSettle();
    final gate = t.playback.loadGate = Completer<void>();
    await tester.tap(_control('Previous recording'));
    await tester.pump();
    // Halfway along, while it opens at 00:20.
    await tester.tapAt(tester.getRect(_control('Position')).center);
    await tester.pump();
    gate.complete();
    t.playback.loadGate = null;
    await tester.pumpAndSettle();
    expect(t.playback.fileId, 'mem://$_kris');
    expect(t.playback.position.inSeconds, inInclusiveRange(80, 100));
  });

  testWidgets('a recording passed before it has opened keeps its place', (
    tester,
  ) async {
    final t = await _openList(tester);
    await _openPage(tester, _second);
    for (var i = 0; i < 2; i++) {
      await tester.tap(_control('Forward 10 seconds'));
      await tester.pumpAndSettle();
    }
    await tester.tap(_control('Pause'));
    await tester.pumpAndSettle();
    await tester.tap(_control('Next recording'));
    await tester.pumpAndSettle();
    // Two quick Previous taps: the second while the first one opens.
    final first = t.playback.loadGate = Completer<void>();
    await tester.tap(_control('Previous recording'));
    await tester.pump();
    final second = t.playback.loadGate = Completer<void>();
    await tester.tap(_control('Previous recording'));
    await tester.pump();
    t.playback.loadGate = null;
    first.complete();
    second.complete();
    await tester.pumpAndSettle();
    expect(find.text(_kris), findsOneWidget);
    expect(t.playback.fileId, 'mem://$_kris');
    await tester.tap(_control('Next recording'));
    await tester.pumpAndSettle();
    expect(t.playback.fileId, 'mem://$_second');
    expect(t.playback.position, const Duration(seconds: 20));
  });

  testWidgets('a page opened while its recording is renamed follows it', (
    tester,
  ) async {
    final t = await _openList(tester);
    await _openPage(tester, _third);
    await tester.tap(labeled('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'late night idea');
    final slow = t.store.slow = Completer<void>();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await _back(tester);
    // Its row, still under the old name: it plays again.
    await _openPage(tester, _third);
    expect(t.playback.isPlaying('mem://$_third'), isTrue);
    slow.complete();
    t.store.slow = null;
    await tester.pumpAndSettle();
    // Still open, on the new name; nothing plays under the old one.
    expect(find.byType(RecordingScreen), findsOneWidget);
    expect(find.text('late night idea.mp3'), findsOneWidget);
    expect(t.playback.fileId, isNot('mem://$_third'));
    expect(_control('Play'), findsOneWidget);
    await tester.tap(_control('Play'));
    await tester.pumpAndSettle();
    expect(t.playback.isPlaying('mem://late night idea.mp3'), isTrue);
    expect(_control('Pause'), findsOneWidget);
    // Playing, so the next one plays too.
    await tester.tap(_control('Next recording'));
    await tester.pumpAndSettle();
    expect(t.playback.isPlaying('mem://2026_09_18_19_52_06.mp3'), isTrue);
    await tester.tap(_control('Previous recording'));
    await tester.pumpAndSettle();
    expect(find.text('late night idea.mp3'), findsOneWidget);
    await _back(tester);
    expect(_openRow(tester), 'late night idea.mp3');
  });

  testWidgets('a page opened while another is renamed reaches it with Next', (
    tester,
  ) async {
    final t = await _openList(tester);
    await _openPage(tester, _third);
    await tester.tap(labeled('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'late night idea');
    final slow = t.store.slow = Completer<void>();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await _back(tester);
    await _openPage(tester, _second);
    slow.complete();
    t.store.slow = null;
    await tester.pumpAndSettle();
    expect(find.text(_second), findsOneWidget);
    await tester.tap(_control('Next recording'));
    await tester.pumpAndSettle();
    expect(find.text('late night idea.mp3'), findsOneWidget);
    expect(t.playback.isPlaying('mem://late night idea.mp3'), isTrue);
    await tester.tap(_control('Previous recording'));
    await tester.pumpAndSettle();
    expect(find.text(_second), findsOneWidget);
  });

  // A skip while a recording opens at its place jumps from that place.
  for (final (label, expected) in [
    ('Forward 10 seconds', const Duration(seconds: 70)),
    ('Back 10 seconds', const Duration(seconds: 50)),
  ]) {
    testWidgets('$label while a recording opens at its place', (tester) async {
      final t = await _openList(tester);
      await _openPage(tester, _kris);
      for (var i = 0; i < 6; i++) {
        await tester.tap(_control('Forward 10 seconds'));
        await tester.pumpAndSettle();
      }
      await tester.tap(_control('Pause'));
      await tester.pumpAndSettle();
      await tester.tap(_control('Next recording'));
      await tester.pumpAndSettle();
      final gate = t.playback.loadGate = Completer<void>();
      await tester.tap(_control('Previous recording'));
      await tester.pump();
      await tester.tap(_control(label));
      await tester.pump();
      gate.complete();
      t.playback.loadGate = null;
      await tester.pumpAndSettle();
      expect(t.playback.fileId, 'mem://$_kris');
      expect(t.playback.playing, isFalse);
      expect(t.playback.position, expected);
    });
  }

  testWidgets('a recording deleted while it opens stays stopped', (
    tester,
  ) async {
    final t = await _openList(tester);
    await _openPage(tester, _kris);
    // Playing, so Next plays the next one: it takes a while to open.
    final gate = t.playback.loadGate = Completer<void>();
    await tester.tap(_control('Next recording'));
    await tester.pump();
    await tester.tap(labeled('Delete'));
    await tester.pumpAndSettle();
    final slow = t.store.slow = Completer<void>();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    gate.complete();
    t.playback.loadGate = null;
    await tester.pumpAndSettle();
    // Stopped before it is moved: it never opens.
    expect(t.playback.fileId, isNull);
    expect(t.playback.playing, isFalse);
    slow.complete();
    t.store.slow = null;
    await tester.pumpAndSettle();
    expect(find.byType(RecordingScreen), findsNothing);
    expect(find.text(_second), findsNothing);
    expect(t.playback.fileId, isNull);
    expect(t.playback.playing, isFalse);
    await waitOutUndo(tester);
  });

  testWidgets('a page reopened on a recording being deleted stops with it', (
    tester,
  ) async {
    final t = await _openList(tester);
    await _openPage(tester, _second);
    await tester.tap(labeled('Delete'));
    await tester.pumpAndSettle();
    final slow = t.store.slow = Completer<void>();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await _back(tester);
    // Its row is still there while it is moved: opened, it plays.
    await _openPage(tester, _second);
    expect(t.playback.isPlaying('mem://$_second'), isTrue);
    slow.complete();
    t.store.slow = null;
    await tester.pumpAndSettle();
    expect(find.byType(RecordingScreen), findsNothing);
    expect(find.text(_second), findsNothing);
    expect(t.playback.fileId, isNull);
    expect(t.playback.playing, isFalse);
    // The page on it closed: nothing is under the Undo toast.
    expect(labeled('Undo'), findsOneWidget);
    await waitOutUndo(tester);
  });

  testWidgets(
    "a delete that ends on another recording's page leaves out Undo",
    (tester) async {
      final t = await _openList(tester);
      await _openPage(tester, _third);
      await tester.tap(labeled('Delete'));
      await tester.pumpAndSettle();
      final slow = t.store.slow = Completer<void>();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await _back(tester);
      await _openPage(tester, _kris);
      slow.complete();
      t.store.slow = null;
      await tester.pumpAndSettle();
      expect(find.byType(RecordingScreen), findsOneWidget);
      expect(find.text('Moved to Recently deleted'), findsOneWidget);
      expect(labeled('Undo'), findsNothing);
      // A tap on the seek bar under it goes through.
      final seeks = t.playback.seeks;
      final bar = tester.getRect(find.bySemanticsLabel('Position'));
      await tester.tapAt(Offset(bar.left + bar.width * 0.3, bar.center.dy));
      await tester.pumpAndSettle();
      expect(t.playback.seeks, seeks + 1);
      await waitOutUndo(tester);
    },
  );

  /// 40 recordings, newest first: 'rec 00.mp3' to 'rec 39.mp3'.
  List<RecordingFile> forty() => [
    for (var i = 0; i < 40; i++)
      RecordingFile(
        id: 'mem://${_rec(i)}',
        name: _rec(i),
        size: 1024 * 1024,
        modified: DateTime(2026, 9, 23, 12).subtract(Duration(hours: i)),
      ),
  ];

  ScrollPosition listPosition(WidgetTester tester) => tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position;

  /// The open row is wholly in the list's view, its controls reachable.
  void expectOpenRowShown(WidgetTester tester, String name) {
    expect(_openRow(tester), name);
    final open = find.byWidgetPredicate(
      (w) => w is PressableArea && w.selected == true,
    );
    final list = tester.getRect(find.byType(ListView));
    final row = tester.getRect(open);
    expect(row.top, greaterThanOrEqualTo(list.top - 0.01), reason: '$row');
    expect(row.bottom, lessThanOrEqualTo(list.bottom + 0.01), reason: '$row');
    expect(labeled('Pause $name').hitTestable(), findsOneWidget);
    expect(_control('Forward 10 seconds').hitTestable(), findsOneWidget);
  }

  testWidgets('after Next to the last recording, Back shows all its row', (
    tester,
  ) async {
    await _openList(tester, files: forty());
    await _openPage(tester, _rec(0));
    for (var i = 0; i < 39; i++) {
      await tester.tap(_control('Next recording'));
      await tester.pumpAndSettle();
    }
    await _back(tester);
    expectOpenRowShown(tester, _rec(39));
  });

  testWidgets('after Previous far up, Back shows the row under the header', (
    tester,
  ) async {
    await _openList(tester, files: forty());
    listPosition(tester).jumpTo(1500);
    await tester.pumpAndSettle();
    // The top row then.
    await _openPage(tester, _rec(23));
    for (var i = 0; i < 6; i++) {
      await tester.tap(_control('Previous recording'));
      await tester.pumpAndSettle();
    }
    await _back(tester);
    expectOpenRowShown(tester, _rec(17));
  });

  testWidgets('a row whose player would be below the list is moved up', (
    tester,
  ) async {
    await _openList(tester, files: forty());
    final row =
        tester.getTopLeft(find.text(_rec(1))).dy -
        tester.getTopLeft(find.text(_rec(0))).dy;
    final p = listPosition(tester);
    // Row 12's name and date end just above the list's bottom edge.
    p.jumpTo(Spec.listTopGap + 13 * row - p.viewportDimension + 1);
    await tester.pumpAndSettle();
    await _openPage(tester, _rec(11));
    await tester.tap(_control('Next recording'));
    await tester.pumpAndSettle();
    await _back(tester);
    expectOpenRowShown(tester, _rec(12));
  });

  testWidgets("a row opened while the list's delete runs stays open", (
    tester,
  ) async {
    final t = await _openList(tester);
    await tester.tap(labeled('Play $_third'));
    await tester.pumpAndSettle();
    await tester.tap(labeled('Pause $_third'));
    await tester.pumpAndSettle();
    await tester.tap(labeled('Delete'));
    await tester.pumpAndSettle();
    final slow = t.store.slow = Completer<void>();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await _openPage(tester, _second);
    slow.complete();
    t.store.slow = null;
    await tester.pumpAndSettle();
    await _back(tester);
    expect(_openRow(tester), _second);
    expect(t.playback.isPlaying('mem://$_second'), isTrue);
    await waitOutUndo(tester);
  });

  testWidgets('after paging far with Next, Back shows the row playing', (
    tester,
  ) async {
    String name(int i) => 'rec ${i.toString().padLeft(2, '0')}.mp3';
    await _openList(
      tester,
      files: [
        for (var i = 0; i < 40; i++)
          RecordingFile(
            id: 'mem://${name(i)}',
            name: name(i),
            size: 1024 * 1024,
            modified: DateTime(2026, 9, 23, 12).subtract(Duration(hours: i)),
          ),
      ],
    );
    await _openPage(tester, name(0));
    for (var i = 0; i < 25; i++) {
      await tester.tap(_control('Next recording'));
      await tester.pumpAndSettle();
    }
    expect(find.text(name(25)), findsOneWidget);
    await _back(tester);
    expect(_openRow(tester), name(25));
    expect(labeled('Pause ${name(25)}').hitTestable(), findsOneWidget);
    // A row already on screen is left where it is.
    ScrollPosition list() => tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    final at = list().pixels;
    await _openPage(tester, name(27));
    await tester.tap(_control('Next recording'));
    await tester.pumpAndSettle();
    await _back(tester);
    expect(_openRow(tester), name(28));
    expect(list().pixels, at);
  });

  testWidgets('Previous and Next are heard once: the name is announced', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(supportsAnnounce: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _openList(tester);
    await _openPage(tester, _kris);
    await tester.tap(_control('Pause'));
    await tester.pumpAndSettle();
    tester.takeAnnouncements();
    await tester.tap(_control('Next recording'));
    await tester.pumpAndSettle();
    expect(tester.takeAnnouncements().map((a) => a.message), [
      'Name: $_second',
    ]);
    // Not a live region as well: VoiceOver would say it again, and again
    // after every dialog that closes over it.
    expect(
      tester.getSemantics(find.bySemanticsLabel('Name: $_second')),
      isNot(isSemantics(isLiveRegion: true)),
    );
    await tester.tap(labeled('Rename'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeAnnouncements(), isEmpty);
  });

  testWidgets("where it can't announce, the name's row is read out", (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures();
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _openList(tester);
    await _openPage(tester, _kris);
    await tester.tap(_control('Pause'));
    await tester.pumpAndSettle();
    await tester.tap(_control('Next recording'));
    await tester.pumpAndSettle();
    expect(tester.takeAnnouncements(), isEmpty);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Name: $_second')),
      isSemantics(isLiveRegion: true),
    );
    // The other rows are not read out on their own.
    expect(
      tester.getSemantics(find.bySemanticsLabel(RegExp('^Size: '))),
      isNot(isSemantics(isLiveRegion: true)),
    );
  });

  testWidgets('renamed to a name freed in Files, Next still goes on', (
    tester,
  ) async {
    final t = await _openList(tester);
    await _openPage(tester, _second);
    // The row before it is deleted in the Files app.
    t.store.files.removeWhere((f) => f.name == _kris);
    await tester.runAsync(t.controller.refreshFiles);
    await tester.pumpAndSettle();
    await tester.tap(labeled('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(EditableText),
      _kris.substring(0, _kris.length - 4),
    );
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text(_kris), findsOneWidget);
    await tester.tap(_control('Play'));
    await tester.pumpAndSettle();
    expect(t.playback.isPlaying('mem://$_kris'), isTrue);
    await tester.tap(_control('Next recording'));
    await tester.pumpAndSettle();
    expect(find.text(_third), findsOneWidget);
    expect(t.playback.isPlaying('mem://$_third'), isTrue);
    await tester.tap(_control('Previous recording'));
    await tester.pumpAndSettle();
    expect(find.text(_kris), findsOneWidget);
  });

  testWidgets("the open row's position is read out by its slider only", (
    tester,
  ) async {
    await _openList(tester);
    await _openPage(tester, _kris);
    await tester.tap(_control('Forward 10 seconds'));
    await tester.pumpAndSettle();
    await tester.tap(_control('Pause'));
    await tester.pumpAndSettle();
    await _back(tester);
    expect(_openRow(tester), _kris);
    final row = find.byWidgetPredicate(
      (w) => w is PressableArea && w.selected == true,
    );
    final label = tester.getSemantics(row).label;
    expect(label, startsWith(_kris));
    expect(label, isNot(contains('00:10')));
    expect(
      tester.getSemantics(find.bySemanticsLabel('Position')).value,
      contains('00:10'),
    );
  });

  testWidgets('at 2x on a narrow phone, the page title is whole', (
    tester,
  ) async {
    useReferenceDevice(tester);
    tester.view.physicalSize = const Size(960, 1704);
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    await pumpReferenceApp(tester);
    await tester.tap(labeled('Recording list'));
    await tester.pumpAndSettle();
    await _openPage(tester, _kris);
    final title = find.descendant(
      of: find.byType(RecordingScreen),
      matching: find.text('Voice Recorder'),
    );
    expect(
      tester.renderObject<RenderParagraph>(title).didExceedMaxLines,
      isFalse,
    );
    final rect = tester.getRect(title);
    expect(rect.left, greaterThanOrEqualTo(Spec.pageTitleLeft - 0.01));
    expect(
      rect.right,
      lessThanOrEqualTo(320 - Spec.pageRenameFromRight - 24 + 0.01),
    );
  });

  testWidgets("a folder out of reach, or that can't be read, leaves it open", (
    tester,
  ) async {
    final t = await _openList(tester);
    await _openPage(tester, _third);
    // An SD card taken out: the folder lists nothing.
    t.store.ready = false;
    await tester.runAsync(t.controller.refreshFiles);
    await tester.pumpAndSettle();
    expect(t.controller.files, isEmpty);
    expect(find.byType(RecordingScreen), findsOneWidget);

    t.store
      ..ready = true
      ..failLists = true;
    await tester.runAsync(t.controller.refreshFiles);
    await tester.pumpAndSettle();
    expect(find.byType(RecordingScreen), findsOneWidget);
  });

  testWidgets("the player's times are read out by the slider only", (
    tester,
  ) async {
    await _openList(tester);
    await _openPage(tester, _kris);
    await tester.tap(_control('Pause'));
    await tester.pumpAndSettle();
    // Nothing says just the position or the length (the details' row
    // says what its length is).
    expect(find.bySemanticsLabel('00:00'), findsNothing);
    expect(find.bySemanticsLabel('03:00'), findsNothing);
    expect(find.bySemanticsLabel(RegExp('03:00')), findsWidgets);
    final slider = tester.getSemantics(_control('Position'));
    expect(slider.value, contains('00:00'));
  });

  testWidgets("a delete's Undo doesn't lie over the next page", (tester) async {
    await _openList(tester);
    await _openPage(tester, _third);
    await tester.tap(labeled('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(labeled('Undo'), findsOneWidget);

    await _openPage(tester, _kris);
    expect(labeled('Undo'), findsNothing);
    await _back(tester);
    hideActionToast();
    await tester.pumpAndSettle();
  });

  testWidgets("the header buttons' highlight is as wide as they are apart", (
    tester,
  ) async {
    await _openList(tester);
    await _openPage(tester, _third);
    const apart = (Spec.pageRenameFromRight - Spec.pageShareFromRight) / 2 * 2;
    for (final label in ['Rename', 'Share', 'Delete']) {
      final icon = find.descendant(
        of: labeled(label),
        matching: find.byType(InkIcon),
      );
      final centre = tester.getCenter(icon);
      final gesture = await tester.startGesture(centre);
      await tester.pump();
      final glow = tester.getRect(
        find.descendant(
          of: labeled(label),
          matching: find.byWidgetPredicate(
            (w) => w is ColoredBox && w.color == const Color(0x33FFFFFF),
          ),
        ),
      );
      expect(glow.width, moreOrLessEquals(apart, epsilon: 0.2), reason: label);
      expect(glow.center.dx, moreOrLessEquals(centre.dx, epsilon: 0.2));
      await gesture.cancel();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('the player waits while the page renames', (tester) async {
    final t = await _openList(tester);
    await _openPage(tester, _third);
    await tester.tap(_control('Pause'));
    await tester.pumpAndSettle();
    final played = [...t.playback.played];
    await tester.tap(labeled('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'late night idea');
    final slow = t.store.slow = Completer<void>();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    // Still saving the new name.
    await tester.tap(_control('Next recording'));
    await tester.pumpAndSettle();
    await tester.tap(_control('Play'));
    await tester.pumpAndSettle();
    expect(find.text(_third), findsOneWidget);
    expect(t.playback.played, played);
    slow.complete();
    t.store.slow = null;
    await tester.pumpAndSettle();
    expect(find.text('late night idea.mp3'), findsOneWidget);
  });

  testWidgets("a late rename doesn't take over a row opened meanwhile", (
    tester,
  ) async {
    final t = await _openList(tester);
    await _openPage(tester, _third);
    await tester.tap(labeled('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'late night idea');
    final slow = t.store.slow = Completer<void>();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await _back(tester);
    // Another row's page, while the rename goes on.
    await _openPage(tester, _second);
    slow.complete();
    t.store.slow = null;
    await tester.pumpAndSettle();
    expect(find.text(_second), findsOneWidget);
    await _back(tester);
    expect(_openRow(tester), _second);
  });

  testWidgets('with Bold Text on, a long name keeps every line', (
    tester,
  ) async {
    await loadAppFonts(); // bold Roboto is wider than regular
    useReferenceDevice(tester);
    // A 375 pt wide iPhone at the default text size, where this name takes
    // two lines, but three in bold.
    tester.view.physicalSize = const Size(375 * 3.5, 3120);
    tester.platformDispatcher.textScaleFactorTestValue = 1;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(boldText: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    const name =
        'Call with Jordan about the quarterly budget review and the new '
        'office lease plans for.m4a';
    await pumpReferenceApp(
      tester,
      files: [
        RecordingFile(
          id: 'mem://$name',
          name: name,
          size: 1000000,
          modified: DateTime(2026, 9, 20, 12),
        ),
      ],
    );
    await tester.tap(labeled('Recording list'));
    await tester.pumpAndSettle();
    await _openPage(tester, name);

    // The name, and the location ending with it: each box is as tall as the
    // lines drawn in it.
    final texts = find.descendant(
      of: find.byType(RecordingScreen),
      matching: find.byWidgetPredicate(
        (w) => w is Text && (w.data?.endsWith(name) ?? false),
      ),
    );
    expect(texts, findsNWidgets(2));
    for (final element in texts.evaluate()) {
      final text = find.byWidget(element.widget);
      final data = (element.widget as Text).data!;
      final drawn = tester
          .renderObject<RenderParagraph>(text)
          .getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: data.length),
          )
          .map((b) => b.top.round())
          .toSet()
          .length;
      final m = AndroidFontMetrics.of(element, Spec.pageText);
      final box = tester.getSize(
        find.ancestor(of: text, matching: find.byType(AText)).first,
      );
      expect(box.height, closeTo(m.height(drawn), 0.01), reason: data);
    }
    expect(find.text(name), findsOneWidget);
  });

  testWidgets("at the largest text, the title stays in the header", (
    tester,
  ) async {
    useReferenceDevice(tester);
    tester.platformDispatcher.textScaleFactorTestValue = 3.1;
    await pumpReferenceApp(tester);
    await tester.tap(labeled('Recording list'));
    await tester.pumpAndSettle();
    await _openPage(tester, _kris);
    final page = find.byType(RecordingScreen);
    final header = tester.getRect(
      find.descendant(of: page, matching: find.byType(RedHeader)),
    );
    final text = find.descendant(
      of: page,
      matching: find.text('Voice Recorder'),
    );
    // No larger than Android's largest (2x), its letters inside the bar.
    expect(MediaQuery.textScalerOf(tester.element(text)).scale(10), 20);
    final title = tester.getRect(text);
    // AText sets the text on its box's first baseline.
    final box = tester.getRect(
      find.ancestor(of: text, matching: find.byType(AText)).first,
    );
    final baseline =
        box.top +
        AndroidFontMetrics.of(
          tester.element(text),
          Spec.pageTitle,
        ).firstBaseline;
    expect(title.top, greaterThanOrEqualTo(header.top));
    expect(baseline, lessThanOrEqualTo(header.bottom - 2));
  });

  testWidgets('the header buttons reach the edge and the title', (
    tester,
  ) async {
    final t = await _openList(tester);
    await _openPage(tester, _third);
    // Left of the pencil, over the title's empty end.
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    final y = tester.getCenter(find.bySemanticsLabel('Rename')).dy;
    await tester.tapAt(Offset(width - Spec.pageRenameFromRight - 26, y));
    await tester.pumpAndSettle();
    expect(find.byType(EditableText), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    // At the screen's right edge, beside the trash can.
    await tester.tapAt(Offset(width - 2, y));
    await tester.pumpAndSettle();
    expect(find.text('Are you sure to delete file? /$_third'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(t.store.shared, isEmpty);
  });

  testWidgets("while recording, the page doesn't play", (tester) async {
    useReferenceDevice(tester);
    final t = await pumpReferenceApp(tester);
    final app = t.controller;
    await tester.tap(labeled('Record'));
    await pumpUntil(tester, () => app.isRecording && !app.isBusy);
    // pumpAndSettle can't be used while the microphone light pulses.
    Future<void> wait() async {
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
    }

    await tester.tap(labeled('Recording list'));
    await wait();
    await tester.tap(find.text(_kris));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(RecordingScreen), findsOneWidget);
    // Not even tried: no "can't play" on opening.
    expect(find.text("Can't play while recording"), findsNothing);
    await wait();
    expect(t.playback.played, isEmpty);

    for (final control in ['Play', 'Forward 10 seconds', 'Position']) {
      await tester.tap(_control(control));
      await tester.pump();
      expect(
        find.text("Can't play while recording"),
        findsOneWidget,
        reason: control,
      );
      await tester.pump(const Duration(seconds: 3));
    }
    expect(t.playback.fileId, isNull);
    expect(t.playback.seeks, 0);

    await tester.tap(labeled('Back'));
    await wait();
    await tester.tap(labeled('Back'));
    await wait();
    await tester.tap(labeled('Stop recording'));
    await pumpUntil(tester, () => !app.isRecording && !app.isBusy);
    await tester.pumpAndSettle();
  });
}
