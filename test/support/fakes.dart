import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:voice_recorder/src/audio/audio_info.dart';
import 'package:voice_recorder/src/audio/playback.dart';
import 'package:voice_recorder/src/audio/recorder_engine.dart';
import 'package:voice_recorder/src/core/format.dart';
import 'package:voice_recorder/src/core/recording_file.dart';
import 'package:voice_recorder/src/core/recording_format.dart';
import 'package:voice_recorder/src/platform/native_bridge.dart';
import 'package:voice_recorder/src/storage/recording_store.dart';

/// In-memory [RecordingStore].
class FakeStore extends RecordingStore {
  FakeStore({List<RecordingFile>? files, this.free = 0, this.ready = true})
    : files = [...?files];

  final List<RecordingFile> files;
  int? free;
  bool ready;

  /// Makes [save] fail, like a folder whose access was revoked.
  bool failSaves = false;

  /// Holds [rename] and [delete] until completed (slow storage).
  Completer<void>? slow;
  final saved = <String>[];

  /// Contents of each saved file.
  final savedBytes = <String, List<int>>{};
  final shared = <String>[];
  var folderChoices = 0;

  /// Old ids that [find] resolves to current ones (moved files).
  final aliases = <String, String>{};

  /// File contents for [openBytes], by id (a missing file reads as empty).
  final contents = <String, List<int>>{};

  /// Ids whose bytes can't be opened (like a file deleted meanwhile).
  final unreadable = <String>{};
  var opens = 0;

  /// Makes [renameTo] (rename, trash, restore) fail.
  bool failRenames = false;
  final deletedForGood = <String>[];

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
  Future<List<RecordingFile>> list() async => [
    for (final f in files)
      if (isAudioFileName(f.name)) f,
  ];

  @override
  Future<List<TrashedRecording>> listTrash() async => [
    for (final f in files) ?TrashedRecording.parse(f),
  ];

  @override
  Future<RecordingFile?> restore(TrashedRecording t) async {
    var name = t.originalName;
    final (base, ext) = splitExtension(name);
    for (var n = 1; files.any((f) => f.name == name); n++) {
      name = '$base ($n)${ext.isEmpty ? '' : '.$ext'}';
    }
    return renameTo(t.file, name);
  }

  @override
  Future<RecordingFile?> renameTo(RecordingFile file, String fileName) async {
    await slow?.future;
    if (failRenames) return null;
    final i = files.indexWhere((f) => f.id == file.id);
    if (i < 0) return null;
    final r = RecordingFile(
      id: 'mem://$fileName',
      name: fileName,
      size: file.size,
      modified: file.modified,
    );
    files[i] = r;
    final bytes = contents.remove(file.id);
    if (bytes != null) contents[r.id] = bytes;
    return r;
  }

  @override
  Future<void> shareAll(List<RecordingFile> files, {Rect? origin}) async =>
      shared.addAll(files.map((f) => f.name));

  @override
  Future<ByteAccess> openBytes(RecordingFile file, {bool write = false}) async {
    opens++;
    if (unreadable.contains(file.id)) {
      throw const FileSystemException('gone');
    }
    return MemoryBytes(contents.putIfAbsent(file.id, () => <int>[]));
  }

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
    if (failSaves) throw const FileSystemException('no access');
    final size = await source.length();
    final bytes = await source.readAsBytes();
    savedBytes[fileName] = bytes;
    await source.delete();
    final f = RecordingFile(
      id: 'mem://$fileName',
      name: fileName,
      size: size,
      modified: DateTime(2026, 9, 23, 19, 14),
    );
    contents[f.id] = [...bytes];
    files.add(f);
    saved.add(fileName);
    return f;
  }

  @override
  Future<RecordingFile?> rename(RecordingFile file, String newBaseName) =>
      renameTo(
        file,
        file.extension.isEmpty ? newBaseName : '$newBaseName.${file.extension}',
      );

  @override
  Future<bool> delete(RecordingFile file) async {
    await slow?.future;
    final before = files.length;
    files.removeWhere((f) => f.id == file.id);
    contents.remove(file.id);
    if (files.length < before) deletedForGood.add(file.name);
    return files.length < before;
  }

  @override
  Future<int?> usableBytes({int pendingBytes = 0}) async => free;

  @override
  Uri playbackUri(RecordingFile file) => Uri.parse(file.id);
}

