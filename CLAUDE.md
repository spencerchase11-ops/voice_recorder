# Voice Recorder: working notes for Claude

Read this at the start of every session. Current state is in `docs/project/STATUS.md`. Read
it next, then act.

## The project

Voice Recorder is a Flutter revival of a classic 2016 Android voice recorder (one red button,
a big timer, MP3, WAV or M4A), for Android and iPhone.

- **On the App Store** as "Voice Recorder – Classic", free, sold by Sable Creek Software LLC
  (team `H7UNC6TN89`). iPhone only, portrait.
- **This repository is public,** because the bundled LAME encoder is LGPL (DECISIONS D6).
- **Owner:** Spencer, who prefers short, clear, step-by-step guidance and does every account
  sign-in and payment personally.

| Path | What's there |
|---|---|
| `lib/src/app_controller.dart` | App state: recording, playback, files, the timer. |
| `lib/src/audio/recorder_engine.dart` | Capture on the `record` plugin, feeding the MP3/WAV writers (`mp3_writer.dart`, `wav_writer.dart`). iOS capture recovery (DECISIONS D9) arrives in 1.0.1, on branch `ios-capture-recovery` until merged. |
| `lib/src/ui/` | Screens, dialogs, widgets; `spec.dart` holds every measured size and colour. |
| `ios/Runner/` | Swift side: Now Playing, free space, import from Files; `Assets.xcassets` icons. |
| `packages/lame_mp3/` | LAME as a Flutter FFI plugin (LGPL source, unmodified). |
| `tool/art/` | Generators for the artwork and the app icon (`render_icon.swift`: the iOS icons without Pillow). |
| `test/tool/` | Renders the App Store screenshots (only with `SHOTS_OUT`; RUNBOOK 5). |
| `docs/APP_STORE.md` | The App Store guide and listing text. `docs/app-store/` has the screenshots. |
| `docs/project/` | STATUS, HISTORY, ROADMAP, DECISIONS, RUNBOOK. Public: keep private details out. |

## Rules that protect the owner

1. **Protect the recordings on the owner's iPhone.**
   - Never `flutter install`: it uninstalls first, deleting them. Never delete the app.
   - Update the phone with `xcrun devicectl device install app` (RUNBOOK 3).
2. **Nothing private in this public repository:** no device identifiers, personal email
   addresses, recording names or counts. Those belong in Claude's local memory.
3. **Never answer password, sign-in or keychain dialogs** for the owner (Apple ID, App Store
   Connect, GitHub, `sudo`).
4. **Ask first before anything outward-facing:**
   - App Store Connect changes and submissions, uploads, tags.
   - Pushes beyond the doc ritual, GitHub settings, rewriting history.
5. **Keep the LGPL obligations** (THIRD_PARTY_NOTICES.md):
   - The repository stays public.
   - Every store build gets a tag.
   - LAME stays its own `lame_mp3.framework`.
6. **The working copy may be temporary:** some sessions run in a folder the Claude app deletes
   with the session. Push work before ending one; GitHub is the only lasting copy. Tools and
   scripts too: commit them, not just their output.

## Everyday commands

```bash
export PATH="$HOME/flutter-3.47.5/bin:$PATH" LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
flutter analyze            # no issues
flutter test               # all pass, except 2 golden tests on macOS hosts (RUNBOOK 2)
flutter build ios --release
flutter build ipa          # App Store archive; upload through Organizer (RUNBOOK 4)
```

For the phone, releases, screenshots and diagnosis, see `docs/project/RUNBOOK.md`.

## Conventions

- **Code style:** match the surrounding code: plain names, and comments that explain why.
  The code uses British spelling in places ("colour"); keep each file consistent.
- **Commits:** author `spencerchase11-ops` with the GitHub no-reply address
  `285316066+spencerchase11-ops@users.noreply.github.com`, never a personal email. End each
  message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Branches:** the default branch is `claude/voice-recorder-fork-7xk3bg`. Unreleased work
  goes on its own branch until it is tested on the phone.
- **Tests:** a test for a fix must fail without the fix; check by breaking it.
- **Editing with scripts:** replace exactly once and assert the match count.

## Doc ritual

When the owner says "doc ritual", or at the end of a substantial session:

1. **`docs/project/STATUS.md`:** rewrite the snapshot. Date; version and build; App Store and
   review state; GitHub and CI; the owner's installed copy; open decisions; watch items.
2. **`docs/project/HISTORY.md`:** add a dated entry saying what changed and why, with commit
   hashes. Add any new lesson.
3. **`docs/project/ROADMAP.md`:** remove finished items (they live in HISTORY now); add new
   ideas and follow-ups.
4. **`docs/project/DECISIONS.md`:** one entry per new decision, with context, decision and
   why. Supersede old entries rather than editing them.
5. **`docs/project/RUNBOOK.md`, `README.md` and `docs/APP_STORE.md`:** update any procedure
   that changed.
6. **This file:** update the rules, commands or pointers that changed.
7. **Memory:** refresh Claude's memory notes if facts changed.
8. **Commit and push:** commit as "Doc ritual: YYYY-MM-DD", then push every branch with work
   on it. Confirm with `git status -sb`: GitHub is the off-machine backup.
