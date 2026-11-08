import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_recorder/src/app_controller.dart';
import 'package:voice_recorder/src/audio/playback.dart';
import 'package:voice_recorder/src/core/settings.dart';

import '../support/fakes.dart';

/// just_audio's player without its platform side: it plays whatever it is
/// told, and says "playing" at once, like the real one.
class FakePlayer extends AudioPlayer {
  final _states = StreamController<PlayerState>.broadcast();
  final _errors = StreamController<PlayerException>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration?>.broadcast();
  bool _isPlaying = false;
  var _processing = ProcessingState.idle;
  var plays = 0;
  var pauses = 0;

  /// Makes play() fail after saying "playing", like just_audio when its own
  /// request for the audio session fails.
  Object? playError;

  /// Keeps each play's future open (just_audio's completes when playback
  /// stops), for the test to complete.
  bool holdPlays = false;
  final held = <Completer<void>>[];

  void _emit() => _states.add(PlayerState(_isPlaying, _processing));

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;
  @override
  Stream<PlayerException> get errorStream => _errors.stream;
  @override
  Stream<Duration> get positionStream => _positions.stream;
  @override
  Stream<Duration?> get durationStream => _durations.stream;
  @override
  bool get playing => _isPlaying;
  @override
  double get speed => 1;

  @override
  Future<Duration?> setAudioSource(
    AudioSource audioSource, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    _processing = ProcessingState.ready;
    _emit();
    return const Duration(minutes: 3);
  }

  @override
  Future<void> play() async {
    if (_isPlaying) return;
    plays++;
    _isPlaying = true;
    _emit();
    final e = playError;
    if (e != null) throw e;
    if (holdPlays) {
      final done = Completer<void>();
      held.add(done);
      return done.future;
    }
  }

  @override
  Future<void> pause() async {
    if (!_isPlaying) return;
    pauses++;
    _isPlaying = false;
    _emit();
  }

  @override
  Future<void> stop() async {
    _isPlaying = false;
    _processing = ProcessingState.idle;
    _emit();
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> dispose() async {}
}

/// The audio session, as the test sets it.
class FakeSession extends PlaybackSession {
  final calls = <String>[];
  bool granted = true;
  Object? activateError;
  Object? prepareError;
  bool callGoingOn = false;

  /// Holds activate() until completed (the system takes a moment).
  Completer<void>? activateGate;
  final noisy = StreamController<void>.broadcast();

  @override
  Future<void> prepare() async {
    calls.add('prepare');
    final e = prepareError;
    if (e != null) throw e;
  }

  @override
  Future<bool> activate() async {
    calls.add('activate');
    await activateGate?.future;
    final e = activateError;
    if (e != null) throw e;
    return granted;
  }

  @override
  Future<void> deactivate() async => calls.add('deactivate');

  @override
  Future<bool> inCall() async {
    calls.add('inCall');
    return callGoingOn;
  }

  @override
  Stream<void> get becomingNoisy => noisy.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlayer player;
  late FakeSession session;
  late JustAudioPlayback playback;
  final a = Uri.parse('file:///a.mp3');
  final b = Uri.parse('file:///b.mp3');

  setUp(() {
    player = FakePlayer();
    session = FakeSession();
    playback = JustAudioPlayback(player: player, session: session);
  });

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('the session is set up again before every play', () async {
    await playback.play('a', a);
    await playback.pause();
    await playback.play('a', a);
    expect(session.calls, [
      'inCall',
      'prepare',
      'activate',
      'inCall',
      'prepare',
      'activate',
    ]);
    expect(player.plays, 2);
  });

  test('a failed set-up of the session still plays', () async {
    session.prepareError = PlatformException(code: '561015905');
    await playback.play('a', a);
    await settle();
    expect(player.plays, 1);
    expect(playback.playing, isTrue);
  });

  test('iOS refusing the session with an error means busy', () async {
    // AVAudioSession's "cannot interrupt others" during a call.
    session.activateError = PlatformException(code: '561017449');
    await expectLater(
      playback.play('a', a),
      throwsA(isA<AudioBusyException>()),
    );
    expect(session.calls, contains('deactivate'));
    expect(player.plays, 0);
  });

  test('a refused session (false) means busy', () async {
    session.granted = false;
    await expectLater(
      playback.play('a', a),
      throwsA(isA<AudioBusyException>()),
    );
    expect(player.plays, 0);
  });

  test('during a call (Android) it is busy without asking', () async {
    session.callGoingOn = true;
    await expectLater(
      playback.play('a', a),
      throwsA(isA<AudioBusyException>()),
    );
    expect(session.calls, isNot(contains('activate')));
    expect(player.plays, 0);
  });

  test('another file loaded while asking for the session wins', () async {
    session.activateGate = Completer();
    final first = playback.play('a', a);
    await settle();
    await playback.load('b', b); // a seek in another row
    session.activateGate!.complete();
    await first;
    await settle();
    expect(playback.fileId, 'b');
    expect(player.plays, 0);
    expect(playback.playing, isFalse);
  });

  test('a play just_audio fails after saying "playing" shows paused', () async {
    player.playError = PlatformException(code: '561017449');
    await playback.play('a', a);
    await settle();
    expect(player.playing, isFalse);
    expect(playback.playing, isFalse);
    // The next play starts it again.
    player.playError = null;
    await playback.play('a', a);
    await settle();
    expect(playback.playing, isTrue);
    expect(player.plays, 2);
  });

  test('a late failure of a replaced play leaves the new one', () async {
    player.holdPlays = true;
    await playback.play('a', a);
    await playback.pause();
    await playback.play('a', a);
    await settle();
    expect(player.pauses, 1);
    // The first play's future fails only now: nothing to do with the play
    // going on, which isn't paused.
    player.held.first.completeError(PlatformException(code: 'abort'));
    await settle();
    expect(player.pauses, 1);
    expect(playback.playing, isTrue);
  });

  test('play during a call (iPhone) says audio is busy', () async {
    session.activateError = PlatformException(code: '561017449');
    final work = await Directory.systemTemp.createTemp('vr_busy');
    addTearDown(() => work.delete(recursive: true));
    SharedPreferences.setMockInitialValues({
      'last_file': referenceRecordings()[2].id,
    });
    final app = AppController(
      settings: await Settings.load(),
      store: FakeStore(files: referenceRecordings()),
      engine: FakeEngine(),
      playback: playback,
      native: FakeNative(),
      workDir: () async => work,
    );
    addTearDown(app.dispose);
    final file = referenceRecordings().first;
    // Not "Can't play this recording".
    expect(await app.togglePlay(file), PlayOutcome.audioBusy);
    expect(playback.playing, isFalse);
  });

  test('unplugged headphones are reported', () async {
    var noisy = 0;
    final sub = playback.becameNoisy.listen((_) => noisy++);
    addTearDown(sub.cancel);
    session.noisy.add(null);
    await settle();
    expect(noisy, 1);
  });
}
