import 'dart:async';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:voice_recorder/src/audio/playback.dart';
import 'package:voice_recorder/src/audio/recorder_engine.dart';
import 'package:voice_recorder/src/core/format.dart';
import 'package:voice_recorder/src/core/recording_file.dart';
import 'package:voice_recorder/src/core/recording_format.dart';
import 'package:voice_recorder/src/storage/recording_store.dart';

/// In-memory [RecordingStore].
class FakeStore extends RecordingStore {
  FakeStore({List<RecordingFile>? files, this.free = 0, this.ready = true})
    : files = [...?files];

  final List<RecordingFile> files;
  int? free;
  bool ready;
  final saved = <String>[];
  final shared = <String>[];
  var folderChoices = 0;

  /// Old ids that [find] resolves to current ones (moved files).
  final aliases = <String, String>{};

  @override
  String get folderDisplayPath => '/storage/emulated/0/Recorders';

  @override
  bool get isReady => ready;

  @override
  Future<void> init() async {}

  @override
  Future<bool> chooseFolder() async {
    folderChoices++;
    ready = true;
    notifyListeners();
    return true;
  }

  @override
  Future<List<RecordingFile>> list() async => [...files];

  @override
  Future<RecordingFile?> find(String id) async {
    final current = aliases[id] ?? id;
    for (final f in files) {
      if (f.id == current) return f;
    }
    return null;
  }

  @override
  Future<RecordingFile> save(
    File source,
    String fileName,
    String mimeType,
  ) async {
    final size = await source.length();
    await source.delete();
    final f = RecordingFile(
      id: 'mem://$fileName',
      name: fileName,
      size: size,
      modified: DateTime(2026, 9, 23, 19, 14),
    );
    files.add(f);
    saved.add(fileName);
    return f;
  }

  @override
  Future<RecordingFile?> rename(RecordingFile file, String newBaseName) async {
    final i = files.indexWhere((f) => f.id == file.id);
    if (i < 0) return null;
    final name = file.extension.isEmpty
        ? newBaseName
        : '$newBaseName.${file.extension}';
    final r = file.copyWith(id: 'mem://$name', name: name);
    files[i] = r;
    return r;
  }

  @override
  Future<bool> delete(RecordingFile file) async {
    final before = files.length;
    files.removeWhere((f) => f.id == file.id);
    return files.length < before;
  }

  @override
  Future<void> share(RecordingFile file, {Rect? origin}) async =>
      shared.add(file.name);

  @override
  Future<int?> freeBytes() async => free;

  @override
  Uri playbackUri(RecordingFile file) => Uri.parse(file.id);
}

/// [RecorderEngine] that writes a few bytes and lets tests drive the level.
class FakeEngine implements RecorderEngine {
  bool permission = true;
  String? path;
  RecordingProfile? profile;
  final levelController = StreamController<double>.broadcast();
  final interruptController = StreamController<bool>.broadcast();

  @override
  Future<bool> requestPermission() async => permission;

  @override
  Future<void> start(RecordingProfile profile, String path) async {
    this.profile = profile;
    this.path = path;
    await File(path).writeAsBytes(List.filled(1000, 1));
  }

  @override
  Future<void> stop() async {}

  @override
  Stream<double> get levels => levelController.stream;

  @override
  Stream<bool> get interrupted => interruptController.stream;

  @override
  Future<void> dispose() async {}
}

class FakePlayback extends Playback {
  String? _id;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  final played = <String>[];

  @override
  String? get fileId => _id;
  @override
  bool get playing => _playing;
  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;

  @override
  Future<void> play(String fileId, Uri uri) async {
    if (_id != fileId) {
      _position = Duration.zero;
      _duration = const Duration(minutes: 3);
    }
    _id = fileId;
    _playing = true;
    played.add(fileId);
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    _playing = false;
    notifyListeners();
  }

  @override
  Future<void> seek(Duration position) async {
    _position = position;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    _id = null;
    _playing = false;
    _position = Duration.zero;
    notifyListeners();
  }

  void setPosition(Duration p) {
    _position = p;
    notifyListeners();
  }
}

/// The recordings visible in the reference "Recording list" screenshot.
List<RecordingFile> referenceRecordings() {
  RecordingFile f(String name, DateTime t, int kb) => RecordingFile(
    id: 'mem://$name',
    name: name,
    size: kb * 1024 + 300,
    modified: t,
  );
  return [
    f('2026_09_16_15_48_15.mp3', DateTime(2026, 9, 16, 15, 48, 15), 38156),
    f('lunch w kris team convo .mp3', DateTime(2026, 9, 17, 13, 30), 26930),
    f(
      'kris n evan got back then zach.mp3',
      DateTime(2026, 9, 23, 18, 38),
      39819,
    ),
    f('2026_09_18_21_23_04.mp3', DateTime(2026, 9, 18, 21, 23, 4), 28689),
    f('2026_09_20_17_26_27.mp3', DateTime(2026, 9, 20, 17, 26, 27), 79381),
    f('2026_09_18_19_52_06.mp3', DateTime(2026, 9, 18, 19, 52, 6), 4808),
    f('got in friday then team call.mp3', DateTime(2026, 9, 18, 10, 15), 31311),
    f('2026_09_18_12_00_26.mp3', DateTime(2026, 9, 18, 12, 0, 26), 24120),
    f('2026_09_17_09_27_00.mp3', DateTime(2026, 9, 17, 9, 27), 62081),
    f('2026_09_16_16_37_26.mp3', DateTime(2026, 9, 16, 16, 37, 26), 5911),
  ];
}

/// Free space that gives "Remaining time: 9665:13:10" at 160 kbps.
final int referenceFreeBytes = (9665 * 3600 + 13 * 60 + 10) * 20000;

/// Display name helper for tests.
String baseOf(String name) => splitExtension(name).$1;
