// The screens and dialogs at iPhone's largest accessibility text size, and
// for screen readers.
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_recorder/src/core/recording_file.dart';
import 'package:voice_recorder/src/ui/dialogs/dialogs.dart';
import 'package:voice_recorder/src/ui/icons/app_icons.dart';
import 'package:voice_recorder/src/ui/screens/recording_list_screen.dart';
import 'package:voice_recorder/src/ui/widgets/frame.dart';
import 'package:voice_recorder/src/ui/widgets/red_bars.dart';
import 'package:voice_recorder/src/ui/widgets/toast.dart';

import '../support/fakes.dart';
import '../support/harness.dart';
import '../support/ui.dart';

/// iPhone's largest accessibility size.
const _largest = 3.1;

Future<TestApp> _pump(WidgetTester tester) async {
  useReferenceDevice(tester);
  tester.platformDispatcher.textScaleFactorTestValue = _largest;
  return pumpReferenceApp(tester);
}

/// A narrow phone (320 wide), where the titles at 2x are wider than the
/// room between the header's buttons.
void _useNarrowPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(960, 1704);
  tester.view.devicePixelRatio = 3;
}

/// The header's [title] keeps clear of its buttons and icons.
void _expectTitleClear(WidgetTester tester, String title) {
  final text = find.descendant(
    of: find.byType(RedHeader),
    matching: find.text(title),
  );
  expect(text, findsOneWidget, reason: title);
  expect(MediaQuery.textScalerOf(tester.element(text)).scale(10), 20);
  final rect = tester.getRect(text);
  final header = find.ancestor(of: text, matching: find.byType(RedHeader));
  final children = tester.widget<RedHeader>(header).children;
  expect(children, isNotEmpty, reason: title);
  // The room kept for the title (however long it gets) has no icon in it.
  final inset = tester.widget<RedHeader>(header).titleInset;
  final bar = tester.getRect(header);
  for (final c in children) {
    // A button's icon (its touch area may reach further).
    final drawn = c is BarButton
        ? find.descendant(of: find.byWidget(c), matching: find.byType(Opacity))
        : find.byWidget(c);
    final icon = tester.getRect(drawn);
    // Not just clear: a gap like a space between words.
    final gap = icon.center.dx < rect.center.dx
        ? rect.left - icon.right
        : icon.left - rect.right;
    expect(gap, greaterThanOrEqualTo(6), reason: '"$title" $gap from $icon');
    final reach = icon.center.dx < bar.center.dx
        ? icon.right - bar.left
        : bar.right - icon.left;
    expect(reach, lessThanOrEqualTo(inset), reason: '"$title" room has $icon');
    expect(rect.overlaps(icon), isFalse, reason: '"$title" over $icon');
  }
  expect(rect.left, greaterThanOrEqualTo(0));
  final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
  expect(rect.right, lessThanOrEqualTo(width));
}

