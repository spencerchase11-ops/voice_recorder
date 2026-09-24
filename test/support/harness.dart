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

import 'fakes.dart';

/// Loads the bundled Roboto family so text renders with real glyphs.
Future<void> loadAppFonts() async {
  final loader = FontLoader('Roboto');
  for (final w in ['Regular', 'Medium', 'Bold']) {
    loader.addFont(rootBundle.load('assets/fonts/Roboto-$w.ttf'));
  }
  await loader.load();
}

/// The phone the reference screenshots were taken on: 1440x3120 px at 3.5x
/// density, a 150 px status bar, a 56 px gesture bar and font scale ~1.077.
void useReferenceDevice(WidgetTester tester) {
  tester.view.physicalSize = const Size(1440, 3120);
  tester.view.devicePixelRatio = 3.5;
  const padding = FakeViewPadding(top: 150, bottom: 56);
  tester.view.padding = padding;
  tester.view.viewPadding = padding;
  tester.platformDispatcher.textScaleFactorTestValue = 1.077;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
}

const imageAssets = [
  'assets/images/brushed_metal.jpg',
  'assets/images/microphone.png',
  'assets/images/record.png',
  'assets/images/record_stop.png',
  'assets/images/play.png',
  'assets/images/pause.png',
  'assets/images/list_play.png',
  'assets/images/list_pause.png',
  'assets/images/app_icon.png',
];

/// Decodes every image so goldens never capture half-loaded frames.
Future<void> precacheImages(WidgetTester tester) async {
  final context = tester.element(find.byType(WidgetsApp).first);
  await tester.runAsync(() async {
    for (final a in imageAssets) {
      await precacheImage(AssetImage(a), context);
    }
  });
  await tester.pump();
}

class TestApp {
  TestApp(
    this.controller,
    this.store,
    this.engine,
    this.playback,
    this.workDir,
  );

  final AppController controller;
  final FakeStore store;
  final FakeEngine engine;
  final FakePlayback playback;
  final Directory workDir;
}

/// Builds the app with fakes in the state shown by the reference screenshots.
Future<TestApp> pumpReferenceApp(
  WidgetTester tester, {
  List<RecordingFile>? files,
  String? current = 'mem://kris n evan got back then zach.mp3',
  Duration lastDuration = const Duration(minutes: 33, seconds: 57),
}) async {
  SharedPreferences.setMockInitialValues({
    'last_file': ?current,
    'last_duration_ms': lastDuration.inMilliseconds,
  });
  final work = await tester.runAsync(
    () => Directory.systemTemp.createTemp('vr_test'),
  );
  addTearDown(() => tester.runAsync(() => work!.delete(recursive: true)));
  final settings = (await tester.runAsync(Settings.load))!;
  final store = FakeStore(
    files: files ?? referenceRecordings(),
    free: referenceFreeBytes,
  );
  final engine = FakeEngine();
  final playback = FakePlayback();
  final controller = AppController(
    settings: settings,
    store: store,
    engine: engine,
    playback: playback,
    native: const NativeBridge(),
    workDir: () async => work!,
  );
  await tester.runAsync(controller.init);
  await tester.pumpWidget(VoiceRecorderApp(controller: controller));
  await precacheImages(tester);
  await tester.pumpAndSettle();
  return TestApp(controller, store, engine, playback, work!);
}
