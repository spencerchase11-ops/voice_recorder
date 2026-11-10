// A recording's own page, opened by tapping its row in the list.
import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_recorder/src/core/format.dart';
import 'package:voice_recorder/src/ui/screens/recording_screen.dart';
import 'package:voice_recorder/src/ui/widgets/frame.dart';
import 'package:voice_recorder/src/ui/screens/recording_list_screen.dart';

import '../support/harness.dart';
import '../support/ui.dart';

const _kris = 'kris n evan got back then zach.mp3';

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

Future<TestApp> _openList(WidgetTester tester) async {
  useReferenceDevice(tester);
  final t = await pumpReferenceApp(tester);
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
