# Runbook

Procedures that worked on the owner's Mac. Get the iPhone's UDID from
`xcrun devicectl list devices` (never write it in this public repository).

## 1. Toolchain

```bash
export PATH="$HOME/flutter-3.47.5/bin:$PATH" LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
flutter --version   # Flutter 3.47.5, Dart 3.13.4
```

- `~/development/flutter` (3.44.4) is for other projects: don't upgrade or switch it.
- If `~/flutter-3.47.5` is missing:
  `git clone https://github.com/flutter/flutter.git -b 3.47.5 --depth 1 ~/flutter-3.47.5`.
- CocoaPods comes from Homebrew. The `LANG` setting stops its UTF-8 warning.

## 2. Check a change

```bash
dart format --output=none --set-exit-if-changed lib test packages/lame_mp3/lib packages/lame_mp3/test
flutter analyze
flutter test
```

- **Expected on macOS:** the `recording list` and `settings` golden tests fail (2.29% and
  1.51%, text anti-aliasing). They pass on CI. Anything else failing is real.
- **MP3 tests** need the host LAME library, or they're skipped:
  - `packages/lame_mp3/tool/build_host_lib.sh` needs CMake, and on macOS it writes
    `liblame_mp3.dylib`, which the app's tests don't load (only the plugin's own tests do).
  - On macOS, or without CMake, run this from `packages/lame_mp3`:

    ```bash
    mkdir -p build/host && L=src/lame/libmp3lame && cc -shared -fPIC -O2 -UNDEBUG -fvisibility=hidden \
      -DDART_SHARED_LIB -DHAVE_CONFIG_H -Isrc/lame -Isrc/lame/include -I$L src/lame_mp3.c \
      -w $L/VbrTag.c $L/bitstream.c $L/encoder.c $L/fft.c $L/gain_analysis.c $L/id3tag.c $L/lame.c \
      $L/newmdct.c $L/presets.c $L/psymodel.c $L/quantize.c $L/quantize_pvt.c $L/reservoir.c \
      $L/set_get.c $L/tables.c $L/takehiro.c $L/util.c $L/vbrquantize.c $L/version.c \
      -o build/host/liblame_mp3.so
    ```

  - The tests load `build/host/liblame_mp3.so`, whatever the platform. The output is
    git-ignored.

## 3. Put a build on the owner's iPhone (keeps every recording)

```bash
flutter build ios --release
xcrun devicectl device install app --device <UDID> build/ios/iphoneos/Runner.app
xcrun devicectl device process launch --terminate-existing --device <UDID> com.spencerchase.voicerecorder
```

- **Never `flutter install`:** it uninstalls first, which deletes the recordings. Never
  delete the app, either.
- Installing over the App Store copy works, and so does the reverse: an App Store or
  TestFlight version later installs over a development build. Recordings stay either way.
- **Launch fails with "Locked"** while the phone is locked; the install itself still worked.
- **Check the recordings** (development builds only):
  `xcrun devicectl device info files --device <UDID> --domain-type appDataContainer --domain-identifier com.spencerchase.voicerecorder --subdirectory Documents/Recorders`.
  Copy one off with `xcrun devicectl device copy from … --source Documents/Recorders/<name> --destination <file>`.
- **iOS Simulator:** use a dedicated "Voice Recorder Test" device. The "iPhone 18 Pro Max"
  simulator is also used by other projects.

## 4. Release to the App Store

1. **Version:** raise `version:` in `pubspec.yaml`. Every upload needs a higher build number;
   1.0.0 used builds 1 and 2; 1.0.1 uses build 4 (build 3 was a development
   build on the owner's phone only). Don't pass `--build-number`.
2. **Build:** run `flutter build ipa`. It signs automatically with the team, and the export
   step also checks the App Store profile.
3. **Open the archive:** `open build/ios/archive/Runner.xcarchive`.
4. **Upload:** in Organizer, choose **Distribute App → App Store Connect → Upload** and keep
   the defaults. The owner clicks this.
   - Every archive is named "Runner": select the one whose version and build match.
   - The command-line upload (`xcodebuild -exportArchive` with `destination` upload) fails
     with "Failed to Use Accounts".
5. **Submit** in App Store Connect (the owner signs in):
   - Create the new version (its version string must match the build's).
   - Add What's New and select the build once it shows **Ready to Submit** (about 5–30 min
     after upload).
   - Choose **Add for Review → Submit for Review**. The listing carries over from the last
     version.
6. **Tag** the uploaded commit and push it: `git tag -a vX.Y.Z -m "…" <commit>` then
   `git push origin vX.Y.Z`. Keep the repository public (LGPL).

## 5. Screenshots and icon

- **App Store screenshots:** `docs/app-store/*.jpg`, 1290 × 2796 (accepted in the 6.9" slot,
  and used for 6.5" too). Order: recording, playing, list, Recently deleted.
  - `test/tool/app_store_screenshots_test.dart` renders them: the iOS layout at 3× with a
    59 pt status bar and a 34 pt home indicator, and neutral sample recordings. A plain
    `flutter test` skips it. Give it an absolute output folder:

    ```bash
    flutter test test/tool/app_store_screenshots_test.dart --dart-define=SHOTS_OUT=/tmp/shots
    for n in 1-recording 2-playing 3-recording-list 4-recently-deleted; do
      sips -s format jpeg -s formatOptions 90 /tmp/shots/$n.png --out docs/app-store/$n.jpg
    done
    ```

  - On 2026-10-17 it reproduced the published images exactly, except the deletion date in
    Recently deleted, which is today's (the screen counts the 30 days from the real clock).
- **App icon:** `python3 tool/art/app_icon.py .` makes every icon (needs numpy and Pillow). The
  iOS master uses disc scale 0.96 and gradient window 18/108–90/108. The 1024 image must stay
  opaque RGB.
  - **Without Pillow** (the owner's Mac has no arm64 build), make the iOS icons with the Swift
    port, which gives the same pixels:

    ```bash
    swiftc -O tool/art/render_icon.swift -o /tmp/render_icon
    mkdir -p /tmp/icons && /tmp/render_icon ios . /tmp/icons
    /tmp/render_icon compare /tmp/icons/Icon-App-1024x1024@1x.png ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png
    ```

    Copy only the icons whose pixels changed (the PNG bytes always differ). A change to the
    artwork goes into both scripts; Android's icons still need the Python one.

## 6. Diagnose a recording problem on the phone

- **Get the file off the phone:**
  - Development build: copy the file off (section 3).
  - App Store build: share it from the app.
  - Then `afinfo <file>` gives its length.
- **Phone logs** for a time window (root needed, so the owner runs it; in zsh, `log` is a
  builtin):

  ```bash
  sudo /usr/bin/log collect --device-udid <UDID> --start 'YYYY-MM-DD HH:MM:SS' --output ~/Desktop/vr.logarchive
  ```

  Then search it for `Runner`, `mediaserverd`, `AVAudioSession` and route changes around the
  time.
- **The app's messages:** "The recording stopped unexpectedly" means the capture died and
  couldn't be started again (iOS MP3/WAV, from 1.0.1), or any capture loss (Android, M4A, and
  every format in 1.0.0, the version on the App Store).
  See `lib/src/audio/recorder_engine.dart`.
