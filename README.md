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
| **Recorder** | Record and stop. While recording, the play button's place holds pause/resume; a paused recording's timer blinks. The timer counts up, and the 10-square level meter shows the input level. "Remaining time" is worked out from free space and the chosen format. The play button plays or pauses the last recording. The bar at the bottom shows where the last recording is saved. The header buttons share, rename or delete it. Before the first recording, the header shows "Voice Recorder" without those buttons, the timer reads 00:00 and the play button is grey, like the original. |
| **Recording list** | All recordings with date, length and size, newest first or in another order (the sort button). The search button finds recordings by name or date ("2026-09"). Tap a row to open it: it turns orange and shows a seek bar, back/forward 10 seconds and the playback speed (1x, 1.25x, 1.5x, 2x). The row's play button plays or pauses it. The bottom bar deletes, renames or shares the open row. A long press starts selecting several rows, to delete or share them together. |
| **Settings** | Recording type (MP3, WAV, M4A) and quality (four levels). Noise reduction. The recordings folder. Recently deleted. Lock screen controls and the playback speed. On iPhone, an import of recordings from the Files app. "Rate 5 stars" and About, which has the licenses. |
| **Recently deleted** | Deleted recordings stay here for 30 days. Restore one, delete one for good, or empty it. Right after a delete, a toast also offers Undo. |

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
  phone is connected. **Settings → Folder** opens it in Files, and
  **Settings → Import recordings** copies MP3, WAV, M4A, AAC and FLAC files
  (or whole folders of them, subfolders included) from Files, iCloud Drive or
  a USB drive into it.

  Importing a whole library (say 2,500 recordings moved over from an Android
  phone): pick the folder that holds them. Settings shows how far it has got
  and keeps the screen on; at the end it says how many were imported, how
  many were already there and how many couldn't be copied. From *On My
  iPhone* the copies are clones: instant, and they take no extra space. From
  iCloud Drive each recording is downloaded first. If the import is
  interrupted (the app closed, the phone out of space), run it again: what is
  already there is skipped. The originals stay where they were; delete them
  in Files once you're happy with the import. Renamed recordings keep their
  date only if it was stored in them (see below) or their file date survived
  the move.

A recording is written to the app's private storage while it runs. It is
moved into the folder when you stop. If the app is killed while recording,
MP3 and WAV recordings are saved on the next launch; WAV headers are repaired.
An M4A file is only playable once it is finished, so an M4A recording that
was cut off can't be recovered; the app says so instead of saving a broken
file. If the folder can't be written to when you stop (for example, Android
lost access to it), the recording is kept and the app asks for the folder
again.

A deleted recording gets a hidden name in the same folder
(`.vr-deleted-<time>-<name>`), so it is out of the list, file managers and music
apps, and it can come back. After 30 days the app deletes it for good (it
checks when it starts and every few hours while it runs). Recently deleted
belongs to the folder: after switching to another folder, what was deleted in
the old one stays there, hidden, and comes back into Recently deleted when you
switch back. The app can't clean up when it is uninstalled, so empty Recently
deleted first if you uninstall it; otherwise those files stay in the folder,
hidden.

### Recording dates

New recordings are named after the time they started
(`2026_09_16_16_37_26.mp3`), and that time is also stored inside the file:

| Format | Where the date is stored |
| --- | --- |
| MP3 | an ID3v2.4 tag at the start of the file, frame `TDRC` (recording time) |
| WAV | a `LIST`/`INFO` chunk after the audio, field `ICRD` (creation date) |
| M4A | the movie header's creation time (`moov`/`mvhd`) |

So a recording keeps its place in the list whatever it is renamed to, and
other apps (music players, file managers, computers) can show the date of a
new recording too.

