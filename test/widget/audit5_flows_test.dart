// The screens after the fifth audit: a notice the "Record" shortcut used to
// close, the folder question at start-up, the Undo toast next to Recently
// deleted, large text, and seeking while a recording is saved.
import 'dart:async';
import 'dart:io';

import 'package:flutter/rendering.dart' show RenderParagraph, SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_recorder/src/app.dart';
import 'package:voice_recorder/src/app_controller.dart';
import 'package:voice_recorder/src/audio/recorder_engine.dart';
import 'package:voice_recorder/src/core/recording_file.dart';
import 'package:voice_recorder/src/core/settings.dart';
import 'package:voice_recorder/src/platform/native_bridge.dart';
import 'package:voice_recorder/src/ui/screens/recording_list_screen.dart';
import 'package:voice_recorder/src/ui/widgets/red_bars.dart';

import '../support/fakes.dart';
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

/// Answers the app's native calls with nothing, except the home-screen
/// shortcut: [launch] once, when set.
class _Shortcut {
  _Shortcut() {
    const channel = MethodChannel('com.spencerchase.voicerecorder/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'takeLaunchAction') return null;
      final a = launch;
      launch = null;
      return a;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  String? launch;
}

/// The app leaving (Home, or the screen locked) and coming back, through
/// the same lifecycle events as on the phone.
void _leave(WidgetTester tester) {
  tester.binding
    ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
    ..handleAppLifecycleStateChanged(AppLifecycleState.hidden);
}

void _comeBack(WidgetTester tester) {
  tester.binding
    ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
    ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

/// Like the Android store as the app starts: the folder chosen earlier is
/// known only once [init] has checked that it can still be reached.
class _StartingStore extends FakeStore {
  _StartingStore()
    : super(files: referenceRecordings(), free: referenceFreeBytes) {
    ready = false;
  }

  /// Completed with whether the folder can still be reached.
  final access = Completer<bool>();
  var initStarted = false;

  @override
  Future<void> init() async {
    initStarted = true;
    ready = await access.future;
  }
}

/// Builds the app like [pumpReferenceApp], but shows it while the
/// controller is still starting (as main() does). Returns the controller and
/// a check for whether its start has finished.
Future<(AppController, bool Function())> _pumpStarting(
  WidgetTester tester,
  FakeStore store,
) async {
  SharedPreferences.setMockInitialValues({});
  const channel = MethodChannel('com.spencerchase.voicerecorder/native');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async => null);
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  final work = await tester.runAsync(
    () => Directory.systemTemp.createTemp('vr_test'),
  );
  addTearDown(() => tester.runAsync(() => work!.delete(recursive: true)));
  final settings = (await tester.runAsync(Settings.load))!;
  final controller = AppController(
    settings: settings,
    store: store,
    engine: FakeEngine(),
    playback: FakePlayback(),
    native: NativeBridge(),
    workDir: () async => work!,
  );
  var started = false;
  unawaited(controller.init().then((_) => started = true));
  await tester.pumpWidget(VoiceRecorderApp(controller: controller));
  await precacheImages(tester);
  return (controller, () => started);
}

Future<TestApp> _deleteOneThenOpenRecentlyDeleted(WidgetTester tester) async {
  useReferenceDevice(tester);
  final t = await pumpReferenceApp(tester, files: _many(3), current: null);
  await _deleteThenOpenRecentlyDeleted(tester, ['2026_09_01_10_02_00.mp3']);
  return t;
}

/// Deletes [names] from the list one at a time, then opens Recently deleted
/// while the last delete's Undo toast is still up.
Future<void> _deleteThenOpenRecentlyDeleted(
  WidgetTester tester,
  List<String> names,
) async {
  await tester.tap(labeled('Recording list'));
  await tester.pumpAndSettle();
  for (final name in names) {
    await tester.tap(find.text(name));
    await tester.pumpAndSettle();
    await tester.tap(labeled('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Moved to Recently deleted'), findsOneWidget);
  }
  // The Undo toast stays for 6 seconds, above every screen.
  await tester.tap(labeled('Back'));
  await tester.pumpAndSettle();
  await tester.tap(labeled('Settings'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Recently deleted'));
  await tester.pumpAndSettle();
  expect(labeled('Undo'), findsOneWidget);
}

/// Holds the listing of Recently deleted while [hold] is set (a slow
/// folder), so the screen still shows it as it was a moment ago.
class _SlowTrashStore extends FakeStore {
  _SlowTrashStore() : super(files: _many(3), free: referenceFreeBytes);

  Completer<void>? hold;

  @override
  Future<List<TrashedRecording>> listTrash() async {
    await hold?.future;
    return super.listTrash();
  }
}

/// A folder whose files keep their id through a rename (the id isn't the
/// path), whose calls run one at a time in order (like NativePlugin's io
/// executor), and whose renames wait while [hold] is set (a network
/// folder).
class _KeepIdSerialStore extends FakeStore {
  _KeepIdSerialStore() : super(files: _many(3), free: referenceFreeBytes);

  Completer<void>? hold;
  Future<void> _tail = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() op) {
    final c = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        c.complete(await op());
      } catch (e, s) {
        c.completeError(e, s);
      }
    });
    return c.future;
  }

