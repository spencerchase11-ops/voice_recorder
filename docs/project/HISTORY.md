# History

Newest first. Add an entry at every doc ritual: what changed and why, with commit hashes.
Earlier work (the app itself, audits 1 to 4) is in the git log up to `bfe83b3`.

## 2026-11-13: 1.1.0 (6): a recording's own page, reviewed until nothing was found

- **The owner's request (2026-11-09):** a missing screen. In the original, tapping a recording
  opened it on its own page; the revival opened the row in place. Added in `fcf0304` (the page,
  measured from the owner's screenshot of the original) and `e8e0c23` (its player above the
  home indicator), with an App Store screenshot in `5d282cf` (`4-recording-page.jpg`; Recently
  deleted moves to `5-`). Released as 1.1.0 together with 1.0.1's fixes, which were never
  uploaded (D18).
- **The owner's decision (2026-11-10):** release without the phone test; review the code until
  a round finds nothing instead (D19). The phone checks now come after the release (ROADMAP).
- **Review rounds:** each by five independent reviewers with different lenses (the new code,
  user flows, crashes, screens and accessibility, release readiness), every finding checked by
  a skeptic with a probe test, and every fix with a test that fails without it.
  - Rounds 1 and 2 (`f3c3851`, `444ba2b`): quick Play/Next/skip races; the seek bars for screen
    readers; a delete no longer closes the list; header touch areas; the player's times at
    large text; Bold Text measured in bold everywhere; headers keep text at most 2x.
  - Round 3 (`02b86cb`): lock-screen and headphone controls stay while Next opens the next
    recording; a recording left paused is found where it was; the page closes when its
    recording goes from the folder; dialogs keep text at most 2x.
  - Round 4 (`69530df`, `6e1cc54`): places restored exactly; a headphone press during Next acts
    on the recording it opens; a recording deleted outside the app stops; a page opened during
    a rename follows it (`AppController.renamedTo`); a seek overtaken by another recording's
    load moves nothing.
  - Round 5 (`d4641db`): presses while a second Next replaces the first; a recording deleted
    while it opens stops; skips while a recording reopens at its place; the search field, tab
    labels and open row at large text; a row's date keeps most of its line.
  - Round 6 (`9804da0`): Back after paging far with Next scrolls to the open row; dates are
    drawn smaller rather than cut; Previous/Next are heard by screen readers (the name is a
    live region); a rename onto a name freed in the Files app; a delete's Undo toast never
    lies over another recording's page; toasts and Settings summaries keep text at most 2x.
  - Round 7 (`0127aa7`): Back brings the open row wholly into view; a plain toast stacks
    above the Undo toast; screen readers hear toasts and the page's name once (announced on
    iOS, live regions on Android); the progress dialog is read out by tenths; dialog buttons
    draw long labels smaller; a delete keeps a row opened meanwhile.
  - Round 8 (`3263a39`): the progress read-out's first change; a rename from the list keeps a
    row opened meanwhile; with a screen reader on, the Undo toast says "Undo available".
  - Round 9 (`60350b2`): with VoiceOver or Switch Control on, the Undo toast stays after its
    6 s until it is used, a dialog opens or the reader is turned off; on Android it keeps its
    6 s (any accessibility service looks like a screen reader there).
  - Round 10 (`f5fec93`): after a delete from selection mode, the list header's frames for
    screen readers were left at the selection header's places (since 1.0.0). Its second pass
    over the whole change found nothing.
  - Round 11, by two reviewers: a check of round 10's fix (the search field, keyboard and
    screen-reader focus at every header switch; the screens unchanged pixel for pixel) found
    nothing.
- **Also in 1.1.0:** `42cdf8e` (from `fix/others-playing`), two gaps around an M4A
  interruption's end (D17).
- **Release docs:** ROADMAP and RUNBOOK 4 now say to paste a changed Description and place a
  new screenshot by hand: a new version copies the last one's listing.
