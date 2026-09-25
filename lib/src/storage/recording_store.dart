import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../audio/audio_info.dart';
import '../core/format.dart';
import '../core/recording_file.dart';
import '../core/settings.dart';
import '../platform/native_bridge.dart';

/// Where recordings live and how they are listed, renamed, deleted and shared.
abstract class RecordingStore extends ChangeNotifier {
  /// The folder as shown in Settings, e.g. `/storage/emulated/0/Recorders`.
  String get folderDisplayPath;

  /// Whether new recordings can be saved right now.
  bool get isReady;

  Future<void> init();

  /// Lets the user pick the recordings folder. Returns false if cancelled.
  Future<bool> chooseFolder();

  Future<List<RecordingFile>> list();

  /// Looks a recording up by id (null if it no longer exists).
  Future<RecordingFile?> find(String id);

  /// Moves a finished recording from app storage into the folder.
  Future<RecordingFile> save(File source, String fileName, String mimeType);

  /// Renames to [newBaseName] keeping the extension. Returns the updated file.
  Future<RecordingFile?> rename(RecordingFile file, String newBaseName);

  /// Deletes for good (see [trash] for Recently deleted).
  Future<bool> delete(RecordingFile file);

  /// Moves [file] to Recently deleted: it gets a hidden name in the same
  /// folder (see [TrashedRecording]). Null if the folder refused.
  Future<TrashedRecording?> trash(RecordingFile file, DateTime now) async {
    final hidden = TrashedRecording.hiddenName(file.name, now);
    // A name Recently deleted wouldn't know would hide the file for good.
    if (TrashedRecording.parse(file.copyWith(name: hidden)) == null) {
      return null;
    }
    final moved = await renameTo(file, hidden);
    if (moved == null) return null;
    final t = TrashedRecording.parse(moved);
    // The folder changed the name on the way: put the file back.
    if (t == null) await renameTo(moved, file.name);
    return t;
  }

  /// What is in Recently deleted.
  Future<List<TrashedRecording>> listTrash();

  /// Puts a deleted recording back under its old name (a free variant of it
  /// if that name is taken meanwhile).
  Future<RecordingFile?> restore(TrashedRecording t);

  /// Gives [file] exactly the name [fileName] (extension included).
  @protected
  Future<RecordingFile?> renameTo(RecordingFile file, String fileName);

  /// Opens the system share sheet. [origin] anchors the popover on iPad.
  Future<void> share(RecordingFile file, {Rect? origin}) =>
      shareAll([file], origin: origin);

  /// Shares several recordings at once.
  Future<void> shareAll(List<RecordingFile> files, {Rect? origin});

  /// Reads (and with [write], changes) a recording's bytes, e.g. to read or
  /// store its recording date.
  Future<ByteAccess> openBytes(RecordingFile file, {bool write = false});

  /// Bytes a recording may still grow by and be saved, or null if unknown.
  /// [pendingBytes] is the size of the recording in progress (0 when idle).
  Future<int?> usableBytes({int pendingBytes = 0});

  /// Full path shown at the bottom of the Recorder screen.
  String displayPath(RecordingFile file) => '$folderDisplayPath/${file.name}';

  /// URI just_audio can play.
  Uri playbackUri(RecordingFile file);

  static String mimeTypeFor(String fileName) =>
      switch (splitExtension(fileName).$2.toLowerCase()) {
        'mp3' => 'audio/mpeg',
        'wav' => 'audio/x-wav',
        'm4a' || 'aac' => 'audio/mp4',
        'amr' => 'audio/amr',
        '3gp' => 'audio/3gpp',
        'ogg' || 'opus' => 'audio/ogg',
        'flac' => 'audio/flac',
        _ => 'application/octet-stream',
      };
}

/// Android: a folder the user grants through the Storage Access Framework
/// (the original app used /storage/emulated/0/Recorders, which modern Android
/// only exposes to apps this way).
class AndroidRecordingStore extends RecordingStore {
  AndroidRecordingStore(this._native, this._settings);

  final NativeBridge _native;
  final Settings _settings;

  static const defaultFolder = '/storage/emulated/0/Recorders';

  bool _ready = false;
  String? _displayPath;

  @override
  String get folderDisplayPath => _displayPath ?? defaultFolder;

  @override
  bool get isReady => _ready;

  @override
  Future<void> init() async {
    final uri = _settings.folder;
    if (uri == null) return;
    _ready = await _native.hasFolderAccess(uri);
    if (_ready) _displayPath = await _native.folderPath(uri);
    notifyListeners();
  }