/// [RecorderEngine] that writes a few bytes and lets tests drive the level.
class FakeEngine implements RecorderEngine {
  bool permission = true;
  String? path;
  RecordingProfile? profile;

  /// What start() writes, and what stop() and resume() throw (if anything).
  List<int> content = List.filled(1000, 1);
  Object? stopError;
  Object? resumeError;

  /// Makes start() take a while, like a slow audio system.
  Completer<void>? startGate;
  final levelController = StreamController<double>.broadcast();
  final interruptController = StreamController<bool>.broadcast();
  final endedController = StreamController<CaptureEnd>.broadcast();
  var resumes = 0;

  @override
  Future<bool> requestPermission() async => permission;

  DateTime? recorded;
  bool? noiseReduction;

  @override
  Future<void> start(
    RecordingProfile profile,
    String path, {
    DateTime? recorded,
    bool noiseReduction = false,
  }) async {
    this.profile = profile;
    this.path = path;
    this.recorded = recorded;
    this.noiseReduction = noiseReduction;
    await startGate?.future;
    await File(path).writeAsBytes(content);
  }

  var pauses = 0;
  Object? pauseError;

  @override
  Future<void> pause() async {
    pauses++;
    if (pauseError != null) throw pauseError!;
  }

  @override
  Future<void> stop() async {
    if (stopError != null) throw stopError!;
  }

  @override
  Stream<double> get levels => levelController.stream;

  @override
  Stream<bool> get interrupted => interruptController.stream;

  @override
  Stream<CaptureEnd> get ended => endedController.stream;

  @override
  Future<void> resume() async {
    resumes++;
    if (resumeError != null) throw resumeError!;
  }

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

  /// Ids that fail to open, like a deleted or corrupt file.
  final broken = <String>{};

  @override
  Future<void> load(String fileId, Uri uri) async {
    if (_id == fileId) return;
    if (broken.contains(fileId)) {
      _id = null;
      throw Exception('cannot open $fileId');
    }
    _id = fileId;
    _position = Duration.zero;
    _duration = const Duration(minutes: 3);
    notifyListeners();
  }

  /// Makes play() fail like during a phone call.
  bool audioBusy = false;

  @override
  Future<void> play(String fileId, Uri uri) async {
    await load(fileId, uri);
    if (audioBusy) throw const AudioBusyException();
    _playing = true;
    played.add(fileId);
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    _playing = false;
    notifyListeners();
  }

  var seeks = 0;

  @override
  Future<void> seek(Duration position) async {
    seeks++;
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

  double _speed = 1;

  @override
  double get speed => _speed;

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
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

/// [ByteAccess] over bytes in memory.
class MemoryBytes implements ByteAccess {
  MemoryBytes(this.data);

  final List<int> data;
  var closed = false;

  @override
  Future<int> length() async => data.length;

  @override
  Future<Uint8List> read(int offset, int count) async {
    final start = math.min(offset, data.length);
    final end = math.min(offset + count, data.length);
    return Uint8List.fromList(data.sublist(start, end));
  }

  @override
  Future<void> write(int offset, List<int> bytes) async {
    if (data.length < offset + bytes.length) {
      data.addAll(List.filled(offset + bytes.length - data.length, 0));
    }
    data.setRange(offset, offset + bytes.length, bytes);
  }

  @override
  Future<void> close() async => closed = true;
}

/// [NativeBridge] whose platform events come from the test. Calls still go
/// to the method channel (mock it to see them).
class FakeNative extends NativeBridge {
  final eventController = StreamController<NativeEvent>.broadcast();

  @override
  Stream<NativeEvent> get events => eventController.stream;
}
