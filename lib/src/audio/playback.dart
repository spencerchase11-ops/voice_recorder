import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

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

  /// Stops and unloads the current recording.
  Future<void> stop();

  bool isPlaying(String id) => playing && fileId == id;
}

class JustAudioPlayback extends Playback {
  JustAudioPlayback() {
    _subs.add(
      _player.playerStateStream.listen((s) {
        if (s.processingState == ProcessingState.completed && !_rewinding) {
          // Rewind like the original: the seek bar returns to 00:00.
          _rewinding = true;
          unawaited(_rewind());
        }
        _playing = s.playing && s.processingState != ProcessingState.completed;
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

  final _player = AudioPlayer();
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

  @override
  Future<void> load(String fileId, Uri uri) async {
    if (_fileId == fileId) return;
    await _player.stop();
    _fileId = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    notifyListeners();
    // Only remember the file once it opened, so a failed file can be retried.
    try {
      await _player.setAudioSource(AudioSource.uri(uri));
    } on PlayerInterruptedException {
      return; // a newer load (another tap) replaced this one
    }
    _fileId = fileId;
    notifyListeners();
  }

  @override
  Future<void> play(String fileId, Uri uri) async {
    await load(fileId, uri);
    if (_fileId != fileId) return; // superseded by another file
    // play() completes when playback stops; errors surface as player events.
    unawaited(
      _player.play().catchError((Object e) {
        debugPrint('Playback error: $e');
      }),
    );
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() async {
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
