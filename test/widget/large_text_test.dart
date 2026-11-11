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
