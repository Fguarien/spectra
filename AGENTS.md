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

## Layout

- `Sources/Spectra/Plex/` — plex.tv PIN auth, server discovery, library API, stream URLs.
- `Sources/Spectra/Player/` — AVPlayer queue engine + system Now-Playing / remote commands.
- `Sources/Spectra/Data/` — GRDB store, records, and the Prism `Items.db` importer.
- `Sources/Spectra/State/` — `AppModel` orchestrator.
- `Sources/Spectra/UI/` — SwiftUI views (login, three-column library, now-playing bar).

## Data notes (reverse-engineered from a Prism export)

- Prism's `Items.db` is a GRDB/SQLite file; DATETIME columns are Unix-epoch
  integers, `duration` is in seconds, a track's Plex rating key is `trackId`.
- The Plex account token is a secret: stored only in the macOS Keychain, never
  on disk in cleartext, never logged.

## Roadmap to a complete clone

Done (phase 1): Plex link auth, server discovery, artist/album/track browse,
streaming playback, queue + transport, system Now-Playing, Plex scrobble,
Prism import (tracks + play history).

Next: star ratings sync, playlists (read+write), full-text search, similar
artists, offline downloads, theming, gapless/transcode fallback for `ape`.
