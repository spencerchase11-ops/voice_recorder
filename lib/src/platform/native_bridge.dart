import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Free space on Android, see [NativeBridge.storageSpace].
typedef StorageSpace = ({int destination, int internal, bool sameVolume});

/// Something the platform side reports on its own.
sealed class NativeEvent {
  const NativeEvent();
}

/// A button on the lock screen, in the playback notification, on
/// headphones or in the car was pressed.
class MediaButton extends NativeEvent {
  const MediaButton(this.action, {this.position});

  /// play, pause, toggle, seek, forward, rewind, stop or dismiss (the
  /// notification was swiped away).
  final String action;

  /// Target of a seek.
  final Duration? position;

  @override
  String toString() => 'MediaButton($action, $position)';
}

/// iOS: how far an import of recordings has got ([total] is 0 while the
/// picked folders are still being looked through).
class ImportProgress extends NativeEvent {
  const ImportProgress(this.done, this.total);

  final int done;
  final int total;

  @override
  String toString() => 'ImportProgress($done of $total)';
}

/// What an import of recordings did.
typedef ImportResult = ({
  int copied,
  int skipped,
  int failed,

  /// Of [failed], those that didn't fit (the iPhone is full).
  int full,

  /// Sound files in formats the app doesn't take (AMR, Ogg…), left out.
  int ignored,

  /// The user stopped it.
  bool cancelled,
});

/// A button in the Android recording notification: pause, resume or stop.
class RecordingButton extends NativeEvent {
  const RecordingButton(this.action);

  final String action;

  @override
  String toString() => 'RecordingButton($action)';
}

/// Calls into the small amount of platform code the app needs
/// (android/app/src/main/kotlin/... and ios/Runner/AppDelegate.swift).
class NativeBridge {
  NativeBridge([MethodChannel? channel])
    : _channel =
          channel ??
          const MethodChannel('com.spencerchase.voicerecorder/native');

  final MethodChannel _channel;
  StreamController<NativeEvent>? _events;

  /// Buttons pressed outside the app (see [NativeEvent]).
  Stream<NativeEvent> get events {
    final existing = _events;
    if (existing != null) return existing.stream;
    final c = _events = StreamController<NativeEvent>.broadcast();
    _channel.setMethodCallHandler((call) async {
      final args = call.arguments is Map
          ? (call.arguments as Map).cast<Object?, Object?>()
          : const <Object?, Object?>{};
      switch (call.method) {
        case 'mediaAction':
          final ms = args['position'];
          c.add(
            MediaButton(
              args['action']! as String,
              position: ms is int ? Duration(milliseconds: ms) : null,
            ),
          );
        case 'recordingAction':
          c.add(RecordingButton(args['action']! as String));
        case 'importProgress':
          c.add(
            ImportProgress(
              (args['done'] as int?) ?? 0,
              (args['total'] as int?) ?? 0,
            ),
          );
        default:
          debugPrint('Unknown call from the platform: ${call.method}');
      }
      return null;
    });
    return c.stream;
  }

  // ------------------------------------------------------------ Android
  /// Opens the system folder picker. Returns the persisted tree URI or null.
  Future<String?> pickFolder({String? initialPath}) =>
      _channel.invokeMethod<String>('pickFolder', {'initialPath': initialPath});

  Future<bool> hasFolderAccess(String treeUri) async =>
      await _channel.invokeMethod<bool>('hasFolderAccess', {
        'treeUri': treeUri,
      }) ??
      false;

  /// e.g. `/storage/emulated/0/Recorders` for a folder on internal storage.
  Future<String?> folderPath(String treeUri) =>
      _channel.invokeMethod<String>('folderPath', {'treeUri': treeUri});

  /// The folder's files; with [hidden], only those whose names start with a
  /// dot (Recently deleted), otherwise all others.
  Future<List<Map<Object?, Object?>>> listFolder(
    String treeUri, {
    bool hidden = false,
  }) async =>
      (await _channel.invokeListMethod<Map<Object?, Object?>>('listFolder', {
        'treeUri': treeUri,
        'hidden': hidden,
      })) ??
      const [];

  /// Copies [sourcePath] into the folder as [displayName].
  Future<Map<Object?, Object?>?> importFile({
    required String treeUri,
    required String sourcePath,
    required String displayName,
    required String mimeType,
  }) => _channel.invokeMapMethod<Object?, Object?>('importFile', {
    'treeUri': treeUri,
    'sourcePath': sourcePath,
    'displayName': displayName,
    'mimeType': mimeType,
  });

  Future<Map<Object?, Object?>?> renameDocument(
    String documentUri,
    String displayName,
  ) => _channel.invokeMapMethod<Object?, Object?>('renameDocument', {
    'documentUri': documentUri,
    'displayName': displayName,
  });

  Future<Map<Object?, Object?>?> statDocument(String documentUri) =>
      _channel.invokeMapMethod<Object?, Object?>('statDocument', {
        'documentUri': documentUri,
      });

  Future<bool> deleteDocument(String documentUri) async =>
      await _channel.invokeMethod<bool>('deleteDocument', {
        'documentUri': documentUri,
      }) ??
      false;

  Future<void> shareDocuments(List<String> documentUris, String mimeType) =>
      _channel.invokeMethod<void>('shareDocuments', {
        'documentUris': documentUris,
        'mimeType': mimeType,
      });