- **Released:** merged into the default branch (fast-forward) and built; build 6 uploaded from
  the command line and Ready to Submit; tag `v1.1.0` = `4ec37d6`. CI's first run on the default
  branch failed one timing-sensitive test (a fixed 100 ms wait for a recording's own stop);
  `1ea05b1` makes three such tests wait for the notice instead (tests only).
- **Submitted 2026-11-14:** App Store Connect wouldn't add version 1.1.0 ("Agreement Update:
  your paid application agreement is outdated") until the owner updated that agreement in
  Business. Then version 1.1.0 was created with What's New, the whole Description and the
  Promotional Text (which didn't carry over) from `docs/APP_STORE.md`, build 6, automatic
  release; submitted, Waiting for Review. The four screenshots of 1.0.0 carried over;
  `4-recording-page.jpg` wasn't added (the browser tools can't upload a file).
- **Lessons:**
  - The golden tests let 1% of pixels differ, so they can't prove a UI change leaves normal
    text alone. Raw RGBA captures of each screen, before and after, compared byte for byte,
    can: every UI fix in rounds 5 to 7 was checked that way.
  - The command-line upload works with `xcodebuild -exportArchive -allowProvisioningUpdates`
    (RUNBOOK 4); without the flag it fails with "Failed to Use Accounts".
  - A copy of the repository made with its `.git` shares the real stash and branches: a
    reviewer's `git stash` in one reached the real repository (undone, nothing lost). Review
    copies are made with `rsync --exclude .git`, and reviewers make no git writes.
- Tests on the Mac: 535 pass, 7 skipped; the two known golden tests fail (macOS text
  anti-aliasing, as before every change).

## 2026-11-08: audit and fixes for 1.0.1 (5)

- **The owner's report:** on 1.0.1 (4), playback stopped when the Ring/Silent switch went to
  Silent, and when the app was left. Under the app's `playAndRecord` session neither can
  happen; the likely cause is iOS resetting its media services, which puts the session back to
  its default (silenced by the switch, not allowed in the background), and nothing in the app
  set it up again. The just_audio player also never reports a pause iOS makes itself, so the
  app kept showing "playing". Not reproducible on the simulator.
- **Audit:** reviewers in several dimensions, each finding checked by 3 skeptics: 36 confirmed
  (some duplicates), 6 rejected. Fixed in 7 groups, each reviewed independently, merged into
  the branch `audit-2026-11-08` (`55aab3c` to `8c4928c`), then a polish round on the reviews'
  remaining points (to `c4b5be2`), a final review of the whole change (6 more issues, fixed in
  `1a59737`, `842fbc5`, `fb0640c`), and `0074d84` (no CallKit, D15). Three more reviews of
  that last change gave `9e619c9`, `89bb46d` and `7becad0` (D17), merged from
  `fix/others-playing`.
- **Playback (iOS):** the session is set up again before every play and after a media-services
  reset (which also unloads the dead player); a launch that can't set it up still opens; a
  refused session says "audio busy" instead of "Can't play this recording"; a pause iOS makes
  (app sent to the background without background audio, a failed play) or a file failing
  partway now reaches the app (`PlayerWatch` in AppDelegate.swift); headphone double/triple
  presses and a car's next/previous skip 10 s; uncaught errors are logged.
- **Playback (Android):** headphones unplugged during a call no longer let playback resume out
  loud after it; play during a call says "audio busy".
- **Recording:** an iOS M4A recording that iOS paused and won't let resume ends, saved, instead
  of staying frozen; opening the app with an M4A recording held up never takes the audio
  session from another app that plays (D15), counting only audio it would cut off, even as the
  interruption's end arrives; while such audio holds it up, the app says that stopping saves it
  and, while open, asks again every 2 s, so the recording goes on or is saved once that audio
  is over (D17); an M4A recording paused during a call and resumed just after the call's end
  no longer stays shown as held up while it records; the MP3/WAV level meter no longer freezes
  when the clock goes back; the WAV limit notice gives the right hours for the quality.
- **Dates and Recently deleted:** a date kept only in the app's cache (a renamed AAC, a write
  that failed or was refused, 1.0.x caches) survives delete and restore, folder switches and
  renames; a 1.0.1 copy time cached on iPhone no longer hides a date typed into the name;
  Recently deleted no longer purges early after the clock was set back; trash actions run one
  at a time, so an Undo still running can't be undone by Delete forever or Restore all; the
  Undo toast goes away when Recently deleted restores or deletes; M4A dates keep their name's
  clock time after a change of time zone; a rename writes a date only 1.0.x's cache held into
  the file (an M4A's own moment is left alone), keeps it when the rename fails, and leaves no
  cache entry behind; better date and VBR MP3 length parsing.
- **Screens:** a notice waiting for the app is no longer closed by the Record shortcut; Android
  no longer asks for the folder while the app is still starting; large text sizes fit
  (Remaining time, Recently deleted's buttons); seeking while a recording is saved says why.
- **Native:** iOS import Cancel stops at once and leftover partial copies are cleaned up; the
  Record shortcut closes the Files picker or share sheet first. Android: a refused delete is
  reported, a folder picked while the app was killed is kept, a save copies under a hidden name
  first (with a fallback where renaming isn't supported), a case-only rename no longer adds
  " (1)".
- **Left on purpose:** the iPhone's folder listing stays synchronous (D16); see ROADMAP for the
  rest.
- **Lesson:** `git add -A test` also adds `test/golden/failures/` (6 MB of images from the
  golden tests that fail on the Mac); it is in `.gitignore` now.
- Tests on the Mac: 425 pass, 6 skipped, and the 2 known golden tests fail (RUNBOOK 2).
  `flutter build ios --simulator` and `flutter build apk --debug` build. On the simulator,
  playback went on after Home.

## 2026-10-17: 1.0.1 (4) prepared

- The owner's call test of 1.0.1 (3) passed: the recording kept going through a call, in one
  file.
- `ios-capture-recovery` merged into the default branch (fast-forward to `925abc9`).
- `ff3dbe2`: `AppConfig.appStoreId = '6816329122'`, so Settings on iPhone shows "Rate this app",
  which opens the App Store's review page (DECISIONS D13). Version 1.0.1+4. The Rate test now
  checks the URL opened (it fails without the id).
- Tests on the Mac: 293 pass, 6 skipped, and the 2 known golden tests fail (RUNBOOK 2).
- `flutter build ipa`: 1.0.1 (4), with `lame_mp3.framework` embedded on its own. The archive's
  app is installed on the owner's iPhone over build 3, with every recording intact.
- **Pre-release review:** 47 agents in 5 dimensions (the Rate link, packaging, regressions on
  Android and M4A, the recovery against record_ios's and audio_session's sources, release
  notes and the LGPL), each finding checked by 3 skeptics. No code issues. The engine and the
  controller are byte-identical to the call-tested build 3. Three doc fixes (README,
  `docs/APP_STORE.md`, CLAUDE.md) applied. What's New is in `docs/APP_STORE.md`.

## 2026-10-17: doc ritual; the screenshot and icon tools kept

- Two tools from the 1.0.0 work lived only in the temporary folders of the session and were
  lost with them. Both were rebuilt and committed:
  - `test/tool/app_store_screenshots_test.dart` renders the four App Store screenshots. It
    reproduced the published images exactly, except the deletion date in Recently deleted (the
    screen reads the real clock, so the test now deletes "just now" to show 30 days left).
    A plain `flutter test` skips it.
  - `tool/art/render_icon.swift`, a Swift port of the iOS part of `app_icon.py` (the Mac has
    no arm64 Pillow). All 15 iOS icons come out pixel-identical to the committed ones, and so
    does the 1.0.0 (1) icon before the 0.96 disc change.
- RUNBOOK 5 has the commands. No app code changed; the call test of 1.0.1 (3) is still to do.

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
- **Anything made in a session's temporary folder is lost with it,** scripts included. Commit a
  tool the moment it proves useful.
- A test of recovery code must prove it fails without the fix: two of the first versions
  passed through the slower 5 s stall check instead.