  @override
  Future<bool> chooseFolder() async {
    final uri = await _native.pickFolder(
      initialPath: _displayPath ?? defaultFolder,
    );
    if (uri == null) return false;
    _settings.folder = uri;
    _ready = true;
    _displayPath = await _native.folderPath(uri);
    notifyListeners();
    return true;
  }

  RecordingFile _fromMap(Map<Object?, Object?> m) => RecordingFile(
    id: m['id']! as String,
    name: m['name']! as String,
    size: (m['size'] as int?) ?? 0,
    modified: DateTime.fromMillisecondsSinceEpoch((m['modified'] as int?) ?? 0),
  );

  @override
  Future<List<RecordingFile>> list() async {
    final uri = _settings.folder;
    if (uri == null || !_ready) return const [];
    try {
      final rows = await _native.listFolder(uri);
      return rows.map(_fromMap).where((f) => isAudioFileName(f.name)).toList();
    } catch (e) {
      // The folder was deleted or access was revoked: ask for it again.
      await init();
      rethrow;
    }
  }

  @override
  Future<List<TrashedRecording>> listTrash() async {
    final uri = _settings.folder;
    if (uri == null || !_ready) return const [];
    final rows = await _native.listFolder(uri, hidden: true);
    return [for (final row in rows) ?TrashedRecording.parse(_fromMap(row))];
  }

  /// The folder picks a free name itself if the old one is taken ("a (1).mp3").
  @override
  Future<RecordingFile?> restore(TrashedRecording t) =>
      renameTo(t.file, t.originalName);

  @override
  Future<RecordingFile?> find(String id) async {
    final m = await _native.statDocument(id);
    return m == null ? null : _fromMap(m);
  }

  @override
  Future<RecordingFile> save(
    File source,
    String fileName,
    String mimeType,
  ) async {
    final uri = _settings.folder;
    if (uri == null) throw StateError('No recordings folder has been chosen');
    final m = await _native.importFile(
      treeUri: uri,
      sourcePath: source.path,
      displayName: fileName,
      mimeType: mimeType,
    );
    if (m == null) {
      throw FileSystemException('Could not save recording', fileName);
    }
    await source.delete();
    return _fromMap(m);
  }

  @override
  Future<RecordingFile?> rename(RecordingFile file, String newBaseName) {
    final ext = file.extension;
    return renameTo(file, ext.isEmpty ? newBaseName : '$newBaseName.$ext');
  }

  @override
  Future<RecordingFile?> renameTo(RecordingFile file, String fileName) async {
    final m = await _native.renameDocument(file.id, fileName);
    return m == null ? null : _fromMap(m);
  }

  @override
  Future<bool> delete(RecordingFile file) => _native.deleteDocument(file.id);

  @override
  Future<void> shareAll(List<RecordingFile> files, {Rect? origin}) {
    final types = {for (final f in files) RecordingStore.mimeTypeFor(f.name)};
    return _native.shareDocuments([
      for (final f in files) f.id,
    ], types.length == 1 ? types.first : 'audio/*');
  }

  @override
  Future<ByteAccess> openBytes(
    RecordingFile file, {
    bool write = false,
  }) async => _DocumentBytes(
    _native,
    await _native.openDocument(file.id, write: write),
  );

  /// A recording is written to app storage while it runs and copied into
  /// the folder when it stops, so it needs room in both places; on the same
  /// volume (internal storage) that is twice its size until the copy is done.
  @override
  Future<int?> usableBytes({int pendingBytes = 0}) async {
    final s = await _native.storageSpace(_settings.folder);
    if (s == null) return null;
    final destination = s.destination - pendingBytes;
    final usable = s.sameVolume
        ? destination ~/ 2
        : math.min(s.internal, destination);
    return math.max(0, usable);
  }

  @override
  Uri playbackUri(RecordingFile file) => Uri.parse(file.id);
}

/// iOS: `Documents/Recorders`, visible in the Files app under
/// On My iPhone > Voice Recorder > Recorders.
class IosRecordingStore extends RecordingStore {
  IosRecordingStore(
    this._native, {
    this._documents = getApplicationDocumentsDirectory,
  });

  final NativeBridge _native;
  final Future<Directory> Function() _documents;
  late Directory _dir;
  String _device = 'iPhone';

  @override
  String get folderDisplayPath => 'On My $_device/Voice Recorder/Recorders';

  @override
  bool get isReady => true;

  @override
  Future<void> init() async {
    final docs = await _documents();
    _dir = Directory('${docs.path}/Recorders');
    await _dir.create(recursive: true);
    try {
      _device = await _native.deviceKind() ?? _device;
    } catch (_) {}
  }

