import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'recording_format.dart';

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
      _lastDurationMs = _prefs.getInt(_kLastDuration) ?? 0;

  static Future<Settings> load() async =>
      Settings(await SharedPreferences.getInstance());

  static const _kType = 'recording_type';
  static const _kQuality = 'recording_quality';
  static const _kFolder = 'folder';
  static const _kLastFile = 'last_file';
  static const _kLastDuration = 'last_duration_ms';

  final SharedPreferences _prefs;

  RecordingType _type;
  RecordingQuality _quality;
  String? _folder;
  String? _lastFile;
  int _lastDurationMs;

  RecordingType get type => _type;
  RecordingQuality get quality => _quality;
  RecordingProfile get profile => RecordingProfile.of(_type, _quality);

  /// Android: the persisted document-tree URI of the recordings folder.
  String? get folder => _folder;

  /// Id of the file shown at the bottom of the Recorder screen.
  String? get lastFile => _lastFile;

  /// Length of the last recording, shown by the timer when idle.
  Duration get lastDuration => Duration(milliseconds: _lastDurationMs);

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
