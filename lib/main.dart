import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
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
  await applySystemUi();
  registerThirdPartyLicenses();

  final settings = await Settings.load();
  final native = NativeBridge();
  final RecordingStore store = Platform.isAndroid
      ? AndroidRecordingStore(native, settings)
      : IosRecordingStore(native);

  await _configureAudioSession();

  final controller = AppController(
    settings: settings,
    store: store,
    engine: RecordPluginEngine(),
    playback: JustAudioPlayback(),
    native: native,
    workDir: getApplicationSupportDirectory,
    isAndroid: Platform.isAndroid,
    info: RecordingInfoCache(
      file: () async => File(
        '${(await getApplicationSupportDirectory()).path}/recording_info.json',
      ),
    ),
  );
  runApp(VoiceRecorderApp(controller: controller));
  unawaited(controller.init());
}

/// Play back through the loudspeaker even with the ring/silent switch on and
/// allow recording at any time. No Bluetooth hands-free profile: recordings
/// use the phone's microphone and headphones keep full playback quality.
/// Keep in sync with `_iosConfig` in lib/src/audio/recorder_engine.dart.
Future<void> _configureAudioSession() async {
  final session = await AudioSession.instance;
  await session.configure(
    AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.defaultToSpeaker |
          AVAudioSessionCategoryOptions.allowBluetoothA2dp,
      avAudioSessionMode: AVAudioSessionMode.defaultMode,
      androidAudioAttributes: const AndroidAudioAttributes(
        contentType: AndroidAudioContentType.speech,
        usage: AndroidAudioUsage.media,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
      // Recordings are speech: pause for a navigation prompt or similar
      // (and resume after it) instead of playing over it.
      androidWillPauseWhenDucked: true,
    ),
  );
}
