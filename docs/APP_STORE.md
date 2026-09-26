# Publishing on the App Store

Everything the app itself needs is in place: bundle id
`com.spencerchase.voicerecorder`, version 1.0.0, iPhone only, portrait, the
icons (no transparency), the microphone text, background audio, the privacy
manifest and the encryption answer (`ITSAppUsesNonExemptEncryption` = NO, so
uploads skip that question). What's left is done on your Mac and in App
Store Connect.

## 1. Build it on your Mac

You need Flutter **3.47.5** (`flutter --version`) and CocoaPods
(`pod --version`). If either is missing:

```sh
git clone https://github.com/flutter/flutter.git -b 3.47.5 --depth 1 ~/flutter-3.47.5
export PATH="$HOME/flutter-3.47.5/bin:$PATH"   # add to ~/.zshrc to keep it
brew install cocoapods
```

Get the code:

```sh
git clone https://github.com/spencerchase11-ops/voice_recorder.git
cd voice_recorder
flutter pub get
open ios/Runner.xcworkspace
```

In Xcode: select **Runner** (the blue project icon) → target **Runner** →
**Signing & Capabilities** → tick *Automatically manage signing* and choose
your **Team**. Xcode registers the bundle id for you. If it says the id is
taken, change *Bundle Identifier* there (e.g. add your own suffix).

## 2. Put it on your iPhone

With the iPhone plugged in and unlocked (iOS 16 and later: *Settings →
Privacy & Security → Developer Mode* on, then restart):

```sh
flutter run --release
```

Pick the iPhone if asked. Or press ▶ in Xcode with the iPhone selected as
the destination.

This copy is a normal install of the app: TestFlight and App Store versions
later install over it and keep everything in it, recordings included (same
bundle id). Never delete the app once your recordings are imported, since
the imported copies live inside it.

## 3. Create the app in App Store Connect

[appstoreconnect.apple.com](https://appstoreconnect.apple.com) → **Apps** →
**+** → **New App**:

- Platform: iOS
- Name: must be unique on the App Store; "Voice Recorder" alone is taken.
  Suggestions: **Voice Recorder – Classic**, **Classic Voice Recorder**,
  **Voice Recorder: Retro Mic**. (The name under the icon on the phone stays
  "Voice Recorder".)
- Primary language: English (U.S.)
- Bundle ID: `com.spencerchase.voicerecorder` (it appears once Xcode has
  registered it)
- SKU: `voice-recorder-ios`

Then, under **Pricing and Availability**, untick *Make this app available*
for Mac computers with Apple silicon and for Apple Vision Pro. The app is
made for iPhone (the folder picker and recording are untested there).

## 4. Upload the build

```sh
flutter build ipa
open build/ios/archive/Runner.xcarchive
```

Xcode's Organizer opens: **Distribute App** → **App Store Connect** →
**Upload**, and accept the defaults. (Or drag `build/ios/ipa/*.ipa` into
Apple's Transporter app.) Each later upload needs a higher build number:
`flutter build ipa --build-number=2`, then 3, and so on; raise the version
itself in `pubspec.yaml` (`version: 1.0.1+3`).

After 10–30 minutes the build shows under **TestFlight**, where you can also
install it on your iPhone before release.

## 5. The listing

Copy these into the version page of App Store Connect.

**Subtitle** (30 max): One-tap MP3 audio recorder

**Promotional text** (170 max):
A classic voice recorder: one red button, a big timer, MP3, WAV or M4A.
Keeps recording with the screen locked. No account, no ads, no tracking.

**Description:**

```
Voice Recorder is a simple, dependable recorder with a classic look: a chrome studio microphone, a big timer and one red button.

RECORD
• Tap once to record, tap again to stop. Pause and resume in the same file.
• MP3, WAV or M4A, in four quality levels.
• Keeps recording with the screen locked or while you use other apps.
• A level meter shows your voice, and "Remaining time" how long you can still record.
• Noise reduction for voices in noisy rooms (MP3 and WAV).
• Start recording from the Home Screen: touch and hold the app icon, then Record.

LISTEN
• All your recordings with their date, length and size, newest first or sorted your way.
• Search by name or date.
• Skip back or forward 10 seconds, and play at up to 2x speed.
• Keeps playing in the background, with controls on the Lock Screen.

ORGANIZE
• Rename, share or delete recordings, one or many at a time.
• Deleted recordings stay in Recently Deleted for 30 days, with Undo right after a delete.
• Your recordings are ordinary files in the Files app (On My iPhone › Voice Recorder), so you can copy them anywhere.
• Import recordings from Files, iCloud Drive or a USB drive, whole folders at a time.

PRIVATE
• No account, no ads, no tracking. Your recordings stay on your iPhone.
```

**Keywords** (100 max):
`voice memo,audio,mp3,dictaphone,record,lecture,meeting,notes,interview,sound,mic,wav,m4a,memos`

**Screenshots** (iPhone 6.9" display; these are 1290 × 2796, which that
slot accepts, and App Store Connect scales them for smaller iPhones):
`docs/app-store/1-recording.jpg`, `2-playing.jpg`, `3-recording-list.jpg`,
`4-recently-deleted.jpg`. Or take your own on the iPhone (side button +
volume up) once your recordings are in; a Pro Max or Plus iPhone gives the
right size.

**Support URL:** https://github.com/spencerchase11-ops/voice_recorder/issues

**Privacy Policy URL** (under *App Privacy*):
https://github.com/spencerchase11-ops/voice_recorder/blob/HEAD/PRIVACY.md

**Marketing URL** (optional): https://github.com/spencerchase11-ops/voice_recorder

**Category:** Utilities (secondary: Productivity). **Price:** Free.

**Age rating:** answer None / No to every question: 4+.

**App Privacy:** Data Not Collected.

**Content rights:** the app doesn't show or access third-party content.

**Copyright:** 2026 and your name.

**App Review information:** no sign-in needed. Notes:

```
No account or login. To try it: tap the red record button (allow the microphone), speak for a few seconds, then tap the stop button. The recording is saved and its location shown at the bottom; the play button plays it. "Recording list" shows all recordings, to play, rename, share or delete them.

Background audio: a recording continues while the screen is locked or another app is open, and playback continues with Lock Screen controls when Settings > Lock screen controls is on (the default).

Settings > Import recordings copies audio files the user picks in the Files app into the app's own folder (On My iPhone > Voice Recorder > Recorders). The app has no network features and collects no data.
```

Then choose the build, and **Add for Review** → **Submit**.

## Before you release

- **The MP3 encoder's license.** MP3 recording uses LAME, which is under the
  LGPL. For an app on the App Store, that license expects the source to be
  available so people could rebuild the app with a changed LAME: this
  repository is public for that, and the About dialog says so. Tag the
  commit of every store build (`git tag v1.0.1 && git push --tags`) and
  keep the repository public. See
  [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
- **After the first release**, put the app's Apple ID (the number under
  *App Information* in App Store Connect) into `lib/src/config.dart`
  (`AppConfig.appStoreId`). From that version on, Settings shows "Rate this
  app", which opens the App Store review page.
