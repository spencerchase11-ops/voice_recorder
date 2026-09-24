import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'src/app.dart';
import 'src/app_controller.dart';
import 'src/audio/playback.dart';
import 'src/audio/recorder_engine.dart';
import 'src/core/settings.dart';
import 'src/licenses.dart';
import 'src/platform/native_bridge.dart';
import 'src/storage/recording_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  registerThirdPartyLicenses();

  final settings = await Settings.load();
  const native = NativeBridge();
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
  );
  runApp(VoiceRecorderApp(controller: controller));
  unawaited(controller.init());
}

/// Play back through the loudspeaker even with the ring/silent switch on and
/// allow recording at any time.
Future<void> _configureAudioSession() async {
  final session = await AudioSession.instance;
  await session.configure(
    AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.defaultToSpeaker |
          AVAudioSessionCategoryOptions.allowBluetooth |
          AVAudioSessionCategoryOptions.allowBluetoothA2dp,
      avAudioSessionMode: AVAudioSessionMode.defaultMode,
      androidAudioAttributes: const AndroidAudioAttributes(
        contentType: AndroidAudioContentType.speech,
        usage: AndroidAudioUsage.media,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
    ),
  );
}
