# Decisions

One entry per decision: context, decision, why. Newest first. Supersede old entries with a
new one rather than editing them.

## D11 (2026-10-15): internal docs live in this public repository

- **Context:** the owner wants status and context kept so nothing is lost; the working copy is
  temporary, and the repository is public (D6).
- **Decision:** `CLAUDE.md` and `docs/project/` are committed here, with no device
  identifiers, personal email addresses or recordings. Those stay in Claude's local memory.
- **Why:** GitHub is the only off-machine copy.

## D10 (2026-10-12): the saved length comes from the file, for every format

- **Context:** up to and including 1.0.0, MP3 and WAV saved the timer's value; only M4A read
  the file.
  With restarts (D9), the timer can run through a few seconds that weren't captured.
- **Decision:** `AppController._stop` reads `audioDuration(file)` for all formats, falling
  back to the timer.
- **Why:** the file is what plays. MP3 is constant bitrate, so its size gives the exact
  length; WAV has it in its header.

## D9 (2026-10-12): iOS restarts a broken capture into the same file

- **Context:** record_ios 2.1.1 doesn't survive the input changing format after a call, route
  changes or media service resets; the recording used to end ("stopped unexpectedly").
- **Decision:** iOS, MP3 and WAV: start the platform stream again with the same
  `RecordConfig` and keep writing the same `Mp3Writer`/`WavWriter`.
  - Never during a call, nor while the user has paused.
  - In the background, if iOS refuses, stay paused until the app is opened
    (`AppController.onResume`).
  - End the recording only in the foreground, after the retries. After 20 restarts, the next
    loss ends it even in the background.
  - M4A is excluded: a restart would replace its file. Android is unchanged.
- **Why:**
  - The plugin always converts to the requested format, so the file stays consistent.
  - Losing a second around the switch beats losing the rest of the recording.
  - Patching the plugin would mean maintaining a fork.

## D8 (2026-09-26): App Store name "Voice Recorder – Classic"

- **Context:** "Voice Recorder" alone is taken on the App Store.
- **Decision:** "Voice Recorder – Classic" (the owner's choice from the guide's suggestions).
  The name under the icon stays "Voice Recorder".

## D7 (2026-09-26): App Store support and privacy pages are on GitHub

- **Decision:**
  - Support: the repository's Issues page.
  - Privacy policy: `PRIVACY.md` through `blob/HEAD`, which follows the default branch.
  - Marketing: the repository.
- **Why:** public pages are required, and the repository became public anyway (D6).

## D6 (2026-09-26): the repository is public (LGPL)

- **Context:** MP3 recording uses LAME (LGPL). The App Store build must let people rebuild
  the app with a changed LAME, and iOS apps can't be relinked by users.
- **Decision:**
  - The owner made the repository public.
  - Every store build is tagged (`v1.0.0` …).
  - The About dialog names LAME's copyright and links the source.
  - LAME stays a separate dynamic framework.
- **Why:** the simplest complete way to comply; nothing secret is in the repository. (A
  summary, not legal advice: THIRD_PARTY_NOTICES.md.)

## D5 (2026-09-26): iPhone Settings has a back caret

- **Context:** an iPhone has no Back button; Settings only offered an edge swipe.
- **Decision:** on iOS the Settings header starts with the same back caret as the other
  screens, before the app icon (like Android's "up"). Android keeps the original header.

## D4 (2026-09-26): the iOS icon matches Android's adaptive icon

- **Context:** the iOS icon's red disc was smaller (78% of the width) than what Android's
  adaptive icon shows (89%).
- **Decision:** render the iOS master with disc scale 0.96 and the tile's gradient window
  18/108 to 90/108 (`tool/art/app_icon.py`); the small sizes are resized from it the way the
  script does.

## D3 (2026-09-26): iPhone keeps the black status bar; only the bottom bar reaches the edge

- **Context:** on iPhone the screens stopped short of the screen's edges.
- **Decision:**
  - The red bottom bar, or the page on screens without one, goes on under the home indicator.
  - The header was extended under the status bar at first; the owner found that weird, and it
    was reverted. The status bar stays black, as in the original.
  - Android is unchanged.

## D2 (2026-09-26): Flutter 3.47.5 lives beside the owner's other Flutter

- **Decision:** install 3.47.5 at `~/flutter-3.47.5` and put it first on `PATH` per command.
  `~/development/flutter` (3.44.4) stays as is, and `~/.zshrc` was not changed.
- **Why:** other projects on the Mac use 3.44.4.

## D1 (2026-09-26): signing with team H7UNC6TN89, automatic

- **Decision:** `DEVELOPMENT_TEAM = H7UNC6TN89` and automatic signing on the Runner target,
  committed.
- **Why:** it's the only team on the Mac (Sable Creek Software LLC), the one the owner's other
  apps use.
