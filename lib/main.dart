import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'src/app.dart';
import 'src/app_controller.dart';
import 'src/audio/playback.dart';
import 'src/audio/recorder_engine.dart';
import 'src/core/settings.dart';
import 'src/licenses.dart';
import 'src/platform/native_bridge.dart';
import 'src/storage/info_cache.dart';
import 'src/storage/recording_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  logUncaughtErrors();
  await applySystemUi();
  registerThirdPartyLicenses();

  final settings = await Settings.load();
  final native = NativeBridge();
  final RecordingStore store = Platform.isAndroid
      ? AndroidRecordingStore(native, settings)
      : IosRecordingStore(native);

  await configureAtLaunch();

  final controller = AppController(
    settings: settings,
    store: store,
    engine: RecordPluginEngine(),
    playback: JustAudioPlayback(),
    // iOS: a reset of the media services undoes the audio session's setup.
    mediaResets: Platform.isIOS
        ? AVAudioSession().mediaServicesWereResetStream
        : null,
    configureAudio: configureAudioSession,
    native: native,
    workDir: getApplicationSupportDirectory,
    isAndroid: Platform.isAndroid,
    // Out of backups: on Android through backup_rules.xml, on iOS by its
    // folder being excluded. (Not in Caches, which iOS may empty: for a
    // renamed AAC or FLAC recording it is the only place its date is kept.)
    info: RecordingInfoCache(
      file: () async {
        final support = await getApplicationSupportDirectory();
        if (!Platform.isIOS) return File('${support.path}/recording_info.json');
        final dir = await Directory('${support.path}/Info').create();
        try {
          await native.excludeFromBackup(dir.path);
        } catch (_) {}
        return File('${dir.path}/recording_info.json');
      },
    ),
  );
  runApp(VoiceRecorderApp(controller: controller));
  unawaited(controller.init());
}

/// Sets up the audio session ([appAudioSession]). A failure (iOS refuses
/// while its media services restart) mustn't keep the app from starting:
/// playback applies the session again before it plays, and the controller
/// once the media services are back.
@visibleForTesting
Future<void> configureAtLaunch([
  Future<void> Function() configure = configureAudioSession,
]) async {
  try {
    await configure();
  } catch (e) {
    debugPrint('Could not configure the audio session: $e');
  }
}

/// Errors nothing caught are logged (to the device's console) and the app
/// carries on. Flutter's own (a widget that failed to build) are still
/// presented as before.
@visibleForTesting
void logUncaughtErrors() {
  FlutterError.onError = (details) => FlutterError.presentError(details);
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Voice Recorder: uncaught error: $error\n$stack');
    return true;
  };
}
