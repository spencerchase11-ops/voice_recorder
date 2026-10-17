// Renders the four App Store screenshots (docs/app-store) as 1290 x 2796
// iPhone screens with neutral sample recordings. Skipped unless asked for:
//
//   flutter test test/tool/app_store_screenshots_test.dart \
//     --dart-define=SHOTS_OUT=/absolute/output/dir
//
// then convert each PNG to docs/app-store/<name>.jpg (sips -s format jpeg
// -s formatOptions 90). Order on the store: recording, playing, list,
// Recently deleted.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_recorder/src/app.dart';
import 'package:voice_recorder/src/app_controller.dart';
import 'package:voice_recorder/src/core/recording_file.dart';
import 'package:voice_recorder/src/core/settings.dart';
import 'package:voice_recorder/src/platform/native_bridge.dart';
import 'package:voice_recorder/src/ui/screens/recently_deleted_screen.dart';
import 'package:voice_recorder/src/ui/screens/recording_list_screen.dart';

import '../support/fakes.dart';
import '../support/harness.dart';
import '../support/ui.dart';

const out = String.fromEnvironment('SHOTS_OUT');
const skip = out == '' ? 'renders screenshots only with SHOTS_OUT' : null;

class IosStore extends FakeStore {
  IosStore({super.files, super.free});
  @override
  String get folderDisplayPath => 'On My iPhone/Voice Recorder/Recorders';
}

RecordingFile rec(String name, DateTime t, int kb, Duration d) => RecordingFile(
  id: 'mem://$name',
  name: name,
  size: kb * 1024 + 300,
  modified: t,
  recorded: t,
  duration: d,
);

Duration hms(int h, int m, int s) => Duration(hours: h, minutes: m, seconds: s);

List<RecordingFile> sampleRecordings({bool trashTwo = false}) {
  // Recently deleted counts the days left from the real clock, so these were
  // "just deleted" to show 30 days left. (The published screenshot, rendered
  // on 2026-09-26, shows that date.)
  final deleted = DateTime.now()
      .subtract(const Duration(minutes: 10))
      .millisecondsSinceEpoch;
  String maybeTrash(String name) =>
      trashTwo ? '${TrashedRecording.prefix}$deleted-$name' : name;
  return [
    rec(
      'Team meeting notes.mp3',
      DateTime(2026, 9, 23, 10),
      39819,
      hms(0, 33, 57),
    ),
    rec(
      '2026_09_22_18_02_11.mp3',
      DateTime(2026, 9, 22, 18, 2, 11),
      14020,
      hms(0, 11, 57),
    ),
    rec('Lecture - week 3.mp3', DateTime(2026, 9, 21, 9), 71230, hms(1, 0, 47)),
    rec('Guitar idea.mp3', DateTime(2026, 9, 20, 21), 2210, hms(0, 1, 53)),
    rec(
      '2026_09_20_09_15_42.mp3',
      DateTime(2026, 9, 20, 9, 15, 42),
      5911,
      hms(0, 5, 2),
    ),
    rec(
      'Podcast interview.mp3',
      DateTime(2026, 9, 19, 15),
      52380,
      hms(0, 44, 41),
    ),
    rec(
      '2026_09_18_12_00_26.mp3',
      DateTime(2026, 9, 18, 12, 0, 26),
      24120,
      hms(0, 20, 35),
    ),
    rec(
      maybeTrash('2026_09_17_09_27_00.mp3'),
      DateTime(2026, 9, 17, 9, 27),
      8081,
      hms(0, 6, 53),
    ),
    rec(
      maybeTrash('Grocery list.mp3'),
      DateTime(2026, 9, 17, 8),
      640,
      hms(0, 0, 32),
    ),
    rec('Birthday song.mp3', DateTime(2026, 9, 16, 20), 3120, hms(0, 2, 39)),
  ];
}

class Shot {
  Shot(this.controller, this.engine, this.playback);
  final AppController controller;
  final FakeEngine engine;
  final FakePlayback playback;
}

