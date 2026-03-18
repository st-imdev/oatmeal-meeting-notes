# Openola

Native macOS meeting capture app with a local file vault and a localhost API.

## Current product shape

- Native SwiftUI macOS app
- Start a meeting, watch the transcript update live, finish the meeting, and keep the result in history
- Meetings persisted as file bundles under `~/Documents/Openola/Meetings`
- Each meeting bundle contains:
  - `meeting.md`
  - `transcript.md`
  - `meta.json`
  - `transcript.json`
- Local HTTP API on `http://127.0.0.1:48567`

## File layout

```text
~/Documents/Openola/
  Meetings/
    2026-03-17-1137-meeting-62ad6d00/
      meeting.md
      transcript.md
      meta.json
      transcript.json
```

`meeting.md` is the human-readable note file. `meta.json` and `transcript.json` are the stable machine-readable files for agents and tools.

## API

The app starts a small local API when it launches.

- `GET /health`
- `GET /openapi.json`
- `GET /meetings`
- `GET /meetings/:id`

Example:

```bash
curl http://127.0.0.1:48567/meetings
```

## Build and run

Openola now lives in an Xcode macOS app project:

```bash
cd /Users/scott/Desktop/Openola
open openola.xcodeproj
```

To build from the command line:

```bash
cd /Users/scott/Desktop/Openola
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project openola.xcodeproj -scheme openola -configuration Debug build
```

To build a distributable app bundle into `dist/Openola.app`:

```bash
cd /Users/scott/Desktop/Openola
./Scripts/package-app.sh
open dist/Openola.app
```

To install the built app into `/Applications`:

```bash
cd /Users/scott/Desktop/Openola
INSTALL_APP=1 ./Scripts/package-app.sh
open /Applications/Openola.app
```

## Permissions

The app needs:

- Microphone access
- Speech Recognition access
- Screen and system-audio capture access

The prompts should appear when you start a live meeting.

## Why permissions can keep resetting

macOS TCC permissions are tied to the app's code-signing identity, not just the bundle name. If you rebuild and repackage an ad-hoc signed app, the signing requirement changes and the OS may ask for permissions again.

To make the permission choice stick:

1. Keep the bundle identifier stable: `wonderwhat.openola`
2. Sign with the same real identity every time
3. Launch the installed app from a stable location like `/Applications/Openola.app`
4. Rebuild over the same installed app instead of opening fresh debug copies

## Current limits

- Live transcription still uses Apple Speech, so this is not yet the local Whisper backend the product ultimately wants.
- Speaker capture now uses ScreenCaptureKit, but it still is not guaranteed parity for every Zoom, Meet, or Slack setup.

## Next sensible steps

1. Swap Apple Speech for a local Whisper pipeline.
2. Add a better capture path for remote call audio on macOS.
3. Add write endpoints to the local API for agent-driven workflows.
4. Clean up old template-era data and simplify the meeting model further.
