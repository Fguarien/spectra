# Spectra

A native macOS music player (Plex, local folders, YouTube Music), written in
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

- `Sources/Spectra/Providers/` — `MusicProvider` protocol + Plex, local-files
  and YouTube Music providers; `catalog()` lists a whole source.
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

## Status

v2.x — Music.app-style window over a merged, cached library from several
sources (Plex, local folders, YouTube Music): All Libraries + one Library row
per source, grid/list views, Songs table with persisted columns, instant
search, Spectra playlists, Radio ♥, queue + history, downloads, mini and
full-screen players. User-facing documentation: `README.md` and the in-app
help (`UI/HelpView.swift`) — keep both in step with features.

## Conventions

- Secrets (tokens, API keys) only in the Keychain (`Support/Keychain.swift`),
  provisioned through one-shot JSON files that are imported then deleted.
  Never in UserDefaults, the database, logs or argv.
- Signing: `make-app.sh` uses `SPECTRA_SIGN_ID`, else the keychain made by
  `Tools/make-signing-keychain.sh`, else ad hoc (Keychain re-prompts each build).
- Nothing environment-specific in the code: endpoints and paths are settings
  with neutral defaults (`~/Music/Spectra`, no LLM endpoint).
- Catalogue grouping runs off the main actor (`CatalogStore.build` is
  `nonisolated static`); views read precomputed values, never re-normalise
  thousands of strings per keystroke.