When a recording without a stored date is renamed (for example one made by
the original app), the app adds it first: from the name if it is a timestamp,
else from the file's modification time. MP3 files get a small ID3v2.4 tag at
the end (before an ID3v1 tag, if there is one), WAV files a `LIST` chunk, and
M4A files have their creation time set; the audio itself isn't touched. A
write that fails halfway (a full storage) is undone. Other apps read the WAV
and M4A dates; a tag at the end of an MP3 is standard, but most players only
look at the start, so there the date is mainly for this app. Files that can't
hold a date (AAC, AMR, OGG, Opus, FLAC, or a damaged file) keep it in the
app's memory of dates and lengths only.

The list takes each recording's date from, in this order: the date stored in
the file, the time in its name, its modification time. One exception: the
original app's M4A files store the time a recording *ended*, so when a
timestamp name is up to the recording's length earlier, the name wins. Dates
and lengths are read from the files when they are first shown, and
remembered between launches (`recording_info.json` in the app's private
storage, left out of backups), so a folder of thousands of recordings opens
quickly.

"Remaining time" is how long you can record and still save the file. On
Android a recording is copied into the folder when it stops, so on internal
storage it can use at most half of the free space. When less than 30 seconds
are left, a recording stops and is saved, and a new one won't start.

### Recording in the background

- **Android:** while recording, a foreground service of type `microphone`
  shows an ongoing notification with a chronometer, and holds a partial wake lock.
  The Flutter engine outlives the activity (`MainActivity` keeps it in
  `FlutterEngineCache`). Leaving the app with Back, or swiping it away from
  Recents, doesn't stop a recording.
- **iOS:** the `audio` background mode keeps recording with the screen locked
  or while you use other apps.
- **Interruptions.** On Android nothing pauses a recording: other apps'
  sounds and alarms are recorded along with everything else, and during a
  phone call Android gives the app silence. On iPhone, calls and Siri pause
  the recording and the timer, and recording resumes when they end (or when
  you return to the app, if iOS didn't resume it; during a call it stays
  paused).