  /// Opens a document for random access; [write] also allows changes.
  /// Returns a handle for the calls below.
  Future<int> openDocument(String documentUri, {bool write = false}) async =>
      (await _channel.invokeMethod<int>('openDocument', {
        'documentUri': documentUri,
        'write': write,
      }))!;

  Future<int> documentLength(int handle) async =>
      (await _channel.invokeMethod<int>('documentLength', {'handle': handle}))!;

  Future<Uint8List> readDocument(int handle, int offset, int count) async =>
      (await _channel.invokeMethod<Uint8List>('readDocument', {
        'handle': handle,
        'offset': offset,
        'count': count,
      })) ??
      Uint8List(0);

  Future<void> writeDocument(int handle, int offset, List<int> bytes) =>
      _channel.invokeMethod<void>('writeDocument', {
        'handle': handle,
        'offset': offset,
        'bytes': Uint8List.fromList(bytes),
      });

  /// Cuts the document to [length] bytes.
  Future<void> truncateDocument(int handle, int length) =>
      _channel.invokeMethod<void>('truncateDocument', {
        'handle': handle,
        'length': length,
      });

  Future<void> closeDocument(int handle) =>
      _channel.invokeMethod<void>('closeDocument', {'handle': handle});

  /// Keeps the process (and microphone access) alive while recording, with
  /// an ongoing notification that has Pause and Stop buttons.
  Future<void> startRecordingService({
    required String title,
    required String text,
  }) => _channel.invokeMethod<void>('startRecordingService', {
    'title': title,
    'text': text,
  });

  /// Shows whether the recording is [paused] in its notification, and how
  /// long it has run ([elapsed], for the notification's timer).
  Future<void> updateRecordingService({
    required String text,
    required bool paused,
    required Duration elapsed,
  }) => _channel.invokeMethod<void>('updateRecordingService', {
    'text': text,
    'paused': paused,
    'elapsedMs': elapsed.inMilliseconds,
  });

  Future<void> stopRecordingService() =>
      _channel.invokeMethod<void>('stopRecordingService');

  // ---------------------------------------------------------------- both
  /// Shows (or updates) the playback controls on the lock screen and, on
  /// Android, in a notification that keeps playback going in the background.
  Future<void> updateMediaSession({
    required String title,
    required Duration duration,
    required Duration position,
    required bool playing,
    required double speed,
  }) => _channel.invokeMethod<void>('updateMediaSession', {
    'title': title,
    'durationMs': duration.inMilliseconds,
    'positionMs': position.inMilliseconds,
    'playing': playing,
    'speed': speed,
  });

  /// Removes the playback controls.
  Future<void> clearMediaSession() =>
      _channel.invokeMethod<void>('clearMediaSession');

  /// What the app was opened for from a home-screen shortcut ("record"),
  /// once; null otherwise.
  Future<String?> takeLaunchAction() =>
      _channel.invokeMethod<String>('takeLaunchAction');

  /// Android: free space of the folder's volume ([treeUri], or shared storage
  /// when none is chosen) and of internal app storage, where recordings are
  /// written before being copied into the folder.
  Future<StorageSpace?> storageSpace(String? treeUri) async {
    final m = await _channel.invokeMapMethod<String, Object?>('storageSpace', {
      'location': treeUri,
    });
    if (m == null) return null;
    return (
      destination: m['destination']! as int,
      internal: m['internal']! as int,
      sameVolume: m['sameVolume']! as bool,
    );
  }

  /// iOS: free bytes on the volume that holds [path].
  Future<int?> freeBytes(String path) =>
      _channel.invokeMethod<int>('freeBytes', {'location': path});

  /// iOS: after a recording, undoes the preferred sample rate it set on the
  /// audio session (so later playback isn't resampled to a low rate) and
  /// lets other apps' audio that the recording paused carry on.
  Future<void> resetAudioSampleRate() =>
      _channel.invokeMethod<void>('resetAudioSampleRate');

  /// iOS: keeps [path] (a folder) out of iCloud and computer backups.
  Future<void> excludeFromBackup(String path) =>
      _channel.invokeMethod<void>('excludeFromBackup', {'path': path});

  /// iOS: "iPhone" or "iPad", used to describe the Files app location.
  Future<String?> deviceKind() => _channel.invokeMethod<String>('deviceKind');

  /// iOS: lets the user pick audio files or folders (in Files, iCloud Drive,
  /// on a USB drive) and copies the recordings among them (subfolders too)
  /// into [destination], reporting [ImportProgress] meanwhile. Null if
  /// cancelled.
  Future<ImportResult?> importRecordings(
    String destination, {
    required bool folder,
  }) async {
    final m = await _channel.invokeMapMethod<String, Object?>(
      'importRecordings',
      {'destination': destination, 'folder': folder},
    );
    if (m == null) return null;
    int count(String key) => (m[key] as int?) ?? 0;
    return (
      copied: count('copied'),
      skipped: count('skipped'),
      failed: count('failed'),
      full: count('full'),
      ignored: count('ignored'),
      cancelled: count('cancelled') > 0,
    );
  }

  /// Opens this app's page in the system settings (to allow the microphone).
  Future<void> openAppSettings() =>
      _channel.invokeMethod<void>('openAppSettings');

  /// Keeps the screen from going to sleep (during a long job), or lets it.
  Future<void> keepScreenOn(bool on) =>
      _channel.invokeMethod<void>('keepScreenOn', {'on': on});

  /// iOS: stops a running import after the file being copied.
  Future<void> cancelImport() => _channel.invokeMethod<void>('cancelImport');
}
