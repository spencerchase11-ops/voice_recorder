import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

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

  Future<bool> delete(RecordingFile file);

  /// Opens the system share sheet. [origin] anchors the popover on iPad.
  Future<void> share(RecordingFile file, {Rect? origin});

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
  Future<RecordingFile?> rename(RecordingFile file, String newBaseName) async {
    final ext = file.extension;
    final name = ext.isEmpty ? newBaseName : '$newBaseName.$ext';
    final m = await _native.renameDocument(file.id, name);
    return m == null ? null : _fromMap(m);
  }

  @override
  Future<bool> delete(RecordingFile file) => _native.deleteDocument(file.id);

  @override
  Future<void> share(RecordingFile file, {Rect? origin}) =>
      _native.shareDocument(file.id, RecordingStore.mimeTypeFor(file.name));

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
  Future<bool> chooseFolder() async {
    await launchUrl(Uri.parse('shareddocuments://${_dir.path}'));
    return true;
  }

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
  Future<void> share(RecordingFile file, {Rect? origin}) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [
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

  /// The recording in progress is already on this volume and is moved (not
  /// copied) into the folder, so the free space is all usable.
  @override
  Future<int?> usableBytes({int pendingBytes = 0}) =>
      _native.freeBytes(_dir.path);

  @override
  Uri playbackUri(RecordingFile file) => Uri.file(file.id);
}
