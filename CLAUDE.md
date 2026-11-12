# piy-screen-it-recorder — Screen It Recorder

- Name: **Screen It Recorder** everywhere a user reads it. `ScreenItRecorder` stays only where
  renaming costs something: bundle id + executable (TCC grants are keyed on them), the Swift
  target, and `~/Movies/ScreenItRecorder` (existing recordings live there).

- **`promptityourself/piy-screen-it-recorder`** **Public repo (MIT).** Everything committed is published. No fleet hosts, IPs, or personal paths in code or docs.
- **Exception to the observer rule:** this Mac app is built and tested ON the
  observer Mac — a macOS app cannot build on the Linux dev boxes.
- Build + install: `./build.sh --install` (SwiftPM + Command Line Tools, no Xcode → no SwiftUI
  macros: no `@State`/`@Observable`, use `ObservableObject`). Signs with the local
  "ScreenItRecorder Local Signing" identity so TCC grants survive rebuilds — never fall back to
  ad hoc: that revokes the Screen Recording grant. Verify: `"build/Screen It Recorder.app/Contents/MacOS/ScreenItRecorder" --test <s>`
  then `ffprobe` the files in the save folder (`defaults read com.mergodon.ScreenItRecorder saveFolder`; unset = `~/Movies/ScreenItRecorder/`). Delete test recordings after — they contain screen content.
- Run the `--test` binary from the terminal: TCC then uses the terminal's Screen Recording + Mic grant.
- `rec` / `widgets` are the ffmpeg CLI fallback; keep the folder and file names in step with the app. They have no quality, camera or click options; do not add them unless mate asks.
- Tests share mate's prefs domain (`com.mergodon.ScreenItRecorder`), and he changes settings in the
  live app between test runs. Around EVERY test command: `defaults export <domain> <snap>` before,
  `defaults import <domain> <snap>` after, then delete each key not in the snapshot (`import`
  merges). Never restore a key by hand from an earlier value. Never
  `--install` (it quits the app) or run any on-screen check (`--test`, `--setup`, `--settings`) while
  he records, plays back or his colour screen is up: list the app's windows first — layer 1002 = recording
  overlay, layer 1000 = colour screen or Playback. A test window shows up in his recording.
- Each recording folder has a `recording.json` (`RecordingInfo` in `Tags.swift`, `"format": 1`).
  A breaking change to it or to the file layout bumps `format`.

## Cross-repo

Never edit these from here; file issues with `gh issue create -R <owner/repo>`.

- **`mergodon/promptityourself-web`** — the PIY site; owns this project's page. No page for this
  app is live: `/projects/` redirects to `/products/`, and `/products/screen-it-recorder/` is 404.
- **Distribution: App Store later** — no Developer ID / notarised download, and the
  site page says nothing about dev builds or signing. Blockers are tracked in this repo's issues.
