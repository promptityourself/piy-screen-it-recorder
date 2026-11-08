<img src="docs/icon.png" width="128" alt="S|R">

# Screen It Recorder

A small macOS menu bar app that records **every display to its own file**, with your
microphone in each file. Drop the files into Final Cut Pro and sync them on the audio.

- One `.mov` per display, 30 fps, plus AAC mic audio. Choose in **Settings → Recording**:
  - **Quality** Standard / High (default) / Maximum.
  - **Resolution** 1440p (default) or Native (5120×2880 on a 5K display).
  - **Codec** HEVC (default, small files) or ProRes 422 LT / 422 / HQ (smooth editing in FCP, very large files).
  Settings shows the size per hour. Measured with moving content: High HEVC 1440p is about 6 GB per
  hour for each display; Maximum ProRes Native is about 210 GB.
- **What to record** (menu → **Record**, or Settings → Recording): all displays (default), or one
  display in full, its left half or its right half. **Select Area…** dims every display and shows the
  current area: drag inside it to move it, drag an edge or corner to resize it, or drag anywhere else
  for a new one. Enter, a double-click or **Use This Area** takes it; Esc cancels. A half of a 5K
  display at Native is 2560×2880. The file keeps the display's number (`screen1.mov` is still
  display 1) and stores its area, so Playback puts it back on that part of that display and the rest
  of the display stays in view.
- **Audio tracks** in each screen file: track 1 is the mic (`Microphone`), track 2 is the sound of
  your apps (`App sound`, stereo; Settings → Recording turns it off). Use headphones, or the mic
  also hears the app sound from the speakers.
- **Start countdown** (Settings → Recording: Off / 3 (default) / 5 / 10 s): the recording starts at
  once, then beeps once a second and plays a "go" tone. Start talking after "go". The tones are pure
  sines for an editor or an agent to find: each count is 880 Hz for 0.12 s, "go" is 1760 Hz for
  0.4 s. They are at full level on the app-sound track, and fainter on the mic from the speakers.
- The same mic track is in every file, so **Synchronize Clips** in FCP lines them up. A clap at the start is a good backup.
- **Camera (optional):** choose a camera in the menu (default **None**). It records 1080p HEVC at 30 fps (matches the screens); **Camera Frame Rate** offers every rate the camera supports, e.g. 50/60 for slow motion
  with the same mic track to `camera.mov`. The camera starts first, so it never misses the clap.
- **Green / blue screen:** press **⌃⌥G** (anywhere) to cover every display with a solid key
  colour, so you can key other footage onto the screens later. Press ⌃⌥G or Esc to remove it.
  Choose in Settings: pure green `#00FF00` (default), chroma green `#00B140`, pure blue
  `#0000FF` or chroma blue `#0047BB`. Use blue when something green (a mic, a plant) is in
  front of the screens. The recording stores the exact value.
  By default it also dims the displays to 40% while green is on (configurable), so the green
  does not flood the room. Only the backlight changes, so the file keeps the exact colour.
  (Dimming uses Apple's private DisplayServices framework; it works on Apple displays.)
- **Playback:** press **⌃⌥P** to play the latest recording full screen, each screen file on the
  display it came from, all displays frame-locked. Perform a demo again live in front of the
  camera instead of keying it in later. Menu → **Playback…** chooses a recording folder or any
  video per display (for example a recut export). Beeps tell you where you are without a look:
  a countdown (Off / 3 / 5 / 10 s), a tick (Off or every 5–60 s), the last 5 seconds and the end.
  At the end it holds the last frame or restarts. ⌃⌥P or Space pauses, ⌃⌥⇧P restarts, Esc stops.
  The video's own sound is off by default. Your mic hears the beeps, so use headphones when it must not.
- **Mouse clicks:** each click shows a red ripple (`#E2342B`) in the recording. Choose in
  **Settings → Recording**: Off / While recording (default) / Always, the ripple length (1, 2, 3, 5, 10, 15, 20 or 30 s)
  and the size. For a video you speed up, make the ripple longer by the same factor: 10× faster
  needs 10 s, so the ripple still lasts about 1 s in the edit.
- **Settings window** (menu → Settings…): all options, the shortcuts, and a live check of the
  Screen Recording, Camera and Microphone permissions with buttons to fix them.
- Captures in sRGB, so the colours in the file match the screen and the file's BT.709 tag.
- Hides your desktop widgets while it records and puts them back after (a setting, on by default).
- Keeps the display awake while it records.
- Refuses to start with less than 10 GB free.
- If you quit or log out during a recording, it saves the files first.

Recordings go to `~/Movies/ScreenItRecorder/<date_time>/`: `screen0.mov`, `screen1.mov`, …, plus
`camera.mov` when a camera is on. Change the folder in **Settings → Saves to**; network drives work.

## Requirements

- macOS 15 or later (uses ScreenCaptureKit's microphone capture).
- Swift 6 toolchain. The Command Line Tools are enough; you do not need Xcode.

## Build and run

```sh
tools/make-local-signing-cert.sh   # once per Mac: keeps permissions across rebuilds
./build.sh --install               # builds, replaces /Applications/Screen It Recorder.app, relaunches
```

Click **S|R** in the menu bar, choose your microphone, then click **Start Recording**, or press **⌃⌥⇧R** anywhere to start and stop.
(⌃⌥R is taken by Final Cut Pro's Custom Speed.)
The first time, macOS asks for Screen Recording, Microphone and (if you use one) Camera permission.

`build.sh` signs with the local identity from `tools/make-local-signing-cert.sh` when it
exists. Without it, the build is signed ad hoc, and macOS forgets the permissions after every
rebuild. To sign a build that you share with other people, use your Developer ID:

```sh
SIGN_ID="Developer ID Application: <your name> (<team id>)" ./build.sh
```

The logo is the [Prompt It Yourself logo](https://promptityourself.com/media/) with S and R in place
of P and Y. `uv run tools/make-logo.py` draws it again into `Resources/`.

Smoke test without the UI (records 5 s, then quits; add `--green` to record over the green screen, `--clicks` for a click ripple in the centre of each display):

```sh
"build/Screen It Recorder.app/Contents/MacOS/ScreenItRecorder" --test 5
```

## Command-line alternative

`rec` records the two screens and the mic with `ffmpeg`, at fixed settings (12 Mbit/s HEVC 1440p; `REC_*` variables change them) (`brew install ffmpeg`). Press Ctrl-C to stop.
`widgets off|on|status` toggles the desktop widgets by hand.

## License

MIT
