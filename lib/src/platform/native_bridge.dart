import 'package:flutter/services.dart';

/// Free space on Android, see [NativeBridge.storageSpace].
typedef StorageSpace = ({int destination, int internal, bool sameVolume});

/// Calls into the small amount of platform code the app needs
/// (android/app/src/main/kotlin/.../MainActivity.kt and ios/Runner/AppDelegate.swift).
class NativeBridge {
  const NativeBridge([
    this._channel = const MethodChannel(
      'com.spencerchase.voicerecorder/native',
    ),
  ]);

  final MethodChannel _channel;

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

  Future<List<Map<Object?, Object?>>> listFolder(String treeUri) async =>
      (await _channel.invokeListMethod<Map<Object?, Object?>>('listFolder', {
        'treeUri': treeUri,
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

  Future<void> shareDocument(String documentUri, String mimeType) =>
      _channel.invokeMethod<void>('shareDocument', {
        'documentUri': documentUri,
        'mimeType': mimeType,
      });

  /// Keeps the process (and microphone access) alive while recording.
  Future<void> startRecordingService({
    required String title,
    required String text,
  }) => _channel.invokeMethod<void>('startRecordingService', {
    'title': title,
    'text': text,
  });

  Future<void> stopRecordingService() =>
      _channel.invokeMethod<void>('stopRecordingService');

  // ---------------------------------------------------------------- both
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

  /// iOS: undoes the preferred sample rate a recording set on the audio
  /// session, so later playback isn't resampled to a low rate.
  Future<void> resetAudioSampleRate() =>
      _channel.invokeMethod<void>('resetAudioSampleRate');

  /// iOS: "iPhone" or "iPad", used to describe the Files app location.
  Future<String?> deviceKind() => _channel.invokeMethod<String>('deviceKind');

  /// Opens this app's page in the system settings (to allow the microphone).
  Future<void> openAppSettings() =>
      _channel.invokeMethod<void>('openAppSettings');
}
