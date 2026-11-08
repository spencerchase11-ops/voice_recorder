# Roadmap

Finished items move to HISTORY. Keep this list short and ordered.

## Now: release 1.0.1 (build 5)

1. **Owner: test on the iPhone** the build from `audit-2026-11-08` (installed with
   `devicectl`, RUNBOOK 3):
   - Play a recording, flip the Ring/Silent switch to Silent: it keeps playing, out loud.
   - Play, then swipe home or lock the phone: it keeps playing (Lock screen controls on).
   - The lock screen still shows the ±10 s buttons; an EarPods/AirPods double press skips
     forward 10 s.
   - Optional: Settings > Developer > Reset Media Services (if the menu is there), then play:
     it still plays on Silent and in the background.
2. Merge `audit-2026-11-08` into the default branch and push (with the owner's go-ahead).
3. `flutter build ipa` (1.0.1, build 5); the owner uploads it through Organizer (RUNBOOK 4).
4. In App Store Connect: version 1.0.1, What's New from `docs/APP_STORE.md` section 5, build
   5, submit (with the owner's go-ahead).
5. Tag `v1.0.1` at the merged commit and push it (LGPL).

## Next

- Delete the merged branches `ios-release-polish` and `ios-capture-recovery`, and the
  `audit/*`, `polish/*` and `final/*` work branches once `audit-2026-11-08` is merged (they
  exist only on the Mac).
- iPhone: list the folder off the UI isolate (D16: about 15-20 ms for 2,500 files on the Mac;
  measure on the phone first).
- just_audio resumes on its own after an interruption that says "should resume"; if taking
  the session fails there, the button can still show Pause with no sound. Rare; would need
  `handleInterruptions: false` and handling it in the app.
- Dates from a 1.0.x cache are kept but never checked against the files: on Android, Store
  dates doesn't offer a 1.0.x write that failed. Could read each such file once.
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