- If recording stops on its own, what was recorded is saved and the app
  says so (when you're back in the app, if it happened in the background).
  That happens after a system error, when audio stops arriving for 5 seconds,
  when the storage can't be written any more, or when a WAV recording reaches
  the format's limit of about 13 hours.
- **Pause.** A paused recording stays one file; nothing is recorded until it
  is resumed. On iPhone, a recording you paused stays paused after a call.
  On Android, the recording notification has Pause/Resume and Stop buttons.
- **Other apps' audio.** Music from other apps pauses while you record and
  can continue afterwards (Android asks for exclusive audio focus for the
  length of the recording; on iPhone the app releases its audio session when
  a recording stops, which tells the other app it may go on).
- **Noise reduction** (Settings) uses the system's noise suppressor on
  Android and voice processing on iPhone. It applies to MP3 and WAV
  recordings.
- **Shortcut.** Long-press the app icon and choose *Start recording*
  (Android; some launchers show *Record*) or *Record* (iPhone) to open the
  app and start recording.

### Playback in the background

With **Settings → Lock screen controls** on (the default), a recording keeps
playing when you leave the app or lock the phone:

- **Android:** a foreground service of type `mediaPlayback` with a media
  session shows a notification (back 10 s, play/pause, forward 10 s and a
  seek bar) and the same controls on the lock screen and, from Android 13, in
  the media player in Quick Settings. Headset and Bluetooth buttons work
  (next/previous skip 10 seconds). After 10 minutes paused (sleep time
  counts), or when you dismiss the player (Android 14 and later), the
  controls go away; the recording stays paused where it was in the app, and
  playing it again brings them back.
- **iOS:** the lock screen and Control Center show the recording ("Now
  Playing") with the same controls.

With it off, there are no such controls and playback pauses when you leave
the app or lock the phone.

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
- Recordings always use the phone's own microphone, also with Bluetooth
  headphones connected; the headphones keep full quality for playback.
- On iOS the app is iPhone-only, like the original phone app. iPads run it in
  iPhone mode, so it always stays in portrait.
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
   - *Google Play:* the app uses two foreground services, so declare both under
     *App content → Foreground service permissions*: `microphone`, "records
     audio that the user started, until the user stops it", and
     `mediaPlayback`, "keeps playing a recording the user started when the
     app is in the background, with playback controls". The app collects no
     data, so the Data safety answer is "no data collected or shared". Play
     requires a privacy policy for apps that use the microphone:
     [PRIVACY.md](PRIVACY.md) describes what this code does. Review it and
     host it somewhere public.
   - *App Store:* the privacy "nutrition label" is "Data Not Collected".
     `ios/Runner/PrivacyInfo.xcprivacy` already declares the free-disk-space
     reads (for "Remaining time"), file-date reads (for the list) and the
     settings storage (UserDefaults). `Info.plist` says the app uses no
     encryption beyond the system's, so uploads skip that question.
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
  values are 3.1 to 3.2 (out of 255) for the dialogs and 6.5 to 7.1 for the
  Recorder, where the microphone grille's hole pattern differs. The list
  (14.6) and Settings (11.6) have grown since the upgrades: the list header's
  sort and search buttons, the open row's playback buttons (which make it
  10 dp taller, moving the rows below it) and the new settings rows.
  The left-out ads badge and "Remove ads" row count toward these numbers.
  `tool/align_check.py` measures how far a single element is off, in pixels.
- `test/widget/flows_test.dart` and `test/widget/upgrades_flows_test.dart`
  tap through the app like a user would: record, pause and stop, the
  first-run folder prompt, missing microphone access, a recording that can't
  be saved or stops on its own, play, seek, skip and speed, delete and undo,
  rename, search, sort, selecting several recordings, Recently deleted, a
  list of 2,500 recordings, the Record shortcut and settings.
- `test/audio/audio_info_test.dart` reads and writes recording dates in MP3
  (ID3v2.2 to 2.4, appended tags, ID3v1), WAV (`LIST`, `bext`) and M4A
  files, including damaged ones.

CI (`.github/workflows/ci.yml`) runs formatting, analysis and all tests.
When they pass, it also builds a release APK and uploads it as an artifact.
The APK is signed with a test key that CI keeps in the Actions cache, so each
new test APK installs as an update over the last one. GitHub deletes a cache
that goes unused for 7 days, so a weekly run keeps it in use; if it is lost
anyway, the next APK gets a new key and the test app has to be uninstalled
once before it installs. The test key is fine for your own phone, not for
Play uploads. The APK's version code is the CI run number, so *Settings →
About* shows which test build is installed. The iOS build (no code signing)
runs when started by hand (*Actions → CI → Run workflow*) and on `main`.

Moving between a test APK and the Google Play version (either way) needs an
uninstall first, because they are signed with different keys. Your
recordings stay in the folder; you choose the folder once more, and the
settings start over.

## Project layout

```
lib/
  main.dart                  wiring: settings, storage, audio session, controller
  src/app_controller.dart    app state: recording, playback, files, remaining time, lock-screen controls
  src/audio/                 recorder engine (record plugin), MP3/WAV writers, playback (just_audio),
                             recording dates and lengths in the files (audio_info.dart)
  src/storage/               Android (Storage Access Framework) and iOS (Documents) storage,
                             Recently deleted, the cache of dates and lengths
  src/core/                  formats, settings, text formats (timer, sizes, dates)
  src/ui/spec.dart           every measured size, colour and font
  src/ui/screens/            Recorder, Recording list, Settings, Recently deleted
  src/ui/dialogs/            Holo dialogs (delete, choices, messages) and the iOS-style rename dialog
  src/ui/widgets/            text with Android metrics, bars, timer box, level meter, glossy buttons
android/app/src/main/kotlin/ folder picker and file access, recording and playback services, shortcut
ios/Runner/AppDelegate.swift free space, device name, Now Playing controls, import from Files
packages/lame_mp3/           LAME MP3 encoder as a Flutter FFI plugin
tool/                        artwork generators and screenshot comparison tools
```