Future<Shot> pumpShotApp(
  WidgetTester tester, {
  String? current,
  bool trashTwo = false,
}) async {
  // An iPhone at 3x: 59 pt status bar, 34 pt home indicator.
  tester.view.physicalSize = const Size(1290, 2796);
  tester.view.devicePixelRatio = 3;
  const padding = FakeViewPadding(top: 59 * 3, bottom: 34 * 3);
  tester.view.padding = padding;
  tester.view.viewPadding = padding;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({
    'last_file': ?current,
    'last_duration_ms': const Duration(minutes: 33, seconds: 57).inMilliseconds,
  });
  const channel = MethodChannel('com.spencerchase.voicerecorder/native');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async => null);
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  final work = await tester.runAsync(
    () => Directory.systemTemp.createTemp('vr_shots'),
  );
  addTearDown(() => tester.runAsync(() => work!.delete(recursive: true)));
  final settings = (await tester.runAsync(Settings.load))!;
  // "Remaining time: 656:10:32" at 160 kbps.
  final store = IosStore(
    files: sampleRecordings(trashTwo: trashTwo),
    free: (656 * 3600 + 10 * 60 + 32) * 20000,
  );
  final engine = FakeEngine();
  final playback = FakePlayback();
  final controller = AppController(
    settings: settings,
    store: store,
    engine: engine,
    playback: playback,
    native: NativeBridge(),
    workDir: () async => work!,
    clock: () => DateTime(2026, 9, 26, 1, 30, 24),
  );
  await tester.runAsync(controller.init);
  await tester.pumpWidget(VoiceRecorderApp(controller: controller));
  await precacheImages(tester);
  await tester.pumpAndSettle();
  return Shot(controller, engine, playback);
}

Future<void> snap(WidgetTester tester, String name) async {
  autoUpdateGoldenFiles = true;
  try {
    await expectLater(
      find.byType(WidgetsApp),
      matchesGoldenFile(Uri.file('$out/$name.png')),
    );
  } finally {
    autoUpdateGoldenFiles = false;
  }
}

Future<void> push(WidgetTester tester, Widget screen) async {
  tester
      .state<NavigatorState>(find.byType(Navigator))
      .push(PageRouteBuilder<void>(pageBuilder: (_, _, _) => screen));
  await tester.pumpAndSettle();
}

void main() {
  final ios = TargetPlatformVariant.only(TargetPlatform.iOS);

  testWidgets(
    '1-recording',
    (tester) async {
      final s = await pumpShotApp(
        tester,
        current: 'mem://Team meeting notes.mp3',
      );
      await tester.tap(labeled('Record'));
      await pumpUntil(
        tester,
        () => s.controller.isRecording && !s.controller.isBusy,
      );
      // The timer is a real stopwatch: about 7 s.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 7400)),
      );
      s.engine.levelController.add(7 / 9);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await snap(tester, '1-recording');
      await tester.tap(labeled('Stop recording'));
      await pumpUntil(
        tester,
        () => !s.controller.isRecording && !s.controller.isBusy,
      );
    },
    variant: ios,
    skip: skip != null,
  );

  testWidgets(
    '2-playing',
    (tester) async {
      final s = await pumpShotApp(
        tester,
        current: 'mem://Team meeting notes.mp3',
      );
      await tester.tap(labeled('Play'));
      await tester.pump(const Duration(milliseconds: 300));
      s.playback.setPosition(const Duration(minutes: 12, seconds: 48));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await snap(tester, '2-playing');
    },
    variant: ios,
    skip: skip != null,
  );

  testWidgets(
    '3-recording-list',
    (tester) async {
      final s = await pumpShotApp(tester);
      await push(
        tester,
        const RecordingListScreen(
          initialSelection: 'mem://Lecture - week 3.mp3',
        ),
      );
      final lecture = s.controller.files.firstWhere(
        (f) => f.name.startsWith('Lecture'),
      );
      await tester.runAsync(() => s.controller.togglePlay(lecture));
      s.playback.setPosition(const Duration(minutes: 1, seconds: 12));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await snap(tester, '3-recording-list');
    },
    variant: ios,
    skip: skip != null,
  );

  testWidgets(
    '4-recently-deleted',
    (tester) async {
      await pumpShotApp(tester, trashTwo: true);
      await push(tester, const RecentlyDeletedScreen());
      await snap(tester, '4-recently-deleted');
    },
    variant: ios,
    skip: skip != null,
  );
}
