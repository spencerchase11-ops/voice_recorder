# Voice Recorder status

Snapshot as of **2026-11-08**. Rewrite this file at every doc ritual (see `CLAUDE.md`).

This repository is **public**: no device identifiers, personal email addresses or the owner's
recordings in here.

## At a glance

| Area | State |
|---|---|
| App Store | **1.0.0 (build 2) live since 2026-09-29** as "Voice Recorder – Classic": free, 4+, iPhone only. |
| Next release | **1.0.1 (build 5)** on the branch `audit-2026-11-08`: build 4's call fix and "Rate this app", plus the 2026-11-08 audit fixes (HISTORY), first of all playback that stopped on the Ring/Silent switch and when leaving the app. Build 4 was never submitted (D14). **Next: the owner tests it on the phone** (ROADMAP "Now"), then merge, upload, submit and tag `v1.0.1`, each with the owner's go-ahead. |
| Owner's own copy | 1.0.1 (4) from the 2026-10-17 archive. Build 5 is to be installed with `devicectl` (RUNBOOK 3) once the phone is connected. |
| Code backup | GitHub, **public**: `spencerchase11-ops/voice_recorder`. The default branch is pushed; `audit-2026-11-08` is pushed too (a work branch, not merged). |
| CI | Green: `v1.0.0` (push run, 2026-09-26), the default branch (`87a9904`) and `ios-capture-recovery` (`843fa18`, `e936670`), 2026-10-15: analyze, tests and the Android build. The 2026-10-17 doc ritual pushes start new runs. The weekly Monday run only keeps the Android test signing key's cache alive and runs no tests. The iOS build job runs only when started by hand. |
| Tests | `audit-2026-11-08` on the Mac: 425 pass, 6 skipped, and the `recording list` and `settings` golden tests fail (2.29% and 1.51% text anti-aliasing, on macOS hosts only, before and after every change). On CI all of them pass. |
| Tools | The App Store screenshots and the iOS icons can be made again on the Mac: `test/tool/app_store_screenshots_test.dart` and `tool/art/render_icon.swift` (RUNBOOK 5), both checked against what's published. |
| Android | Not part of these sessions: no Play Store work done or checked. |

## App Store

- **App:** "Voice Recorder – Classic", Apple ID `6816329122`, bundle ID
  `com.spencerchase.voicerecorder`, SKU `voice-recorder-ios`, team `H7UNC6TN89` (Sable Creek
  Software LLC). Public page: https://apps.apple.com/us/app/voice-recorder-classic/id6816329122
- **Listing:** subtitle "One-tap MP3 audio recorder"; Utilities, then Productivity; free in
  all 175 countries or regions; age rating 4+; App Privacy "Data Not Collected"; not offered
  on Apple silicon Macs or Vision Pro; release automatic after approval. Text, keywords and
  review notes as in `docs/APP_STORE.md`. Screenshots: `docs/app-store/*.jpg`, 1290 × 2796, in the 6.9" slot.
- **URLs:** support https://github.com/spencerchase11-ops/voice_recorder/issues, privacy
  https://github.com/spencerchase11-ops/voice_recorder/blob/HEAD/PRIVACY.md, marketing
  https://github.com/spencerchase11-ops/voice_recorder. Copyright "2026 Sable Creek Software
  LLC".
- **Build 1.0.0 (1):** uploaded 2026-09-26, never submitted (its About dialog didn't say where
  the source is).
- **Build 1.0.0 (2):** uploaded by the owner 2026-09-26 through Xcode's Organizer, submitted
  2026-09-26, approved, live 2026-09-29. Source: tag `v1.0.0`.
- **App Store Connect session:** expired by 2026-10-15; the owner signs in (Claude never does).

## Code and backups

- **Working copy:** `voice_recorder/` inside a temporary folder the Claude app made for one
  session; **it is deleted with that session.** GitHub is the only lasting copy. Start new
  work from a fresh clone (`gh repo clone spencerchase11-ops/voice_recorder`) in a permanent
  folder.
- **Branches:**
  - `claude/voice-recorder-fork-7xk3bg`: the default branch, with 1.0.1 (4) since 2026-10-17.
  - `audit-2026-11-08`: 1.0.1 (5), the audit fixes; merged into the default branch after the
    owner's phone test.
  - `ios-capture-recovery`: the call fix (`843fa18`). Merged into the default branch
    (fast-forward); can be deleted.
  - `ios-release-polish`: the 1.0.0 work; the same commit as `v1.0.0`. Merged; can be deleted.
- **Tag:** `v1.0.0` = `d066dd5`, the exact source of App Store build 2 (needed for the LGPL).
- **Commit identity:** `spencerchase11-ops <285316066+spencerchase11-ops@users.noreply.github.com>`.
  The older commits are by "Claude".

## Toolchain (owner's Mac)

- Flutter **3.47.5** (Dart 3.13.4) at `~/flutter-3.47.5`; `~/development/flutter` (3.44.4)
  stays for other projects. Put 3.47.5 first on `PATH` (RUNBOOK 1).
- Xcode 27.0 (27A266a), CocoaPods 1.16.2, macOS 27.0. Xcode is signed in to the team.

## Open decisions

- Whether build 5 fixes the owner's playback problem on the phone (the cause couldn't be
  reproduced on the simulator; ROADMAP "Now" has the test).
- The owner's go-ahead to merge, upload, submit and tag.

## Watch items

- **Never use `flutter install`** on the owner's phone: it uninstalls the app first, which
  deletes every recording (RUNBOOK 3).
- **Upload from the command line fails** ("Failed to Use Accounts"); export works. Upload
  through Xcode's Organizer. Archives there are all named "Runner": check the build number.
- **LGPL:** keep this repository public and tag every store build (THIRD_PARTY_NOTICES.md).
  LAME must stay its own `lame_mp3.framework` (`use_frameworks!` in `ios/Podfile`).
- **`lame_mp3` doesn't support Swift Package Manager:** Flutter warns that this will become
  an error in a future version.
- **record_ios 2.1.1** has no handling of route changes or media service resets; the app works
  around it from 1.0.1 (DECISIONS D9). Re-check when upgrading `record`.
- **just_audio 0.10.6** doesn't report pauses iOS makes itself; AppDelegate.swift's
  `PlayerWatch` does (from 1.0.1). Re-check when upgrading `just_audio`.
- **No CallKit** (D15): App Review rejects apps that link it while offered in China mainland.
- **M4A and other apps' audio** (D17): whether another app plays is asked with iOS's
  `secondaryAudioShouldBeSilencedHint`, which only a phone can test (ROADMAP "Now" has the
  steps). An M4A recording left paused that way, never stopped, is lost if iOS closes the app.
- **iOS 27** deprecates `AVAudioSessionInterruptionNotification` (still posted; the plugins
  rely on it). Watch the next iOS releases.
