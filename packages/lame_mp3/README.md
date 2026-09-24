# lame_mp3

A Flutter FFI plugin for Android and iOS that encodes 16-bit PCM audio to MP3.
It uses the [LAME](https://lame.sourceforge.io) 4.0 encoder library, which is
vendored unmodified in `src/lame`, plus a small C wrapper (`src/lame_mp3.c`)
that Dart calls through `dart:ffi`.

```dart
import 'package:lame_mp3/lame_mp3.dart';

final encoder = LameMp3Encoder(sampleRate: 44100, bitrateKbps: 128);
try {
  await for (final Int16List chunk in pcmChunks) { // e.g. from the recorder
    file.add(encoder.encode(chunk));
  }
  file.add(encoder.flush());
} finally {
  encoder.close();
}
```

## API

```dart
class LameMp3Encoder implements Finalizable {
  LameMp3Encoder({
    required int sampleRate, // Hz, one of supportedSampleRates
    int channels = 1,        // 1 = mono, 2 = joint stereo (interleaved input)
    required int bitrateKbps, // one of supportedBitrates(sampleRate)
    int quality = 5,         // LAME's algorithm quality: 0 (best, slowest) to 9 (fastest)
  });

  static const List<int> supportedSampleRates;
  static List<int> supportedBitrates(int sampleRate);
  static String get lameVersion; // "4.0"

  final int sampleRate, channels, bitrateKbps, quality;
  bool get isClosed;

  Uint8List encode(Int16List samples); // interleaved if stereo; may return an empty list
  Uint8List flush();                   // call once, at the end
  void close();                        // idempotent; frees the native memory
}
```

- Invalid arguments throw an `ArgumentError`. This includes a bitrate that is
  not valid at the sample rate, and stereo input with an odd length.
  Calling `encode`/`flush` after `flush` or `close` throws a `StateError`.
  So does a failure inside LAME.
- The encoder never resamples, and every frame uses the requested bitrate:

  | MPEG version | Sample rates (Hz)     | Bitrates (kbit/s)                                   |
  | ------------ | --------------------- | --------------------------------------------------- |
  | MPEG-1       | 32000, 44100, 48000   | 32 40 48 56 64 80 96 112 128 160 192 224 256 320    |
  | MPEG-2       | 16000, 22050, 24000   | 8 16 24 32 40 48 56 64 80 96 112 128 144 160        |
  | MPEG-2.5     | 8000, 11025, 12000    | 8 16 24 32 40 48 56 64                              |

- Output: the bytes from all `encode` calls plus `flush`, concatenated, form a
  complete CBR MP3 file. It contains MPEG Layer III frames only: no ID3 tag,
  and no Xing/Info/LAME header frame. So it can be written to a file or socket
  as it is produced, and no seek back is needed at the end. Players compute
  the duration from the constant bitrate. The stream starts with LAME's fixed
  encoder delay of 576 samples, and the last frame is padded with silence.
  Without the header frame, players cannot trim that delay and padding.
- `encode` runs synchronously on the calling isolate. On a desktop x86_64
  host, LAME encodes 44.1 kHz mono at 128 kbit/s about 250 times faster than
  real time, so recorder-sized chunks are cheap. Phones are slower. Use a
  background isolate for long files.
- Each encoder holds about 400 KB of native memory. Call `close()`: a
  `NativeFinalizer` also frees it, but only once the object is garbage
  collected.

## Native build

- **Android**: Gradle builds `src/CMakeLists.txt` with the NDK for the ABIs
  that the app builds (no `abiFilters` here). The library is linked with
  16 KB page alignment, for Android 15 devices with 16 KB pages.
- **iOS**: CocoaPods compiles only files inside `ios/`. So `ios/Classes`
  holds one forwarder `.c` file per C file of `src/`, each containing only an
  `#include` of the real file. Each file stays a separate compilation unit,
  because LAME's files define static symbols with the same names. See
  `ios/lame_mp3.podspec` for the header paths and defines. No LAME header is
  part of the pod.
- LAME is configured by `src/lame/config.h`, which replaces the file that
  `./configure` would generate. Every ABI runs LAME's portable C code: no
  SSE/NASM, no IEEE-754 bit tricks, no fast-log tables, and no decoder. The
  build uses `-O2` in every configuration. LAME's `assert()`s are compiled
  out in app builds (`NDEBUG`). Only the five `lame_mp3_*` functions of
  `src/lame_mp3.h` are exported; LAME's own symbols are hidden.
- `src/lame/PATCHES.md` lists what was vendored and how it was verified
  (there are no source patches), and how to update LAME.

## Tests on a development machine

The tests run on the host (Linux, or macOS), against a host build of the
same CMake project:

```sh
tool/build_host_lib.sh   # CMake -> build/host/liblame_mp3.so; prints its path
flutter test
```

The tests find `build/host/` by themselves. To use another build, set
`LAME_MP3_LIBRARY` (the Dart code loads that path instead of the platform
default):

```sh
LAME_MP3_LIBRARY="$(tool/build_host_lib.sh)" flutter test
```

If no library is found, the tests that need it are skipped, with a message.
The host build keeps LAME's `assert()`s enabled. The tests decode the frame
headers of the output and check the MPEG version, bitrate, sample rate,
channel mode, frame count and duration. They also check that the output does
not depend on how the input is chunked, every legal sample rate / bitrate /
channel combination, and misuse errors.

After changing `src/lame_mp3.h`, regenerate
`lib/lame_mp3_bindings_generated.dart` with
`dart run ffigen --config ffigen.yaml`. This needs libclang.

## License

The plugin's own code (Dart, the C wrapper, the build files) is MIT-licensed;
see `LICENSE`. LAME, in `src/lame`, is licensed under the LGPL-2.0-or-later,
so the native library built from `src/` is distributed under the LGPL.

The LGPL allows the use of LAME in closed-source apps. An app that ships it
must include the license text, and must offer LAME's source code (with any
modifications). It must also let users replace LAME with a modified version,
for example by relinking. That is simple with Android's separate
`liblame_mp3.so`, but needs more care for iOS App Store builds. If in doubt,
get legal advice.