  /// There is no folder picker on iOS; this opens the folder in Files instead.
  @override
  Future<bool> chooseFolder() =>
      launchUrl(Uri.parse('shareddocuments://${_dir.path}'));

  RecordingFile _fromFile(File f) {
    final stat = f.statSync();
    return RecordingFile(
      id: f.path,
      name: f.uri.pathSegments.last,
      size: stat.size,
      modified: stat.modified,
    );
  }

  @override
  Future<List<RecordingFile>> list() async {
    if (!await _dir.exists()) return const [];
    return _dir
        .listSync()
        .whereType<File>()
        .where((f) => isAudioFileName(f.uri.pathSegments.last))
        .map(_fromFile)
        .toList();
  }

  @override
  Future<List<TrashedRecording>> listTrash() async {
    if (!await _dir.exists()) return const [];
    return [
      for (final f in _dir.listSync().whereType<File>())
        if (f.uri.pathSegments.last.startsWith('.'))
          ?TrashedRecording.parse(_fromFile(f)),
    ];
  }

  @override
  Future<RecordingFile?> restore(TrashedRecording t) async {
    final target = _unique(t.originalName);
    return _fromFile(await File(t.file.id).rename(target.path));
  }

  @override
  Future<RecordingFile?> renameTo(RecordingFile file, String fileName) async {
    final target = File('${_dir.path}/$fileName');
    return _fromFile(await File(file.id).rename(target.path));
  }

  /// Copies recordings picked in the Files app into the folder. Returns how
  /// many were copied (null if the picker was cancelled).
  Future<int?> importRecordings() => _native.importRecordings(_dir.path);

  @override
  Future<RecordingFile?> find(String id) async {
    var f = File(id);
    // iOS moves the app container on updates, so a saved path can go stale:
    // look the name up in the current folder instead.
    if (!await f.exists()) f = File('${_dir.path}/${id.split('/').last}');
    return await f.exists() ? _fromFile(f) : null;
  }

  File _unique(String fileName) {
    var candidate = File('${_dir.path}/$fileName');
    final (base, ext) = splitExtension(fileName);
    var n = 1;
    while (candidate.existsSync()) {
      candidate = File('${_dir.path}/$base ($n)${ext.isEmpty ? '' : '.$ext'}');
      n++;
    }
    return candidate;
  }

  @override
  Future<RecordingFile> save(
    File source,
    String fileName,
    String mimeType,
  ) async {
    final target = _unique(fileName);
    try {
      await source.rename(target.path);
    } on FileSystemException {
      await source.copy(target.path);
      await source.delete();
    }
    return _fromFile(target);
  }

  @override
  Future<RecordingFile?> rename(RecordingFile file, String newBaseName) async {
    final ext = file.extension;
    final name = ext.isEmpty ? newBaseName : '$newBaseName.$ext';
    if (name == file.name) return file;
    final target = _unique(name);
    final renamed = await File(file.id).rename(target.path);
    return _fromFile(renamed);
  }

  @override
  Future<bool> delete(RecordingFile file) async {
    try {
      await File(file.id).delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<void> shareAll(List<RecordingFile> files, {Rect? origin}) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [
          for (final file in files)
            XFile(
              file.id,
              mimeType: RecordingStore.mimeTypeFor(file.name),
              name: file.name,
            ),
        ],
        sharePositionOrigin: origin,
      ),
    );
  }

  @override
  Future<ByteAccess> openBytes(RecordingFile file, {bool write = false}) =>
      FileByteAccess.open(File(file.id), write: write);

  /// The recording in progress is already on this volume and is moved (not
  /// copied) into the folder, so the free space is all usable.
  @override
  Future<int?> usableBytes({int pendingBytes = 0}) =>
      _native.freeBytes(_dir.path);

  @override
  Uri playbackUri(RecordingFile file) => Uri.file(file.id);
}

/// [ByteAccess] to an Android document, through the platform side.
class _DocumentBytes implements ByteAccess {
  _DocumentBytes(this._native, this._handle);

  final NativeBridge _native;
  final int _handle;

  @override
  Future<int> length() => _native.documentLength(_handle);

  @override
  Future<Uint8List> read(int offset, int count) =>
      _native.readDocument(_handle, offset, count);

  @override
  Future<void> write(int offset, List<int> bytes) =>
      _native.writeDocument(_handle, offset, bytes);

  @override
  Future<void> truncate(int length) =>
      _native.truncateDocument(_handle, length);

  @override
  Future<void> close() => _native.closeDocument(_handle);
}