  @override
  Future<RecordingFile?> renameTo(RecordingFile file, String fileName) {
    final h = hold;
    return _serial(() async {
      await h?.future;
      final i = files.indexWhere((f) => f.id == file.id);
      if (i < 0) return null;
      return files[i] = files[i].copyWith(name: fileName);
    });
  }

  @override
  Future<bool> delete(RecordingFile file) => _serial(() async {
    final i = files.indexWhere((f) => f.id == file.id);
    if (i < 0) return false;
    deletedForGood.add(files[i].name);
    files.removeAt(i);
    return true;
  });
}

/// No message says that something couldn't be restored or deleted.
void _expectNoFailure() {
  expect(find.textContaining("Couldn't restore"), findsNothing);
  expect(find.textContaining("couldn't be restored"), findsNothing);
  expect(find.textContaining("Couldn't delete"), findsNothing);
  expect(find.textContaining("couldn't be deleted"), findsNothing);
}

void main() {
  testWidgets('the "Record" shortcut keeps a notice that waited for the '
      'app to come back', (tester) async {
    final shortcut = _Shortcut();
    useReferenceDevice(tester);
    final t = await pumpReferenceApp(tester);
    final app = t.controller;
    await tester.tap(labeled('Record'));
    await pumpUntil(tester, () => app.isRecording && !app.isBusy);

    // The screen is locked; the recording then stops on its own.
    _leave(tester);
    t.engine.endedController.add(CaptureEnd.writeFailed);
    await pumpUntil(tester, () => !app.isRecording && !app.isBusy);

    // Opened again from the home-screen "Record" shortcut.
    shortcut.launch = 'record';
    _comeBack(tester);
    await pumpUntil(tester, () => app.isRecording && !app.isBusy);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.textContaining("The recording stopped: it couldn't be written."),
      findsOneWidget,
    );
    expect(labeled('Stop recording'), findsOneWidget);

    await tester.tap(find.text('OK'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('The recording stopped'), findsNothing);
    await tester.tap(labeled('Stop recording'));
    await pumpUntil(tester, () => !app.isRecording && !app.isBusy);
    await tester.pumpAndSettle();
    expect(t.store.saved, hasLength(2));
  });

  testWidgets("the list opened during start-up doesn't ask for a folder "
      'that is fine', (tester) async {
    useReferenceDevice(tester);
    final store = _StartingStore();
    final (app, started) = await _pumpStarting(tester, store);
    await pumpUntil(tester, () => store.initStarted);
    // Still checking the folder's access when the list opens.
    await tester.tap(labeled('Recording list'));
    await tester.pumpAndSettle();
    expect(find.text('Folder'), findsNothing);

    store.access.complete(true);
    await pumpUntil(tester, started);
    await tester.pumpAndSettle();
    expect(find.text('Folder'), findsNothing);
    expect(app.store.isReady, isTrue);
    expect(find.text('kris n evan got back then zach.mp3'), findsOneWidget);
  });

  testWidgets('the list still asks for a folder that is gone, once the app '
      'has started', (tester) async {
    useReferenceDevice(tester);
    final store = _StartingStore();
    final (_, started) = await _pumpStarting(tester, store);
    await pumpUntil(tester, () => store.initStarted);
    await tester.tap(labeled('Recording list'));
    await tester.pumpAndSettle();
    // No access any more (the user removed it in the system settings).
    store.access.complete(false);
    await pumpUntil(tester, started);
    await tester.pumpAndSettle();
    expect(find.text('Folder'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  group('Recently deleted closes the Undo toast of a delete', () {
    testWidgets('when it restores the recording', (tester) async {
      final t = await _deleteOneThenOpenRecentlyDeleted(tester);
      await tester.tap(find.text('2026_09_01_10_02_00.mp3'));
      await tester.pumpAndSettle();
      await tester.tap(labeled('Restore'));
      await tester.pumpAndSettle();
      expect(find.text('Restored 2026_09_01_10_02_00.mp3'), findsOneWidget);
      // Its Undo would only find the recording gone from here.
      expect(labeled('Undo'), findsNothing);
      await waitOutUndo(tester);
      expect(find.textContaining("couldn't be restored"), findsNothing);
      expect(t.controller.files, hasLength(3));
    });

    testWidgets('when it restores all', (tester) async {
      final t = await _deleteOneThenOpenRecentlyDeleted(tester);
      await tester.tap(labeled('Restore all'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore all').last);
      await tester.pumpAndSettle();
      expect(labeled('Undo'), findsNothing);
      await waitOutUndo(tester);
      expect(find.textContaining("couldn't be restored"), findsNothing);
      expect(t.controller.files, hasLength(3));
    });

    testWidgets('when it deletes the recording forever', (tester) async {
      final t = await _deleteOneThenOpenRecentlyDeleted(tester);
      await tester.tap(find.text('2026_09_01_10_02_00.mp3'));
      await tester.pumpAndSettle();
      await tester.tap(labeled('Delete forever'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(labeled('Undo'), findsNothing);
      await waitOutUndo(tester);
      expect(find.textContaining("couldn't be restored"), findsNothing);
      expect(t.store.deletedForGood, hasLength(1));
    });

    testWidgets('but not when that is cancelled', (tester) async {
      await _deleteOneThenOpenRecentlyDeleted(tester);
      await tester.tap(labeled('Delete all'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(labeled('Undo'), findsOneWidget);
      await waitOutUndo(tester);
    });
  });

  // The Undo toast stays above Recently deleted's questions, and can be
  // tapped while one is up.
  group('Recently deleted, after an Undo tapped during its question,', () {
    testWidgets("doesn't say Restore all failed", (tester) async {
      final t = await _deleteOneThenOpenRecentlyDeleted(tester);
      await tester.tap(labeled('Restore all'));
      await tester.pumpAndSettle();
      await tester.tap(labeled('Undo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore all').last);
      await tester.pumpAndSettle();
      _expectNoFailure();
      expect(
        find.textContaining('No recently deleted recordings'),
        findsOneWidget,
      );
      await waitOutUndo(tester);
      _expectNoFailure();
      expect(t.controller.files, hasLength(3));
    });

    testWidgets("doesn't delete forever what Undo put back", (tester) async {
      final t = await _deleteOneThenOpenRecentlyDeleted(tester);
      await tester.tap(find.text('2026_09_01_10_02_00.mp3'));
      await tester.pumpAndSettle();
      await tester.tap(labeled('Delete forever'));
      await tester.pumpAndSettle();
      await tester.tap(labeled('Undo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      _expectNoFailure();
      await waitOutUndo(tester);
      _expectNoFailure();
      expect(t.store.deletedForGood, isEmpty);
      expect(t.controller.files, hasLength(3));
    });

    testWidgets('deletes all of the rest', (tester) async {
      useReferenceDevice(tester);
      final t = await pumpReferenceApp(tester, files: _many(3), current: null);
      await _deleteThenOpenRecentlyDeleted(tester, [
        '2026_09_01_10_02_00.mp3',
        '2026_09_01_10_01_00.mp3',
      ]);
      await tester.tap(labeled('Delete all'));
      await tester.pumpAndSettle();
      // Puts back the one deleted last.
      await tester.tap(labeled('Undo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete all').last);
      await tester.pumpAndSettle();
      _expectNoFailure();
      await waitOutUndo(tester);
      _expectNoFailure();
      expect(t.store.deletedForGood, hasLength(1));
      expect(t.store.deletedForGood.single, endsWith('10_02_00.mp3'));
      expect(t.controller.files.map((f) => f.name), [
        '2026_09_01_10_01_00.mp3',
        '2026_09_01_10_00_00.mp3',
      ]);
    });

    testWidgets("doesn't restore what Undo put back before the list "
        'showed it', (tester) async {
      useReferenceDevice(tester);
      final store = _SlowTrashStore();
      final (app, started) = await _pumpStarting(tester, store);
      await pumpUntil(tester, started);
      await tester.pumpAndSettle();
      await _deleteThenOpenRecentlyDeleted(tester, ['2026_09_01_10_02_00.mp3']);
      await tester.tap(find.text('2026_09_01_10_02_00.mp3'));
      await tester.pumpAndSettle();
      // Listed again after the Undo, slowly: Restore is tapped meanwhile.
      store.hold = Completer<void>();
      await tester.tap(labeled('Undo'));
      await tester.pump();
      expect(find.text('2026_09_01_10_02_00.mp3'), findsOneWidget);
      await tester.tap(labeled('Restore'));
      await tester.pump();
      store.hold!.complete();
      store.hold = null;
      await tester.pumpAndSettle();
      _expectNoFailure();
      expect(
        find.textContaining('No recently deleted recordings'),
        findsOneWidget,
      );
      await waitOutUndo(tester);
      _expectNoFailure();
      expect(app.files, hasLength(3));
    });
  });

  // A few recordings are put back without a progress dialog: the question
  // can be answered while Undo is still renaming them.
  group('Recently deleted, answered while Undo still puts recordings '
      'back,', () {
    /// Opens Recently deleted after deleting [names], selects [select] (if
    /// given) and taps [question]; taps Undo with its rename held, then
    /// [answer]. The rename goes on after that.
    Future<(AppController, _KeepIdSerialStore)> answerDuringUndo(
      WidgetTester tester, {
      required List<String> names,
      String? select,
      required String question,
      required String answer,
    }) async {
      useReferenceDevice(tester);
      final store = _KeepIdSerialStore();
      final (app, started) = await _pumpStarting(tester, store);
      await pumpUntil(tester, started);
      await tester.pumpAndSettle();
      await _deleteThenOpenRecentlyDeleted(tester, names);
      if (select != null) {
        await tester.tap(find.text(select));
        await tester.pumpAndSettle();
      }
      await tester.tap(labeled(question));
      await tester.pumpAndSettle();
      store.hold = Completer<void>();
      await tester.tap(labeled('Undo'));
      await tester.pump();
      await tester.tap(find.text(answer).last);
      await tester.pump();
      await tester.pump();
      final held = store.hold!;
      store.hold = null;
      held.complete();
      await tester.pumpAndSettle();
      _expectNoFailure();
      return (app, store);
    }

    testWidgets("Delete forever doesn't delete the recording it puts "
        'back', (tester) async {
      final (app, store) = await answerDuringUndo(
        tester,
        names: ['2026_09_01_10_02_00.mp3'],
        select: '2026_09_01_10_02_00.mp3',
        question: 'Delete forever',
        answer: 'Delete',
      );
      await waitOutUndo(tester);
      _expectNoFailure();
      expect(store.deletedForGood, isEmpty);
      expect(store.files.map((f) => f.name), [
        '2026_09_01_10_00_00.mp3',
        '2026_09_01_10_01_00.mp3',
        '2026_09_01_10_02_00.mp3',
      ]);
      expect(app.files, hasLength(3));
    });

    testWidgets('Delete all deletes only the rest', (tester) async {
      final (app, store) = await answerDuringUndo(
        tester,
        // An older one in Recently deleted, then the one Undo is for.
        names: ['2026_09_01_10_00_00.mp3', '2026_09_01_10_02_00.mp3'],
        question: 'Delete all',
        answer: 'Delete all',
      );
      await waitOutUndo(tester);
      _expectNoFailure();
      expect(store.deletedForGood.single, endsWith('-2026_09_01_10_00_00.mp3'));
      expect(store.files.map((f) => f.name), [
        '2026_09_01_10_01_00.mp3',
        '2026_09_01_10_02_00.mp3',
      ]);
      expect(app.files, hasLength(2));
    });

    testWidgets('Restore all restores only the rest', (tester) async {
      final (app, store) = await answerDuringUndo(
        tester,
        names: ['2026_09_01_10_00_00.mp3', '2026_09_01_10_02_00.mp3'],
        question: 'Restore all',
        answer: 'Restore all',
      );
      expect(find.text('Restored 1 recording'), findsOneWidget);
      await waitOutUndo(tester);
      _expectNoFailure();
      expect(store.files.map((f) => f.name).toSet(), {
        '2026_09_01_10_00_00.mp3',
        '2026_09_01_10_01_00.mp3',
        '2026_09_01_10_02_00.mp3',
      });
      expect(app.files, hasLength(3));
    });
  });

  group('large text', () {
    testWidgets('"Remaining time" keeps its number', (tester) async {
      useReferenceDevice(tester);
      // iPhone's largest accessibility size.
      tester.platformDispatcher.textScaleFactorTestValue = 3.1;
      await pumpReferenceApp(tester);
      final text = find.textContaining('Remaining time');
      expect(
        tester.renderObject<RenderParagraph>(text).didExceedMaxLines,
        isFalse,
      );
      final rect = tester.getRect(text);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(
        rect.right,
        lessThanOrEqualTo(tester.view.physicalSize.width / 3.5),
      );
      expect(find.text('Remaining time: 9665:13:10'), findsOneWidget);
    });

    testWidgets("Recently deleted's button labels stay inside the bar", (
      tester,
    ) async {
      useReferenceDevice(tester);
      await pumpReferenceApp(tester, files: _many(3), current: null);
      await tester.tap(labeled('Recording list'));
      await tester.pumpAndSettle();
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
      // Android's largest font size is 2; iPhone's accessibility sizes go
      // beyond.
      tester.platformDispatcher.textScaleFactorTestValue = 2.5;
      await tester.pumpAndSettle();

      void expectInside(String label) {
        final text = tester.getRect(find.text(label));
        final cell = tester.getRect(labeled(label));
        expect(text.bottom, lessThanOrEqualTo(cell.bottom), reason: label);
        expect(text.top, greaterThanOrEqualTo(cell.top), reason: label);
        expect(text.left, greaterThanOrEqualTo(cell.left), reason: label);
        expect(text.right, lessThanOrEqualTo(cell.right), reason: label);
      }

      expectInside('Restore all');
      expectInside('Delete all');
      await tester.tap(find.text('2026_09_01_10_02_00.mp3'));
      await tester.pumpAndSettle();
      expectInside('Restore');
      expectInside('Delete forever');
    });
  });

  testWidgets('seeking while a recording is being saved says why it '
      "can't play", (tester) async {
    useReferenceDevice(tester);
    final t = await pumpReferenceApp(tester);
    final app = t.controller;
    await tester.tap(labeled('Record'));
    await pumpUntil(tester, () => app.isRecording && !app.isBusy);
    // pumpAndSettle can't be used while the microphone light pulses.
    await tester.tap(labeled('Recording list'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    // Its page doesn't play it while recording; back to its open row.
    await tester.tap(find.text('2026_09_20_17_26_27.mp3'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(t.playback.played, isEmpty);
    await tester.tap(labeled('Back'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    // Stopped while the list is open (as from the notification's Stop
    // button). The stop waits for the app's start, which runAsync lets
    // through, then saves the file with real file access, which goes on
    // only in pumpUntil.
    unawaited(app.toggleRecord());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(app.isRecording, isFalse);
    expect(app.isBusy, isTrue);
    await tester.tap(find.byType(HoloSeekBar));
    await tester.pump();
    expect(find.text("Can't play this recording"), findsNothing);
    expect(find.text("Can't play while recording"), findsOneWidget);
    expect(t.playback.seeks, 0);

    await pumpUntil(tester, () => !app.isBusy);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(t.store.saved, hasLength(1));
  });

  group("after a delete from selection, the header's screen-reader frames "
      'are where its buttons are', () {
    /// [label]'s accessibility frame, in logical pixels on the screen.
    Rect frameOf(WidgetTester tester, String label) {
      final node = tester.getSemantics(labeled(label));
      expect(node.label, label);
      var rect = node.rect;
      for (SemanticsNode? n = node; n != null; n = n.parent) {
        final t = n.transform;
        if (t != null) rect = MatrixUtils.transformRect(t, rect);
      }
      final ratio = tester.view.devicePixelRatio;
      return Rect.fromLTRB(
        rect.left / ratio,
        rect.top / ratio,
        rect.right / ratio,
        rect.bottom / ratio,
      );
    }

    void expectFramed(WidgetTester tester, String label) {
      // Frames are clipped to the header, as Back's is at the screen's edge.
      final drawn = tester
          .getRect(labeled(label))
          .intersect(tester.getRect(find.byType(RedHeader)));
      final frame = frameOf(tester, label);
      for (final (a, b) in [
        (frame.left, drawn.left),
        (frame.top, drawn.top),
        (frame.right, drawn.right),
        (frame.bottom, drawn.bottom),
      ]) {
        expect(a, moreOrLessEquals(b, epsilon: 0.01), reason: label);
      }
    }

    Future<void> deleteSelected(WidgetTester tester) async {
      await tester.longPress(find.text('2026_09_01_10_00_00.mp3'));
      await tester.pumpAndSettle();
      await tester.tap(labeled('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
    }

    testWidgets('back to the list', (tester) async {
      final semantics = tester.ensureSemantics();
      useReferenceDevice(tester);
      await pumpReferenceApp(tester, files: _many(3), current: null);
      await tester.tap(labeled('Recording list'));
      await tester.pumpAndSettle();
      await deleteSelected(tester);
      expect(find.text('Recording list'), findsOneWidget);
      for (final label in ['Back', 'Sort', 'Search']) {
        expectFramed(tester, label);
      }
      await waitOutUndo(tester);
      for (final label in ['Back', 'Sort', 'Search']) {
        expectFramed(tester, label);
      }
      semantics.dispose();
    });

    testWidgets('back to a search', (tester) async {
      final semantics = tester.ensureSemantics();
      useReferenceDevice(tester);
      await pumpReferenceApp(tester, files: _many(3), current: null);
      await tester.tap(labeled('Recording list'));
      await tester.pumpAndSettle();
      await tester.tap(labeled('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), '2026');
      await tester.pumpAndSettle();
      await deleteSelected(tester);
      expect(find.byType(EditableText), findsOneWidget);
      expectFramed(tester, 'Back');
      await waitOutUndo(tester);
      expectFramed(tester, 'Back');
      semantics.dispose();
    });
  });
}
