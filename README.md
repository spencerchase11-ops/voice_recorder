# Voice Recorder

A rebuild of the classic 2016 Android voice recorder: red title bar, brushed-metal
background, chrome studio microphone, glossy record/play buttons. It is written in
Flutter and runs on **Android (Google Play)** and **iOS**.

Six screenshots of the original app are the spec: the Recorder with and
without a recording, the Recording list, Settings, the Delete dialog and the
Rename dialog. On the phone those
screenshots came from (1440×3120, 3.5× density, font scale 1.077), the golden
tests render every screen within a few pixels of the original. See
[docs/SPEC.md](docs/SPEC.md) for how the measurements were made.

## Features

| Screen | What it does |
| --- | --- |
| **Recorder** | Record and stop. The timer counts up, and the 10-square level meter shows the input level. "Remaining time" is worked out from free space and the chosen format. The play button plays or pauses the last recording. The bar at the bottom shows where the last recording is saved. The header buttons share, rename or delete it. Before the first recording, the header shows "Voice Recorder" without those buttons, the timer reads 00:00 and the play button is grey, like the original. |
| **Recording list** | All recordings, newest first, with date and size. Tap a row to select it: it turns orange and shows a seek bar. The row's play button plays or pauses it. The bottom bar deletes, renames or shares the selected file. |
| **Settings** | Recording type (MP3, WAV, M4A) and quality (four levels). The recordings folder. "Rate 5 stars" and About, which has the licenses. |

Recording formats (all mono):

| Quality | MP3 | WAV (16-bit PCM) | M4A (AAC-LC) |
| --- | --- | --- | --- |
| Low quality | 16 kHz, 32 kbit/s | 8 kHz | 16 kHz, 32 kbit/s |
| Medium quality | 22.05 kHz, 64 kbit/s | 16 kHz | 22.05 kHz, 64 kbit/s |
| High quality | 44.1 kHz, 128 kbit/s | 22.05 kHz | 44.1 kHz, 96 kbit/s |
| **The best quality** (default) | 44.1 kHz, 160 kbit/s | 44.1 kHz | 44.1 kHz, 128 kbit/s |

