import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_recorder/src/app_controller.dart';
import 'package:voice_recorder/src/core/settings.dart';
import 'package:voice_recorder/src/platform/native_bridge.dart';

import 'support/fakes.dart';

/// The Recorder screen's recording.
final _last = referenceRecordings()[2].id;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory work;
  late FakeEngine engine;
  late FakePlayback playback;
  late FakeNative native;
  late AppController app;
  late StreamController<void> resets;
  late int configures;
  late List<MethodCall> calls;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('vr_playback');
    calls = [];
    configures = 0;
    resets = StreamController<void>.broadcast();
    const channel = MethodChannel('com.spencerchase.voicerecorder/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    SharedPreferences.setMockInitialValues({
      'last_file': _last,
      'last_duration_ms': 2037000,
    });
    final settings = await Settings.load();
    engine = FakeEngine();
    playback = FakePlayback();
    native = FakeNative();
    app = AppController(
      settings: settings,
      store: FakeStore(files: referenceRecordings(), free: referenceFreeBytes),
      engine: engine,
      playback: playback,
      native: native,
      workDir: () async => work,
      mediaResets: resets.stream,
      configureAudio: () async => configures++,
    );
    await app.init();
  });
  tearDown(() async {
    app.dispose();
    await work.delete(recursive: true);
  });

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Iterable<MethodCall> named(String method) =>
      calls.where((c) => c.method == method);

  group('iOS resetting its media services', () {
    test('sets up the session again and unloads the dead player', () async {
      await app.togglePlay(app.currentFile!);
      await settle();
      expect(playback.playing, isTrue);
      expect(named('updateMediaSession'), isNotEmpty);

      resets.add(null);
      await settle();
      expect(configures, 1);
      expect(playback.fileId, isNull);
      expect(playback.playing, isFalse);
      expect(app.isPlayingCurrent, isFalse);
      expect(named('clearMediaSession'), hasLength(1));

      // The next play opens the file afresh.
      await app.togglePlay(app.currentFile!);
      expect(playback.playing, isTrue);
      expect(playback.played, hasLength(2));
    });

    test('leaves the session to a recording that is running', () async {
      expect(await app.toggleRecord(), RecordOutcome.started);
      resets.add(null);
      await settle();
      expect(configures, 0);
      expect(app.isRecording, isTrue);
    });
  });

  test('unplugged during a call: playback doesn\'t resume by itself', () async {
    final file = app.currentFile!;
    await app.togglePlay(file);
    await settle();
    // A call pauses it (just_audio would resume it afterwards)…
    await playback.pause();
    await settle();
    // …the headphones go meanwhile…
    playback.noisyController.add(null);
    await settle();
    // …and the call ends: just_audio resumes it by itself.
    await playback.play(file.id, Uri.parse(file.id));
    await settle();
    expect(playback.playing, isFalse);

    // Played in the app (or with the controls), it plays.
    await app.togglePlay(file);
    await settle();
    expect(playback.playing, isTrue);
  });

  test('a file that stops playing partway (iOS) is unloaded', () async {
    await app.togglePlay(app.currentFile!);
    await settle();
    expect(playback.playing, isTrue);
    native.eventController.add(const MediaButton('failed'));
    await settle();
    expect(playback.fileId, isNull);
    expect(playback.playing, isFalse);
    expect(named('clearMediaSession'), hasLength(1));
  });

  test('iOS pausing the player itself shows it paused', () async {
    await app.togglePlay(app.currentFile!);
    await settle();
    native.eventController.add(const MediaButton('pause'));
    await settle();
    expect(playback.playing, isFalse);
    expect(app.isPlayingCurrent, isFalse);
    expect(named('updateMediaSession').last.arguments['playing'], isFalse);
  });
}
