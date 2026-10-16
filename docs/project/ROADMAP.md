# Roadmap

Finished items move to HISTORY. Keep this list short and ordered.

## Now: release 1.0.1

1. **Owner: call test** of 1.0.1 (3), already on the phone:
   1. Record MP3 and say "before the call".
   2. Lock the phone, take a call or FaceTime for 20–30 s, and hang up.
   3. Say "after the call", then open the app. It should still be recording, with no "stopped
      unexpectedly".
   4. Stop and play it back: both parts should be in one file.
   5. Optional: connect or disconnect AirPods mid-recording.
2. **Decide** whether 1.0.1 also sets `AppConfig.appStoreId = '6816329122'` in
   `lib/src/config.dart`, so "Rate this app" shows (STATUS, open decisions). If any code
   changes, use build 4.
3. Merge `ios-capture-recovery` into the default branch. It's a fast-forward, because the
   default branch (with the doc ritual) was merged into it on 2026-10-15.
4. Build and upload (RUNBOOK 4). What's New: "A recording now keeps going after a phone call,
   and after headphones or a car connect, in the same file." Submit; release is automatic.
5. Tag `v1.0.1` at the uploaded commit and push it (LGPL).

## Next

- Delete the merged branch `ios-release-polish`.
- Make the App Store screenshots reproducible: they were rendered from a temporary widget test
  (1290 × 2796, iOS layout, neutral sample recordings) that isn't in the repository. Add it as
  `tool/` or a tagged test.
- Golden tests: make the two that fail on macOS hosts (anti-aliasing) pass there too, or skip
  them off CI, so a local run is green.
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
