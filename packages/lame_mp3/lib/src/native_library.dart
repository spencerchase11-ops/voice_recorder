import 'dart:ffi';
import 'dart:io';

/// Environment variable that overrides the path of the native library.
///
/// Used to run the tests on a development machine against a host build of
/// `src/` (see `tool/build_host_lib.sh`).
const String lameMp3LibraryEnvironmentVariable = 'LAME_MP3_LIBRARY';

/// Path of the native library to load instead of the platform default.
///
/// Takes precedence over [lameMp3LibraryEnvironmentVariable]. Only meant for
/// tests, and only effective if set before the first use of the package API.
String? lameMp3LibraryPathOverride;

/// Opens the `lame_mp3` library bundled with the app by the Flutter tooling.
DynamicLibrary openLameMp3Library() {
  final String? override =
      lameMp3LibraryPathOverride ??
      Platform.environment[lameMp3LibraryEnvironmentVariable];
  if (override != null && override.isNotEmpty) {
    return DynamicLibrary.open(override);
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('liblame_mp3.so');
  }
  if (Platform.isIOS || Platform.isMacOS) {
    try {
      // CocoaPods builds the plugin as a framework (`use_frameworks!`).
      return DynamicLibrary.open('lame_mp3.framework/lame_mp3');
    } on ArgumentError {
      // Statically linked pods: the symbols are part of the executable.
      return DynamicLibrary.process();
    }
  }
  throw UnsupportedError(
    'lame_mp3 is not available on ${Platform.operatingSystem}.',
  );
}
