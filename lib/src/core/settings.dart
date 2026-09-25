import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'recording_format.dart';

/// Order of the recording list.
enum SortOrder {
  newest('Newest first'),
  oldest('Oldest first'),
  nameAscending('Name (A to Z)'),
  nameDescending('Name (Z to A)'),
  largest('Largest first');

  const SortOrder(this.label);

  final String label;
}

/// Playback speeds offered in the list and in Settings.
const playbackSpeeds = [1.0, 1.25, 1.5, 2.0];

/// `1x`, `1.25x`, `1.5x`, `2x`.
String formatSpeed(double speed) {
  final s = speed == speed.roundToDouble()
      ? speed.toInt().toString()
      : speed.toString();
  return '${s}x';
}

/// Persisted user settings.
class Settings extends ChangeNotifier {
  Settings(this._prefs)
    : _type = _enumByName(
        RecordingType.values,
        _prefs.getString(_kType),
        RecordingType.mp3,
      ),
      _quality = _enumByName(
        RecordingQuality.values,
        _prefs.getString(_kQuality),
        RecordingQuality.best,
      ),
      _folder = _prefs.getString(_kFolder),
      _lastFile = _prefs.getString(_kLastFile),
      _lastDurationMs = _prefs.getInt(_kLastDuration) ?? 0,
      _sortOrder = _enumByName(
        SortOrder.values,
        _prefs.getString(_kSortOrder),
        SortOrder.newest,
      ),
      _speed = _validSpeed(_prefs.getDouble(_kSpeed)),
      _lockScreenControls = _prefs.getBool(_kLockScreen) ?? true,
      _noiseReduction = _prefs.getBool(_kNoiseReduction) ?? false;

  static Future<Settings> load() async =>
      Settings(await SharedPreferences.getInstance());

  static const _kType = 'recording_type';
  static const _kQuality = 'recording_quality';
  static const _kFolder = 'folder';
  static const _kLastFile = 'last_file';
  static const _kLastDuration = 'last_duration_ms';
  static const _kSortOrder = 'sort_order';
  static const _kSpeed = 'playback_speed';
  static const _kLockScreen = 'lock_screen_controls';
  static const _kNoiseReduction = 'noise_reduction';

  final SharedPreferences _prefs;

  RecordingType _type;
  RecordingQuality _quality;
  String? _folder;
  String? _lastFile;
  int _lastDurationMs;
  SortOrder _sortOrder;
  double _speed;
  bool _lockScreenControls;
  bool _noiseReduction;

  RecordingType get type => _type;
  RecordingQuality get quality => _quality;
  RecordingProfile get profile => RecordingProfile.of(_type, _quality);

  /// Android: the persisted document-tree URI of the recordings folder.
  String? get folder => _folder;

  /// Id of the file shown at the bottom of the Recorder screen.
  String? get lastFile => _lastFile;

  /// Length of the last recording, shown by the timer when idle.
  Duration get lastDuration => Duration(milliseconds: _lastDurationMs);

  SortOrder get sortOrder => _sortOrder;

  /// Playback speed, one of [playbackSpeeds].
  double get playbackSpeed => _speed;

  /// Playback keeps going in the background, with controls on the lock
  /// screen and (Android) in a notification. Off: it pauses when the app is
  /// left.
  bool get lockScreenControls => _lockScreenControls;

  /// The platform's noise suppression while recording (MP3 and WAV).
  bool get noiseReduction => _noiseReduction;

  set sortOrder(SortOrder v) {
    if (v == _sortOrder) return;
    _sortOrder = v;
    _prefs.setString(_kSortOrder, v.name);
    notifyListeners();
  }

  set playbackSpeed(double v) {
    final speed = _validSpeed(v);
    if (speed == _speed) return;
    _speed = speed;
    _prefs.setDouble(_kSpeed, speed);
    notifyListeners();
  }

  set lockScreenControls(bool v) {
    if (v == _lockScreenControls) return;
    _lockScreenControls = v;
    _prefs.setBool(_kLockScreen, v);
    notifyListeners();
  }

  set noiseReduction(bool v) {
    if (v == _noiseReduction) return;
    _noiseReduction = v;
    _prefs.setBool(_kNoiseReduction, v);
    notifyListeners();
  }

  static double _validSpeed(double? v) => playbackSpeeds.contains(v) ? v! : 1.0;

  set type(RecordingType v) {
    if (v == _type) return;
    _type = v;
    _prefs.setString(_kType, v.name);
    notifyListeners();
  }

  set quality(RecordingQuality v) {
    if (v == _quality) return;
    _quality = v;
    _prefs.setString(_kQuality, v.name);
    notifyListeners();
  }

  set folder(String? v) {
    if (v == _folder) return;
    _folder = v;
    v == null ? _prefs.remove(_kFolder) : _prefs.setString(_kFolder, v);
    notifyListeners();
  }

  void setLast(String? fileId, Duration duration) {
    _lastFile = fileId;
    _lastDurationMs = duration.inMilliseconds;
    fileId == null
        ? _prefs.remove(_kLastFile)
        : _prefs.setString(_kLastFile, fileId);
    _prefs.setInt(_kLastDuration, _lastDurationMs);
    notifyListeners();
  }

  static T _enumByName<T extends Enum>(
    List<T> values,
    String? name,
    T fallback,
  ) => values.firstWhere((v) => v.name == name, orElse: () => fallback);
}
