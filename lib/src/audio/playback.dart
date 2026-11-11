import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

/// Play back through the loudspeaker even with the ring/silent switch on and
/// allow recording at any time. No Bluetooth hands-free profile: recordings
/// use the phone's microphone and headphones keep full playback quality.
/// Keep in sync with `_iosConfig` in lib/src/audio/recorder_engine.dart.
final appAudioSession = AudioSessionConfiguration(
  avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
  avAudioSessionCategoryOptions:
      AVAudioSessionCategoryOptions.defaultToSpeaker |
      AVAudioSessionCategoryOptions.allowBluetoothA2dp,
  avAudioSessionMode: AVAudioSessionMode.defaultMode,
  androidAudioAttributes: const AndroidAudioAttributes(
    contentType: AndroidAudioContentType.speech,
    usage: AndroidAudioUsage.media,
  ),
  androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
  // Recordings are speech: pause for a navigation prompt or similar
  // (and resume after it) instead of playing over it.
  androidWillPauseWhenDucked: true,
);

/// Applies [appAudioSession]. Every call sends the category to iOS again
/// (audio_session doesn't skip one that looks unchanged), which is what
/// restores it after iOS reset its media services. Throws if iOS refuses.
Future<void> configureAudioSession() async =>
    (await AudioSession.instance).configure(appAudioSession);

/// Thrown by [Playback.play] when the system won't let the app play audio
/// right now (e.g. during a phone call).
class AudioBusyException implements Exception {
  const AudioBusyException();

  @override
  String toString() => 'Audio is in use by another app or a call';
}

/// Plays one recording at a time; shared by the Recorder and list screens.
abstract class Playback extends ChangeNotifier {
  /// Id of the loaded recording, if any.
  String? get fileId;
  bool get playing;
  Duration get position;
  Duration get duration;

  /// Loads [fileId] (if it isn't already) without starting playback.
  /// Throws if the file can't be opened; nothing is loaded then.
  Future<void> load(String fileId, Uri uri);

  /// Loads [fileId] if needed and plays it from the current position.
  Future<void> play(String fileId, Uri uri);
  Future<void> pause();
  Future<void> seek(Duration position);

  /// Playback speed (1 = normal); the pitch stays the same.
  double get speed;
  Future<void> setSpeed(double speed);

  /// Stops and unloads the current recording.
  Future<void> stop();

  /// Headphones were unplugged or disconnected (or the like): audio would
  /// now come out of the loudspeaker.
  Stream<void> get becameNoisy => const Stream.empty();

  bool isPlaying(String id) => playing && fileId == id;
}

/// The audio session as [JustAudioPlayback] uses it (tests stand in for it).
class PlaybackSession {
  const PlaybackSession();

  /// iOS: applies the app's session again. A reset of the media services
  /// puts it back to the system's default, which the Ring/Silent switch
  /// mutes and which stops playing when the app is left.
  Future<void> prepare() async {
    if (Platform.isIOS) await configureAudioSession();
  }

  /// Asks for the session (Android: audio focus). False if refused; iOS
  /// refuses with an error instead.
  Future<bool> activate() async =>
      (await AudioSession.instance).setActive(true);

  Future<void> deactivate() async {
    await (await AudioSession.instance).setActive(false);
  }

  /// Android: a phone call rings or goes on. The app may still hold audio
  /// focus from before the call (a call only pauses it), and Android isn't
  /// asked again then.
  Future<bool> inCall() async {
    if (!Platform.isAndroid) return false;
    final mode = await AndroidAudioManager().getMode();
    return mode == AndroidAudioHardwareMode.ringtone ||
        mode == AndroidAudioHardwareMode.inCall ||
        mode == AndroidAudioHardwareMode.inCommunication;
  }

  Stream<void> get becomingNoisy =>
      Stream.fromFuture(AudioSession.instance)
          .asyncExpand((s) => s.becomingNoisyEventStream);
}

