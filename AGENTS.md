# Spectra

A native macOS (Intel x86_64) music player for a Plex Media Server, written in
Swift/SwiftUI. Original code — not derived from any proprietary binary; it
reimplements, against the public Plex HTTP API, the behaviour of a Plex music
client and migrates a user's own data from a Prism `Items.db` export.

## Build (on an Intel Mac with Xcode installed)

```bash
./make-app.sh release     # SwiftPM build + assembles Spectra.app
open Spectra.app
```

No `.xcodeproj`: the app is a SwiftPM executable target, bundled by `make-app.sh`.
Dependency: GRDB 7.11.0 (pinned).

`./make-app.sh release --install` also copies the bundle into `/Applications`.
The app icon (a prism splitting white light) is generated reproducibly by
`Tools/make-icon.swift` on first build — no binary asset is committed.

## Layout

- `Sources/Spectra/Plex/` — plex.tv PIN auth, server discovery, library API,
  search, playlists, ratings, stream + universal-transcode URLs.
- `Sources/Spectra/Player/` — AVQueuePlayer gapless engine (shuffle/repeat/
  reorder), system Now-Playing / remote commands, and the offline download manager.
- `Sources/Spectra/Data/` — GRDB store, records, and the schema-adaptive Prism
  `Items.db` importer (tracks, plays, tags, similar artists, playlists).
- `Sources/Spectra/State/` — `AppModel` orchestrator + `ThemeManager`.
- `Sources/Spectra/UI/` — SwiftUI views (sidebar, library, playlists, search,
  downloads, settings, queue, now-playing bar).
- `Tools/make-icon.swift` — CoreGraphics app-icon generator.

## Data notes (reverse-engineered from a Prism export)

- Prism's `Items.db` is a GRDB/SQLite file; DATETIME columns are Unix-epoch
  integers, `duration` is in seconds, a track's Plex rating key is `trackId`.
- The Plex account token is a secret: stored only in the macOS Keychain, never
  on disk in cleartext, never logged.

## Status — complete clone

Delivered: Plex link auth, server discovery, artist/album/track browse,
streaming playback, system Now-Playing + remote commands, Plex scrobble,
Prism import (tracks, plays, tags, similar artists, playlists); star ratings
(local + Plex `/:/rate`), playlists (read/play/delete/add + recreate imported
Prism ones), server-side search, similar artists, offline downloads + local
playback, Auto/Light/Dark themes with accent + text size, universal-transcode
fallback for `ape` and other non-AVFoundation codecs, gapless queue with
shuffle / repeat / reorder / remove / jump, app icon, `/Applications` install.

Possible follow-ups (not required for parity): smart playlists, lyrics,
sonic-analysis mixes, multi-server switching.