/// From Settings (the row may be below the screen).
Future<void> _openRecentlyDeleted(WidgetTester tester) async {
  final row = find.text('Recently deleted');
  await tester.scrollUntilVisible(
    row,
    100,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets("the headers' titles keep clear of their buttons", (
    tester,
  ) async {
    _useNarrowPhone(tester);
    await _pump(tester);
    _useNarrowPhone(tester);
    await tester.pumpAndSettle();
    _expectTitleClear(tester, 'Recorder');

    await tester.tap(labeled('Recording list'));
    await tester.pumpAndSettle();
    _expectTitleClear(tester, 'Recording list');

    await tester.longPress(find.text('kris n evan got back then zach.mp3'));
    await tester.pumpAndSettle();
    _expectTitleClear(tester, '1 selected');
    await tester.tap(labeled('Cancel selection'));
    await tester.pumpAndSettle();

    await tester.tap(labeled('Back'));
    await tester.pumpAndSettle();
    await tester.tap(labeled('Settings'));
    await tester.pumpAndSettle();
    _expectTitleClear(tester, 'Voice Recorder');

    await _openRecentlyDeleted(tester);
    _expectTitleClear(tester, 'Recently deleted');
  });

  testWidgets("the search field's hint is whole at 2x on a narrow phone", (
    tester,
  ) async {
    await _pump(tester);
    _useNarrowPhone(tester);
    await tester.pumpAndSettle();
    await tester.tap(labeled('Recording list'));
    await tester.pumpAndSettle();
    await tester.tap(labeled('Search'));
    await tester.pumpAndSettle();
    const hint = 'Search by name or date';
    final text = find.text(hint);
    expect(text, findsOneWidget);
    expect(MediaQuery.textScalerOf(tester.element(text)).scale(10), 20);
    final paragraph = tester.renderObject<RenderParagraph>(text);
    expect(paragraph.didExceedMaxLines, isFalse);
    // Smaller, inside the field.
    final field = tester.getRect(find.byType(EditableText));
    final drawn = tester.getRect(text);
    expect(drawn.left, greaterThanOrEqualTo(field.left - 0.01));
    expect(drawn.right, lessThanOrEqualTo(field.right + 0.01));
    // A screen reader still hears it whole.
    expect(find.bySemanticsLabel(RegExp(hint)), findsWidgets);
  });

  for (final width in [320.0, 375.0]) {
    testWidgets(
      'typed in the search field at 2x, ${width.round()} wide, nothing is cut',
      (tester) async {
        await _pump(tester);
        tester.view.physicalSize = Size(width * 3, 1704);
        tester.view.devicePixelRatio = 3;
        await tester.pumpAndSettle();
        await tester.tap(labeled('Recording list'));
        await tester.pumpAndSettle();
        await tester.tap(labeled('Search'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(EditableText), 'gypsy');
        await tester.pumpAndSettle();
        final editable = tester.allRenderObjects
            .whereType<RenderEditable>()
            .single;
        // (Asked outside a layout: allowed as while checking intrinsics.)
        RenderObject.debugCheckingIntrinsics = true;
        final double baseline;
        try {
          baseline =
              editable.localToGlobal(Offset.zero).dy +
              editable.getDistanceToBaseline(TextBaseline.alphabetic)!;
        } finally {
          RenderObject.debugCheckingIntrinsics = false;
        }
        final header = tester.getRect(find.byType(RedHeader).first);
        // The tails of g, y and p (about 0.21 em below the line) are in
        // the header: the text is 18 at 2x.
        expect(baseline + 0.21 * 36, lessThanOrEqualTo(header.bottom));
      },
    );
  }

  for (final scale in [2.0, _largest]) {
    testWidgets("at ${scale}x, the tabs' labels keep below their icons", (
      tester,
    ) async {
      useReferenceDevice(tester);
      tester.view.physicalSize = const Size(1179, 2556); // 393 wide
      tester.view.devicePixelRatio = 3;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      await pumpReferenceApp(tester);
      for (final label in ['Recorder', 'Recording list', 'Settings']) {
        final tab = labeled(label);
        final text = find.descendant(of: tab, matching: find.text(label));
        final icon = find.descendant(of: tab, matching: find.byType(InkIcon));
        expect(
          tester.getRect(text).top,
          greaterThanOrEqualTo(tester.getRect(icon).bottom - 0.01),
          reason: label,
        );
      }
    });
  }

  testWidgets("the open row's controls stay on a narrow phone", (tester) async {
    final t = await _pump(tester);
    _useNarrowPhone(tester);
    await tester.pumpAndSettle();
    const name = 'kris n evan got back then zach.mp3';
    final file = referenceRecordings().firstWhere((f) => f.name == name);
    await tester.runAsync(() => t.controller.seek(file, 0));
    // An overnight recording, far along.
    t.playback.setPosition(const Duration(hours: 10, minutes: 2, seconds: 3));
    await openListAt(tester, name);
    expect(find.text('10:02:03'), findsOneWidget);
    expect(
      tester.getRect(labeled('Forward 10 seconds')).right,
      lessThanOrEqualTo(320),
    );
  });

  /// The first row's second line keeps two thirds for [main] (the date),
  /// [side] (the size, the days left) drawn smaller in the rest.
  void expectDetailLine(WidgetTester tester, Finder main, Finder side) {
    final m = tester.getRect(main.first);
    final s = tester.getRect(side.first);
    final line = s.right - m.left;
    expect(s.width, lessThanOrEqualTo(line / 3 + 0.5));
    expect(tester.getSize(main.first).width, greaterThan(line * 2 / 3 - 9));
  }

  testWidgets("a row's date keeps most of its line at the largest text", (
    tester,
  ) async {
    useReferenceDevice(tester);
    tester.view.physicalSize = const Size(1125, 2436); // 375 wide
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = _largest;
    final t = await pumpReferenceApp(tester);
    await tester.tap(labeled('Recording list'));
    await tester.pumpAndSettle();
    expectDetailLine(
      tester,
      find.textContaining('2026-09-23'),
      find.text('39819KB'),
    );

    await tester.runAsync(() => t.controller.delete([t.controller.files[1]]));
    await tester.tap(labeled('Back'));
    await tester.pumpAndSettle();
    await tester.tap(labeled('Settings'));
    await tester.pumpAndSettle();
    await _openRecentlyDeleted(tester);
    expectDetailLine(
      tester,
      find.textContaining('Deleted '),
      find.textContaining('days left'),
    );
    await tester.pump(const Duration(seconds: 5));
  });

  // The dates are drawn smaller where they wouldn't fit, never cut.
  for (final (wide, scale, bold) in [
    (375.0, _largest, false),
    (320.0, _largest, true),
    (320.0, 2.0, true),
  ]) {
    testWidgets(
      'at ${scale}x, $wide wide${bold ? ', bold' : ''}, the dates are whole',
      (tester) async {
        useReferenceDevice(tester);
        tester.view.physicalSize = Size(wide * 3, 2436);
        tester.view.devicePixelRatio = 3;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            FakeAccessibilityFeatures(boldText: bold);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        final t = await pumpReferenceApp(tester);
        await tester.tap(labeled('Recording list'));
        await tester.pumpAndSettle();
        void expectWhole(Finder text) {
          expect(text, findsWidgets);
          final p = tester.renderObject<RenderParagraph>(
            find.descendant(of: text.first, matching: find.byType(RichText)),
          );
          expect(p.didExceedMaxLines, isFalse, reason: p.text.toPlainText());
        }

        expectWhole(find.textContaining('2026-09-23'));
        await tester.runAsync(
          () => t.controller.delete([t.controller.files[1]]),
        );
        await tester.tap(labeled('Back'));
        await tester.pumpAndSettle();
        await tester.tap(labeled('Settings'));
        await tester.pumpAndSettle();
        await _openRecentlyDeleted(tester);
        expectWhole(find.textContaining('Deleted '));
        await tester.pump(const Duration(seconds: 5));
      },
    );
  }

  testWidgets("the toasts' and Settings summaries' text is at most 2x", (
    tester,
  ) async {
    useReferenceDevice(tester);
    _useNarrowPhone(tester);
    tester.platformDispatcher.textScaleFactorTestValue = _largest;
    await pumpReferenceApp(tester);
    await tester.tap(labeled('Recording list'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2026_09_18_21_23_04.mp3'));
    await tester.pumpAndSettle();
    await tester.tap(labeled('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    double scale(Finder f) =>
        MediaQuery.textScalerOf(tester.element(f)).scale(10);
    expect(scale(find.text('Moved to Recently deleted')), 20);
    showToast(tester.element(find.byType(RecordingListScreen)), 'Saved');
    await tester.pump();
    expect(scale(find.text('Saved')), 20);
    await waitOutUndo(tester);
    await tester.tap(labeled('Back'));
    await tester.pumpAndSettle();
    await tester.tap(labeled('Settings'));
    await tester.pumpAndSettle();
    expect(scale(find.text('Filters out background noise')), 20);
    // The titles keep the full size.
    expect(scale(find.text('Noise reduction')), 31);
  });

  testWidgets('a big recording at the largest bold text fits its row', (
    tester,
  ) async {
    useReferenceDevice(tester);
    tester.view.physicalSize = const Size(960, 1704); // 320 wide
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = _largest;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(boldText: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await pumpReferenceApp(
      tester,
      files: [
        RecordingFile(
          id: 'mem://overnight.wav',
          name: 'overnight.wav',
          size: 1205632 * 1024,
          modified: DateTime(2026, 9, 23, 7),
        ),
      ],
      current: null,
    );
    await tester.tap(labeled('Recording list'));
    await tester.pumpAndSettle();
    expectDetailLine(
      tester,
      find.textContaining('2026-09-23'),
      find.text('1205632KB'),
    );
  });

  testWidgets('a title too wide for the room left is drawn smaller', (
    tester,
  ) async {
    useReferenceDevice(tester);
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: PlainText(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: RedHeader(
                title: 'A title far too long for this header to hold',
                titleInset: 50,
              ),
            ),
          ),
        ),
      ),
    );
    final rect = tester.getRect(find.byType(Text));
    expect(rect.left, greaterThanOrEqualTo(50 - 0.01));
    expect(rect.right, lessThanOrEqualTo(250 + 0.01));
    // Whole: smaller, not cut short.
    final paragraph = tester.renderObject<RenderParagraph>(find.byType(Text));
    expect(paragraph.didExceedMaxLines, isFalse);
  });

  testWidgets('on iPhone, the Settings title keeps clear of Back', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await _pump(tester);
      _useNarrowPhone(tester);
      await tester.pumpAndSettle();
      await tester.tap(labeled('Settings'));
      await tester.pumpAndSettle();
      _expectTitleClear(tester, 'Voice Recorder');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets("a choice dialog's text is at most 2x, a long choice whole", (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(labeled('Recording list'));
    await tester.pumpAndSettle();
    const long = 'A folder, with all its recordings';
    showChoiceDialog(
      tester.element(find.byType(RecordingListScreen)),
      title: 'Import recordings',
      items: const [long, 'Single recordings'],
      selected: -1,
    );
    await tester.pumpAndSettle();

    final text = find.text(long);
    expect(MediaQuery.textScalerOf(tester.element(text)).scale(10), 20);
    // The title is whole too, drawn smaller.
    expect(
      tester
          .renderObject<RenderParagraph>(find.text('Import recordings'))
          .didExceedMaxLines,
      isFalse,
    );
    final paragraph = tester.renderObject<RenderParagraph>(text);
    expect(paragraph.didExceedMaxLines, isFalse);
    // Wrapped, its row grows to hold it.
    final row = tester.getRect(
      find.ancestor(of: text, matching: find.byType(PressableArea)).first,
    );
    final drawn = tester.getRect(text);
    expect(drawn.height, greaterThan(48));
    expect(row.top, lessThanOrEqualTo(drawn.top));
    expect(row.bottom, greaterThanOrEqualTo(drawn.bottom));

    await tester.tap(find.text('Single recordings'));
    await tester.pumpAndSettle();
  });

  // A screen reader hears a toast once: announced where the platform can,
  // a live region where it can't.
  for (final announce in [true, false]) {
    testWidgets('a toast is heard once (${announce ? 'iOS' : 'Android'})', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures(supportsAnnounce: announce);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      useReferenceDevice(tester);
      await pumpReferenceApp(tester);
      final ctx = tester.element(find.byType(Navigator).first);
      tester.takeAnnouncements();
      showToast(ctx, 'Saved');
      showActionToast(ctx, 'Moved', action: 'Undo', onAction: () {});
      await tester.pump();
      expect(
        tester.takeAnnouncements().map((a) => a.message),
        announce ? ['Saved', 'Moved'] : isEmpty,
      );
      for (final text in ['Saved', 'Moved']) {
        expect(
          tester.getSemantics(find.bySemanticsLabel(text)),
          announce
              ? isNot(isSemantics(isLiveRegion: true))
              : isSemantics(isLiveRegion: true),
          reason: text,
        );
      }
      hideActionToast();
      await waitOutUndo(tester);
    });
  }

  // Both toasts, either one first: the plain one keeps above the other.
  for (final plainFirst in [false, true]) {
    testWidgets(
      'at 2x, toasts shown together keep apart${plainFirst ? ' (plain first)' : ''}',
      (tester) async {
        useReferenceDevice(tester);
        tester.view.physicalSize = const Size(1179, 2556); // 393 wide
        tester.view.devicePixelRatio = 3;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        await pumpReferenceApp(tester);
        final ctx = tester.element(find.byType(Navigator).first);
        void undo() => showActionToast(
          ctx,
          '2 recordings moved to Recently deleted',
          action: 'Undo',
          onAction: () {},
        );
        if (!plainFirst) {
          undo();
          await tester.pump();
        }
        showToast(ctx, 'Please select a file');
        await tester.pump();
        if (plainFirst) {
          undo();
          await tester.pump();
          await tester.pump();
        }
        Rect box(String text) => tester.getRect(
          find
              .ancestor(of: find.text(text), matching: find.byType(Container))
              .first,
        );
        final plain = box('Please select a file');
        final action = box('2 recordings moved to Recently deleted');
        expect(
          plain.bottom,
          lessThanOrEqualTo(action.top),
          reason: '$plain $action',
        );
        hideActionToast();
        await waitOutUndo(tester);
      },
    );
  }

  testWidgets("a job's first change is read out (copying starts, Cancel)", (
    tester,
  ) async {
    await _pump(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    String heard() => tester
        .getSemantics(find.bySemanticsLabel(RegExp('^Looking|^Copying|^Stop')))
        .label;
    Future<ProgressDialogRoute> open(ValueNotifier<JobState> state) async {
      final route = ProgressDialogRoute(
        title: 'Importing',
        state: state,
        label: (s) => s.total == 0
            ? 'Looking for recordings…'
            : 'Copying ${s.done} of ${s.total} recordings…',
        onCancel: () {},
      );
      navigator.push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      return route;
    }

    // Done looking: copying is said at once, not a tenth in.
    var state = ValueNotifier<JobState>((done: 0, total: 0));
    var route = await open(state);
    expect(heard(), 'Looking for recordings…');
    state.value = (done: 0, total: 200);
    await tester.pump();
    expect(heard(), 'Copying 0 of 200 recordings…');
    navigator.removeRoute(route);
    await tester.pumpAndSettle();

    // Cancel before anything has been done.
    for (final total in [0, 25]) {
      state = ValueNotifier<JobState>((done: 0, total: total));
      route = await open(state);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(heard(), 'Stopping…', reason: '$total');
      navigator.removeRoute(route);
      await tester.pumpAndSettle();
    }
  });

  testWidgets('a long job is read out by tenths, not every recording', (
    tester,
  ) async {
    await _pump(tester);
    final state = ValueNotifier<JobState>((done: 0, total: 60));
    final route = ProgressDialogRoute(
      title: 'Deleting',
      state: state,
      label: (s) => 'Moving ${s.done} of ${s.total}',
      onCancel: () {},
    );
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    String heard() => tester
        .getSemantics(find.bySemanticsLabel(RegExp('^Moving|^Stopping')))
        .label;
    final said = <String>{heard()};
    for (var done = 1; done <= 60; done++) {
      state.value = (done: done, total: 60);
      await tester.pump();
      said.add(heard());
      // What shows follows every recording.
      expect(find.text('Moving $done of 60'), findsOneWidget);
    }
    expect(said.length, 11, reason: '$said');
    expect(said, contains('Moving 6 of 60'));
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(heard(), 'Stopping…');
    navigator.removeRoute(route);
    await tester.pumpAndSettle();
  });

  testWidgets("at 2x on a narrow phone, a dialog's buttons keep every word", (
    tester,
  ) async {
    useReferenceDevice(tester);
    _useNarrowPhone(tester);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(boldText: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await pumpReferenceApp(tester);
    final ctx = tester.element(find.byType(Navigator).first);
    showConfirmDialog(
      ctx,
      title: 'Restore all',
      message: 'Restore all recordings?',
      ok: 'Restore all',
    );
    await tester.pumpAndSettle();
    final label = find.descendant(
      of: find.byType(HoloButton),
      matching: find.text('Restore all'),
    );
    final p = tester.renderObject<RenderParagraph>(
      find.descendant(of: label, matching: find.byType(RichText)),
    );
    expect(p.didExceedMaxLines, isFalse);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets("a progress dialog's text is at most 2x", (tester) async {
    await _pump(tester);
    final state = ValueNotifier<JobState>((done: 1, total: 3));
    final route = ProgressDialogRoute(
      title: 'Deleting',
      state: state,
      label: (s) => '${s.done} of ${s.total}',
    );
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final text = find.text('Deleting');
    expect(MediaQuery.textScalerOf(tester.element(text)).scale(10), 20);
    navigator.removeRoute(route);
    await tester.pumpAndSettle();
  });

  testWidgets(
    "the list's empty text scrolls when it's longer than the screen",
    (tester) async {
      useReferenceDevice(tester);
      // A small phone, at the largest text.
      tester.view.physicalSize = const Size(1080, 1680);
      tester.view.devicePixelRatio = 3;
      tester.platformDispatcher.textScaleFactorTestValue = _largest;
      await pumpReferenceApp(tester, files: [], current: null);
      await tester.tap(labeled('Recording list'));
      await tester.pumpAndSettle();
      final text = find.textContaining('No recordings in this folder yet');
      final before = tester.getRect(text);
      // From its first line: the rest is below the screen.
      await tester.dragFrom(
        Offset(before.center.dx, before.top + 20),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(text).top, lessThan(before.top - 100));
    },
  );

  testWidgets("Recently deleted's empty text scrolls too", (tester) async {
    useReferenceDevice(tester);
    tester.view.physicalSize = const Size(1080, 1680);
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = _largest;
    await pumpReferenceApp(tester, files: []);
    await tester.tap(labeled('Settings'));
    await tester.pumpAndSettle();
    await _openRecentlyDeleted(tester);
    final text = find.textContaining('No recently deleted recordings.');
    final before = tester.getRect(text);
    await tester.dragFrom(
      Offset(before.center.dx, before.top + 20),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(text).top, lessThan(before.top - 100));
  });

  testWidgets('screen readers hear which choice is the current one', (
    tester,
  ) async {
    useReferenceDevice(tester);
    await pumpReferenceApp(tester);
    await tester.tap(labeled('Recording list'));
    await tester.pumpAndSettle();
    await tester.tap(labeled('Sort'));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.bySemanticsLabel('Newest first')),
      isSemantics(isButton: true, isSelected: true),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Oldest first')),
      isSemantics(isButton: true, isSelected: false),
    );
    await tester.tap(find.text('Newest first'));
    await tester.pumpAndSettle();
  });
}