class JustAudioPlayback extends Playback {
  /// [player] and [session] stand in for the real ones (tests).
  JustAudioPlayback({
    AudioPlayer? player,
    this._session = const PlaybackSession(),
  }) : _player = player ?? AudioPlayer() {
    _subs.add(
      _player.playerStateStream.listen((s) {
        if (s.processingState == ProcessingState.completed && !_rewinding) {
          // Rewind like the original: the seek bar returns to 00:00.
          _rewinding = true;
          unawaited(_rewind());
        }
        // Idle: nothing loaded, or an error ended playback (just_audio then
        // still says "playing").
        _playing =
            s.playing &&
            s.processingState != ProcessingState.completed &&
            s.processingState != ProcessingState.idle;
        notifyListeners();
      }),
    );
    _subs.add(
      _player.errorStream.listen((e) {
        // The file couldn't be read on (e.g. its storage went away): show it
        // stopped, and open it afresh on the next play.
        debugPrint('Playback error: ${e.message}');
        _fileId = null;
        _playing = false;
        unawaited(_player.pause().catchError((Object _) {}));
        notifyListeners();
      }),
    );
    _subs.add(
      _player.positionStream.listen((p) {
        _position = p;
        notifyListeners();
      }),
    );
    _subs.add(
      _player.durationStream.listen((d) {
        _duration = d ?? Duration.zero;
        notifyListeners();
      }),
    );
  }

  final AudioPlayer _player;
  final PlaybackSession _session;
  final _subs = <StreamSubscription<Object?>>[];
  bool _rewinding = false;

  Future<void> _rewind() async {
    try {
      await _player.pause();
      await _player.seek(Duration.zero);
    } catch (e) {
      debugPrint('Could not rewind: $e');
    } finally {
      _rewinding = false;
    }
  }

  String? _fileId;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  String? get fileId => _fileId;
  @override
  bool get playing => _playing;
  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;

  /// The file being opened, and that load.
  ({String id, Future<void> done})? _opening;

  /// A second load of the file being opened (a skip or seek while its play
  /// opens it) waits for that load: starting over would stop it, and the
  /// play waiting on it would then not play.
  @override
  Future<void> load(String fileId, Uri uri) {
    if (_fileId == fileId) return Future.value();
    final opening = _opening;
    if (opening != null && opening.id == fileId) return opening.done;
    late final Future<void> done;
    done = _load(fileId, uri).whenComplete(() {
      if (identical(_opening?.done, done)) _opening = null;
    });
    _opening = (id: fileId, done: done);
    return done;
  }

  Future<void> _load(String fileId, Uri uri) async {
    await _player.stop();
    _fileId = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    notifyListeners();
    // Only remember the file once it opened, so a failed file can be retried.
    final Duration? length;
    try {
      length = await _player.setAudioSource(AudioSource.uri(uri));
    } on PlayerInterruptedException {
      return; // a newer load (another tap) replaced this one
    }
    _fileId = fileId;
    // Known now (the duration stream may tell a moment later).
    if (length != null) _duration = length;
    notifyListeners();
  }

  @override
  Stream<void> get becameNoisy => _session.becomingNoisy;

  /// Counts the plays, so a late error of one that was replaced is ignored.
  var _plays = 0;

  @override
  Future<void> play(String fileId, Uri uri) async {
    await load(fileId, uri);
    if (_fileId != fileId) return; // superseded by another file
    await _claimSession();
    // Another file may have been loaded meanwhile (a seek in another row).
    if (_fileId != fileId) return;
    final ticket = ++_plays;
    // play() completes when playback stops; errors surface as player events.
    unawaited(
      _player.play().catchError((Object e) {
        debugPrint('Playback error: $e');
        // just_audio says "playing" before it asks for the session itself
        // and stays so if that fails, although nothing plays: show it
        // paused (and let the next play start it again).
        if (ticket == _plays && _player.playing) {
          unawaited(_player.pause().catchError((Object _) {}));
        }
      }),
    );
  }

  /// Asks for the audio session ourselves: just_audio would silently not
  /// play if refused, and audio_session would keep the refused request.
  /// Throws [AudioBusyException] if the system won't let the app play now.
  Future<void> _claimSession() async {
    var call = false;
    try {
      call = await _session.inCall();
    } catch (e) {
      debugPrint('Could not tell whether a call goes on: $e');
    }
    if (call) throw const AudioBusyException();
    try {
      await _session.prepare();
    } catch (e) {
      // Playing may still work; if not, the activation below says so.
      debugPrint('Could not set up the audio session: $e');
    }
    var granted = false;
    try {
      granted = await _session.activate();
    } on PlatformException catch (e) {
      // iOS refuses with an error (a call, another app's session).
      debugPrint('Audio session refused: $e');
    }
    if (!granted) {
      try {
        await _session.deactivate();
      } catch (_) {}
      throw const AudioBusyException();
    }
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  double get speed => _player.speed;

  @override
  Future<void> setSpeed(double speed) async {
    await _player.setSpeed(speed);
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    _opening = null; // a load of it after this starts afresh
    await _player.stop();
    _fileId = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    _playing = false;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }
}