MP3 at "The best quality" is the original app's default. A 33:57 recording
from the original is 39,819 KB, which works out to 160 kbit/s. MP3 is encoded on the device
with [LAME](https://lame.sourceforge.io), which lives in the local plugin
[`packages/lame_mp3`](packages/lame_mp3).

### Where recordings are saved

- **Android:** a folder you choose once, through the system folder picker (the
  Storage Access Framework). The first time you record, the app explains this
  and opens the picker at `/storage/emulated/0/Recorders`. That is the
  original app's folder, so choosing it keeps all your old recordings in the
  list. Google Play doesn't let apps like this one read shared storage
  directly, so the picker is the Play-compliant way to reach the same folder.
  You can change the folder under **Settings → Folder**.
- **iOS:** `Documents/Recorders` inside the app. It shows up in the Files app
  under *On My iPhone → Voice Recorder → Recorders*, and in Finder when the
  phone is connected. **Settings → Folder** opens it in Files.

A recording is written to the app's private storage while it runs. It is
moved into the folder when you stop. If the app is killed while recording,
MP3 and WAV recordings are saved on the next launch; WAV headers are repaired.
M4A recordings can't be saved this way, because the file is only finished
when recording stops.

### Recording in the background

- **Android:** while recording, a foreground service of type `microphone`
  shows an ongoing notification with a chronometer, and holds a partial wake lock.
  The Flutter engine outlives the activity (`MainActivity` keeps it in
  `FlutterEngineCache`). Leaving the app with Back, or swiping it away from
  Recents, doesn't stop a recording.
- **iOS:** the `audio` background mode keeps recording with the screen locked
  or while you use other apps.
- Phone calls and other audio interruptions pause the recording and the timer.
  Recording resumes when the interruption ends.

## Differences from the original

The screenshots only show the app sitting idle, so a few things had to be
decided:

- While recording, the record button becomes a stop button and the
  microphone's red light pulses. The play button becomes pause while playing.
- The original's "no ads" badge on the Recorder screen and its **Remove ads**
  setting sold an ad-free premium version. This version is free and has no
  ads, so both are left out.
- **Rate 5 stars** opens the Play Store listing on Android. On iOS it opens
  the App Store review page once `AppConfig.appStoreId` is set; until then it
  shows a toast.
- The rename dialog opens without the keyboard, like in the screenshot. Tap
  the field to edit. The characters `\ / : * ? " < > |` can't be typed.
- All artwork was drawn from scratch to match the screenshots, nothing was
  copied from the original APK. The microphone, metal, buttons and app icon
  are procedural renders (`tool/art/`). The icons are outlines from
  open-licensed icon fonts plus a few hand-drawn paths.

## Building

You need Flutter **3.47.5** (Dart 3.13), which is what this was built and
tested with, and:

- **Android:** Android Studio or the command-line tools, JDK 17, and the
  Android SDK. Gradle downloads the NDK and CMake that the LAME plugin needs.
- **iOS:** a Mac with Xcode 16 or newer and CocoaPods.

```sh
flutter pub get
flutter run                      # on a connected phone or emulator
flutter build appbundle          # Android App Bundle for Google Play
flutter build ipa                # iOS archive for App Store Connect (needs signing)
```

### Before publishing

1. **App id.** Both platforms use `com.spencerchase.voicerecorder`
   (`android/app/build.gradle.kts`, and `PRODUCT_BUNDLE_IDENTIFIER` in
   `ios/Runner.xcodeproj`). Change it before the first upload if you want a
   different one; it can't change afterwards.
2. **Android signing.** Create an upload key and an `android/key.properties`
   file (git ignores it):
   ```properties
   storePassword=...
   keyPassword=...
   keyAlias=upload
   storeFile=/absolute/path/to/upload-keystore.jks
   ```
   Without this file, release builds are signed with the debug key. That's
   fine for testing, but Play won't accept those builds.
3. **iOS signing.** Open `ios/Runner.xcworkspace` in Xcode and choose your team
   under *Signing & Capabilities*.
4. **App Store id.** Set `AppConfig.appStoreId` in `lib/src/config.dart` once
   the app exists in App Store Connect. This makes "Rate 5 stars" work on iOS.
5. **Store forms.**
   - *Google Play:* the app uses a `microphone` foreground service, so declare
     it under *App content → Foreground service permissions*: "records audio
     that the user started, until the user stops it". The app collects no
     data, so the Data safety answer is "no data collected or shared". Play
     requires a privacy policy for apps that use the microphone:
     [PRIVACY.md](PRIVACY.md) describes what this code does. Review it and
     host it somewhere public.
   - *App Store:* the privacy "nutrition label" is "Data Not Collected".
     `ios/Runner/PrivacyInfo.xcprivacy` already declares the free-disk-space
     reads (for "Remaining time") and file-date reads (for the list).
6. **LGPL.** LAME is LGPL-licensed. The app shows its license under
   *Settings → About → Licenses* and says where its source is. See
   [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for what the LGPL expects
   from a published app.

## Tests

```sh
packages/lame_mp3/tool/build_host_lib.sh   # once: LAME for the host (needs CMake), for the MP3 test
flutter test                              # unit, widget, controller and golden tests
(cd packages/lame_mp3 && flutter test)    # encoder plugin tests
```

- `test/golden/` renders every screen on the reference phone and compares it
  with `test/golden/goldens/*.png`, allowing 1% of pixels to differ. After an
  intended visual change, run `flutter test --update-goldens test/golden`.
- `python3 tool/compare_goldens.py <dir-with-original-screenshots> [out]`
  (needs Pillow and NumPy) puts each golden next to the original screenshot,
  with a difference image, and prints the mean pixel difference. The current
  values are 3.1 to 4.2 (out of 255) for the dialogs, list and settings, and
  6.5 to 7.1 for the Recorder, where the microphone grille's hole pattern
  differs.
  The left-out ads badge and "Remove ads" row count toward these numbers.
  `tool/align_check.py` measures how far a single element is off, in pixels.
- `test/widget/flows_test.dart` taps through the app like a user would:
  record and stop, the first-run folder prompt, missing microphone access,
  play, delete, rename, list selection, and settings.

CI (`.github/workflows/ci.yml`) runs formatting, analysis and all tests. It
also builds a release APK and uploads it as an artifact, signed with the debug
key: fine for installing on your own phone. The iOS build (no code signing)
runs on `main` and on manual runs.

## Project layout

```
lib/
  main.dart                  wiring: settings, storage, audio session, controller
  src/app_controller.dart    app state: recording, playback, files, remaining time
  src/audio/                 recorder engine (record plugin), MP3/WAV writers, playback (just_audio)
  src/storage/               Android (Storage Access Framework) and iOS (Documents) storage
  src/core/                  formats, settings, text formats (timer, sizes, dates)
  src/ui/spec.dart           every measured size, colour and font
  src/ui/screens/            Recorder, Recording list, Settings
  src/ui/dialogs/            Holo dialogs (delete, choices, messages) and the iOS-style rename dialog
  src/ui/widgets/            text with Android metrics, bars, timer box, level meter, glossy buttons
android/app/src/main/kotlin/ folder picker and file access, foreground service
ios/Runner/AppDelegate.swift free space and device name
packages/lame_mp3/           LAME MP3 encoder as a Flutter FFI plugin
tool/                        artwork generators and screenshot comparison tools
```
