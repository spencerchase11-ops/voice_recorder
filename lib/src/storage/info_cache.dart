import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../audio/audio_info.dart';
import '../core/recording_file.dart';

/// Dates and lengths read from the recordings themselves, kept between
/// launches so each file is read once. A file is known by its name, size and
/// modification time, so a changed file is read again.
///
/// Dates are kept as clock time, like the tags and names they come from, so
/// they stay in step with those after a change of time zone.
class RecordingInfoCache {
  /// Kept in [file] when given (the app), otherwise in memory only (tests).
  RecordingInfoCache({Future<File> Function()? file}) : _locate = file;

  final Future<File> Function()? _locate;
  final _map = <String, AudioInfo>{};

  /// Files whose date is known only here: writing it into the file failed,
  /// after the write had changed the file's time (see [dateOnlyHere]).
  final _onlyHere = <String>{};
  Timer? _saveTimer;
  bool _dirty = false;

  /// The save in progress; the next one waits for it.
  Future<void> _saving = Future.value();

  static String keyOf(RecordingFile f) =>
      '${f.name}|${f.size}|${f.modified.millisecondsSinceEpoch}';

  Future<void> load() async {
    final locate = _locate;
    if (locate == null) return;
    try {
      final f = await locate();
      if (!await f.exists()) return;
      final json = jsonDecode(await f.readAsString());
      if (json is! Map) return;
      json.forEach((k, v) {
        if (k is! String || v is! List || v.length < 2) return;
        final r = v[0], d = v[1];
        if (v.length > 2 && v[2] == 1) _onlyHere.add(k);
        _map[k] = AudioInfo(
          recorded: switch (r) {
            final String t => DateTime.tryParse(t),
            // Written by the first test builds: a point in time.
            final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
            _ => null,
          },
          duration: d is int ? Duration(milliseconds: d) : null,
        );
      });
    } catch (e) {
      debugPrint('Could not read the recording info cache: $e');
    }
  }

  AudioInfo? operator [](RecordingFile f) => _map[keyOf(f)];

  bool contains(RecordingFile f) => _map.containsKey(keyOf(f));

  /// Whether [f]'s date is known only here, not in the file (a write that
  /// failed): it should be written again.
  bool dateOnlyHere(RecordingFile f) => _onlyHere.contains(keyOf(f));

  /// Remembers [info] for [f]; [onlyHere] marks a date the file doesn't
  /// hold (see [dateOnlyHere]).
  void put(RecordingFile f, AudioInfo info, {bool onlyHere = false}) {
    final key = keyOf(f);
    if (_map[key] == info && _onlyHere.contains(key) == onlyHere) return;
    _map[key] = info;
    if (onlyHere) {
      _onlyHere.add(key);
    } else {
      _onlyHere.remove(key);
    }
    _changed();
  }

  /// Forgets files that are gone.
  void retainOnly(Iterable<RecordingFile> files) {
    final keep = {for (final f in files) keyOf(f)};
    final before = _map.length;
    _map.removeWhere((k, _) => !keep.contains(k));
    _onlyHere.removeWhere((k) => !keep.contains(k));
    if (_map.length != before) _changed();
  }

  void _changed() {
    _dirty = true;
    if (_locate == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 3), () => unawaited(save()));
  }

  /// Writes the cache now (it is also written a few seconds after changes).
  Future<void> save() {
    _saveTimer?.cancel();
    _saveTimer = null;
    return _saving = _saving.then((_) => _write());
  }

  Future<void> _write() async {
    final locate = _locate;
    if (locate == null || !_dirty) return;
    _dirty = false;
    final json = {
      for (final e in _map.entries)
        e.key: [
          // Local clock time without a zone: `2026-09-25T10:00:00.000`.
          e.value.recorded?.toLocal().toIso8601String(),
          e.value.duration?.inMilliseconds,
          if (_onlyHere.contains(e.key)) 1,
        ],
    };
    try {
      final f = await locate();
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(json), flush: true);
      await tmp.rename(f.path);
    } catch (e) {
      _dirty = true;
      debugPrint('Could not save the recording info cache: $e');
    }
  }

  void dispose() => _saveTimer?.cancel();
}
