# History

Newest first. Add an entry at every doc ritual: what changed and why, with commit hashes.
Earlier work (the app itself, audits 1 to 4) is in the git log up to `bfe83b3`.

## 2026-10-15: doc ritual

- First doc ritual: `CLAUDE.md` and `docs/project/` (STATUS, HISTORY, ROADMAP, DECISIONS,
  RUNBOOK) created, following the owner's convention from another project.
- The 1.0.1 fix was pushed to its own branch first (`ios-capture-recovery`, `843fa18`), so
  nothing lives only in the temporary working copy.

## 2026-10-12: a recording no longer ends after a phone call (1.0.1, not yet released)

- **The problem:** an MP3 recording ended with "The recording stopped unexpectedly. It has
  been saved." after a phone or FaceTime call.
- **The cause:** MP3 and WAV use `record`'s streaming mode, whose iOS side (record_ios 2.1.1)
  pauses for an interruption and resumes after it, but does nothing about the input coming
  back in another format (as after a call), route changes (headphones, a car) or media service
  resets. Its converter then fails and it stops itself, or its engine just goes silent; the
  app's stall check ended the recording 5 s later.
- **The fix** (`843fa18`, branch `ios-capture-recovery`, version 1.0.1+3), iOS MP3 and WAV
  only. A lost capture is started again with the same configuration and goes on into the same
  file. That covers a stall, the plugin's stop, a stream error, an interruption that ends
  without the capture coming back, and a route change or reset with no audio after it.
  - Retries: at once, then after 0.5, 1, 2, 4 and 8 s, at most 20 restarts per recording.
  - It waits for a call to end, and for the user's resume when paused.
  - In the background, a capture that can't be started stays paused, and opening the app
    resumes it.
  - Only in the foreground does the recording end after failed retries, as before. After 20
    restarts, the next loss ends it even in the background.
  - Android and M4A are unchanged.
  - The saved length now comes from the file for every format (the timer may have run through
    the seconds before a restart).
- **Review:** 27 agents in 4 dimensions (races, iOS reality, integration, tests), each finding
  verified by a skeptic. 18 confirmed findings, 8 distinct issues, all fixed. The worst: an
  interruption that never reports its end blocked later restarts for good. Each fix has a test
  that fails without it (checked by breaking each fix), except stop-during-resume, which has
  two independent guards.
- **Tests:** on the Mac, 293 pass, 2 fail (the golden tests, RUNBOOK 2) and 2 are skipped
  (they need `/dev/full`): 297 in all. `test/audio/record_engine_test.dart` has 32 (30 run on
  macOS), 20 of them on recovery. CI passed on `843fa18`.
- **Installed** on the owner's iPhone as a development build, 1.0.1 (3), over the App Store
  copy; every recording carried over.

## 2026-09-29: 1.0.0 live on the App Store

- Apple approved build 2; it went live 2026-09-29 as "Voice Recorder – Classic".

## 2026-09-26: App Store release 1.0.0

- **Setup:** cloned; Flutter 3.47.5 installed at `~/flutter-3.47.5`; Runner signed with team
  `H7UNC6TN89` and CocoaPods integrated (`bf21521`).
- **iPhone fixes** from the owner's first look on the device (`35dc9bb`):
  - The red bottom bar now reaches the screen's edge under the home indicator. The header was
    also extended under the status bar at first; the owner found that weird, so it was
    reverted and the status bar stays black.
  - Settings got a back caret before the app icon: an iPhone has no Back button.
- **Icon:** the iOS icon now matches what Android's adaptive icon shows (larger disc). The App
  Store screenshots were retaken with the red bottom bar (`9ee785b`). A review of these
  changes (15 agents) found 5 issues, all fixed before pushing.
- **LGPL:** the owner made the repository public. The About dialog names LAME's copyright and
  links the source; notices and docs were updated; version 1.0.0+2 (`d066dd5`); tag `v1.0.0`.
- **App Store Connect:**
  - Claude registered the bundle ID and created the app record.
  - Claude filled the listing: App Information, pricing and availability, App Privacy, the
    version page and the screenshots.
  - The owner entered the review contact and uploaded the builds through Organizer.
  - Build 2 was submitted for review with the owner's go-ahead.

## Lessons

- **`flutter install` uninstalls the app first** (flutter_tools `install.dart`), which deletes
  the owner's recordings. Update the phone's copy with `xcrun devicectl device install app` or
  `flutter run --release` only.
- **Command-line upload fails** with "Failed to Use Accounts" (`xcodebuild -exportArchive`,
  destination upload), even with Xcode signed in; plain export works. Upload through Organizer.
- Organizer lists every archive as "Runner": the owner first uploaded build 1 instead of
  build 2. Check the build number.
- **Phone logs:** `sudo log collect --device-udid … --start …` needs root, so the owner runs it.
  In zsh, `log` is a shell builtin: call `/usr/bin/log`.
- **App Store builds don't share their files;** a development build does
  (`xcrun devicectl device copy from --domain-type appDataContainer …`).
- **App Store Connect:**
  - Its dropdowns ignore programmatic value changes unless the page has fully loaded.
  - A password manager's inline menu over the review sign-in fields blocked all browser
    automation until the owner closed it.
- **On macOS, or without CMake,** the host LAME library for the app's MP3 tests must be compiled
  directly with `cc` to `build/host/liblame_mp3.so` (RUNBOOK 2). `build_host_lib.sh` makes a
  `.dylib` on macOS, which those tests don't load.
- A test of recovery code must prove it fails without the fix: two of the first versions
  passed through the slower 5 s stall check instead.
