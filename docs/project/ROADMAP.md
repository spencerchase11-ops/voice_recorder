# Roadmap

Finished items move to HISTORY. Keep this list short and ordered.

## Now: release 1.1.0 (build 6)

1.0.1 was never uploaded; its fixes ship in 1.1.0 with a recording's own page (D18). The owner
asked to release without the phone test (D19): the code is merged into the default branch and
built; the phone checks come after the release.

1. **Owner: upload** build 6 through Xcode's Organizer (RUNBOOK 4): Distribute App → App Store
   Connect → Upload. Every archive is named "Runner": pick version 1.1.0, build 6.
2. **Owner: in App Store Connect,** once build 6 shows Ready to Submit:
   - Add a new iOS version, 1.1.0.
   - What's New and the Description from `docs/APP_STORE.md` section 5 (paste the whole
     Description: it gains the LISTEN line about a recording's own page).
   - Screenshots: add `docs/app-store/4-recording-page.jpg` and drag it in front of Recently
     deleted (optional).
   - Select build 6, then Add for Review → Submit for Review.
3. **After release, test on the iPhone** (from the App Store, or from TestFlight before that).
   Anything wrong goes into 1.1.1.
   - Tap a recording in the list: its page opens and plays it. Name, size, location, date and
     length are right; the buttons sit above the home indicator.
   - Previous and next go through the list in its order (also after sorting or searching).
     Back returns to the list, with that recording's row open.
   - Rename, share and delete from the page's header; after a delete, Undo brings it back.
   - Play a recording, flip the Ring/Silent switch to Silent: it keeps playing, out loud.
   - Play, then swipe home or lock the phone: it keeps playing (Lock screen controls on).
   - The lock screen still shows the ±10 s buttons; an EarPods/AirPods double press skips
     forward 10 s.
   - Optional: Settings > Developer > Reset Media Services (if the menu is there), then play:
     it still plays on Silent and in the background.
   - M4A (Settings > Recording type): record, take a phone call, and open Voice Recorder
     during it: the recording stays paused. After the call it keeps going, in the same file.
   - M4A: record, then play a song in Music. Open Voice Recorder: the song keeps playing, and
     after a few seconds the app says another app's audio has paused the recording and that
     stopping saves it. Pause the song with the app still open: within a few seconds the
     recording ends, saved.
   - With VoiceOver on: Previous and Next say the new recording's name; after a delete, the
     Undo toast stays until it is used, a dialog opens or VoiceOver is turned off.

## Next

- Trim, the original's scissors on a recording's page (rename stands in for now, D18).
- A golden test for the recording page. Make its image on Linux: the goldens pass on CI
  (Linux), and text renders slightly differently on macOS (two of them fail there).
- Delete the merged branches `recording-page`, `audit-2026-11-08`, `fix/others-playing`,
  `ios-release-polish` and `ios-capture-recovery` (all in the default branch since 1.1.0).
- Android: after a delete, the Undo toast keeps its 6 s even with TalkBack on (Flutter reports
  any accessibility service as a screen reader there, so waiting would keep it on screen for
  people who don't use one). Recently deleted still restores. Could wait only for TalkBack.
- iPhone: list the folder off the UI isolate (D16: about 15-20 ms for 2,500 files on the Mac;
  measure on the phone first).
- just_audio resumes on its own after an interruption that says "should resume"; if taking
  the session fails there, the button can still show Pause with no sound. Rare; would need
  `handleInterruptions: false` and handling it in the app.
- Dates from a 1.0.x cache are kept but never checked against the files: on Android, Store
  dates doesn't offer a 1.0.x write that failed (a rename now writes such a date into the
  file). Could read each such file once.
- Android saves: an empty hidden `.vr-saving-` copy can be left if the app dies in the few
  milliseconds between creating it and recording it; leftovers are only retried when the same
  name is saved again.
- Golden tests: make the two that fail on macOS hosts (anti-aliasing) pass there too, or skip
  them off CI, so a local run is green.
- After a UI change: render the App Store screenshots again (RUNBOOK 5) and upload them
  with the next version.
- Optional: keep the live timer from counting the few seconds before a restart (the engine can
  report the lost time; the saved length is already right).

## Later

- `lame_mp3`: adopt Swift Package Manager before Flutter makes CocoaPods-only plugins an error.
  LAME must stay a separate dynamic framework (LGPL).
- Report record_ios's missing route change and media reset handling upstream; drop the
  workaround if it's fixed there.
- Dependency updates: 9 packages have newer versions outside the current constraints
  (`flutter pub outdated`).
- Google Play: not looked at in these sessions; see README "Before publishing".
