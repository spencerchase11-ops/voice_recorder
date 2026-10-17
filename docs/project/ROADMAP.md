# Roadmap

Finished items move to HISTORY. Keep this list short and ordered.

## Now: release 1.0.1

1. **Owner: upload** `build/ios/archive/Runner.xcarchive` (1.0.1, build 4) through Organizer
   (RUNBOOK 4). If the working copy is gone, check out `ff3dbe2` and run `flutter build ipa`.
2. In App Store Connect: add version 1.0.1, paste What's New (`docs/APP_STORE.md`, section
   5), choose build 4 once it's processed, and submit (with the owner's go-ahead). Release
   is automatic after approval.
3. Tag `v1.0.1` at `ff3dbe2` and push it (LGPL).
4. Optional: check headphones or a car connecting mid-recording on the phone (covered by unit
   tests, not tried on the device).

## Next

- Delete the merged branches `ios-release-polish` and `ios-capture-recovery`.
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
