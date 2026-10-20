# Spectra

A native macOS music player in the style of Apple Music, for the music you
already own — wherever it lives. Spectra merges three kinds of library into one
window:

- **Plex Media Server** — every music section of your server;
- **Local folders** — audio files on your Mac or on a mounted NAS share;
- **YouTube Music** — your own library (via [ytmusicapi]) or search-only.

Written in Swift / SwiftUI, no Electron, no web view. Original code: Plex is used
through its public HTTP API; nothing is derived from a proprietary client.

## Features

- **All Libraries** — one merged library: one album, one copy per song, picked
  in the order Local → Plex → YouTube Music. A badge on each cover shows which
  sources hold it.
- **Library** — one sidebar row per source, with only that source's albums and
  songs. Rename or refresh each row from its context menu.
- **Music.app-style pages** — Recently Added, Recently Played, Artists, Albums,
  Songs, Genres. Albums and Artists can be viewed as a grid or as a list. The
  Songs table has sortable, resizable, hideable columns, remembered per page.
- **Fast search** — instant over the cached library; each online source adds its
  results as it answers.
- **Offline-first catalogue** — each source is listed once into a local SQLite
  cache, then refreshed in the background every hour (⌘R to force).
- **Playlists** — Spectra playlists mix songs from every source (⌘N, rename,
  delete, download); Plex and YouTube Music playlists are listed too.
- **Favourite Songs and Radio ♥** — love a song (⌘L) to build a playlist of
  similar tracks from Last.fm, optionally curated by an LLM behind any
  OpenAI-compatible endpoint.
- **Playback** — gapless queue, shuffle / repeat, Playing Next and History,
  mini player, full-screen player, AirPlay, system Now Playing and media keys,
  Plex scrobbling and Last.fm scrobbling.
- **Downloads** — songs or whole playlists to a storage folder
  (`~/Music/Spectra` by default, or a NAS share: downloads wait while it is not
  mounted and resume when it is).
- **Database backups** — the local database is copied every hour to the storage
  folder's `Backup/`.

## Requirements

- macOS 14 Sonoma or later (developed on Intel; Apple silicon should build too).
- Xcode or the Swift 6 command-line tools.
- For YouTube Music: [`yt-dlp`] on the `PATH` (Homebrew: `brew install yt-dlp`),
  and for your own library a Python virtualenv with [ytmusicapi].

## Build and install

```bash
git clone https://github.com/Fguarien/spectra.git
cd spectra
./make-app.sh release            # builds Spectra.app here
./make-app.sh release --install  # … and copies it into /Applications
```

There is no `.xcodeproj`: Spectra is a SwiftPM executable target, assembled into
an app bundle by `make-app.sh`. The only dependency is [GRDB] (pinned). The app
icon is drawn by `Tools/make-icon.swift` at build time — no binary asset is
committed.

### Signing (avoids Keychain prompts after each build)

The macOS Keychain ties stored tokens to the app's *designated requirement*.
Signed ad hoc, that requirement is the binary's hash, so after every rebuild
the Keychain asks again for each token. `make-app.sh` signs with a stable
identity when it finds one, in this order:

1. `SPECTRA_SIGN_ID=<identity> ./make-app.sh …` — any code-signing identity
   you have (e.g. Apple Development);
2. the « Spectra Local Signing » certificate created once by
   `Tools/make-signing-keychain.sh` — a self-signed certificate in its own
   keychain that unlocks without interaction, so it also works when you build
   over SSH (read the trade-off at the top of the script);
3. otherwise ad hoc — choose **Always Allow** after each build.

Check: `codesign -dr - /Applications/Spectra.app` should show
`certificate leaf = H"…"`, not `cdhash H"…"`.

## Setting up sources

### Plex
File → **Add Plex Account…**. Spectra opens plex.tv with a link code; approve it
and the server is found automatically. Every music section is read.

### Local folder
File → **Add Local Folder…** and pick a folder. Tags and durations are read from
the files.

### YouTube Music
Search and playback work without an account. For your own library:

```bash
mkdir -p ~/Developer/spectra-ytmusic && cd ~/Developer/spectra-ytmusic
python3 -m venv venv && venv/bin/pip install ytmusicapi
cp /path/to/spectra/Tools/ytmusic_bridge.py .
venv/bin/ytmusicapi browser     # paste your request headers → browser.json
```

Then File → **Add YouTube Music** and choose that `browser.json`. Spectra looks
for `venv/bin/python` and `ytmusic_bridge.py` next to it.

> Using yt-dlp / ytmusicapi with YouTube is against YouTube's Terms of Service.
> It is your account and your call.

### Last.fm (optional — scrobbling and Radio ♥)
Create an API account at <https://www.last.fm/api/account/create>, then write
the key pair once to
`~/Library/Application Support/Spectra/lastfm-provision.json`:

```json
{"api_key": "…", "shared_secret": "…"}
```

Spectra moves it into the Keychain and deletes the file at next launch. Then
Settings → Last.fm → Connect.

### LLM curation for Radio ♥ (optional)
Settings → Radio ♥: an OpenAI-compatible chat-completions URL (LiteLLM, Ollama,
OpenAI…) and a model name. The key goes, once, into
`~/Library/Application Support/Spectra/litellm-provision.json` as
`{"key": "sk-…"}` — imported into the Keychain, then deleted. Without it, Radio ♥
keeps Last.fm's own order.

## Privacy and secrets

Tokens and API keys live in the macOS Keychain only — never in preferences,
never in the database, never in logs. The YouTube Music `browser.json` stays
where you put it; Spectra only stores its path. Nothing is sent anywhere but to
your own sources, Last.fm and the LLM endpoint you configure.

## Data

| What | Where |
|---|---|
| Database (catalogue cache, playlists, history, likes) | `~/Library/Application Support/Spectra/spectra.sqlite` |
| Downloads, artwork, backups | Storage folder — Settings → Storage |
| Preferences | `defaults read eu.savethemall.spectra` |

## Layout

- `Sources/Spectra/Providers/` — the `MusicProvider` protocol and its Plex,
  local-files and YouTube Music implementations.
- `Sources/Spectra/Plex/` — plex.tv PIN auth, server discovery, library API.
- `Sources/Spectra/Data/` — GRDB database, the merged catalogue
  (`Catalog.swift`), local playlists, likes and history.
- `Sources/Spectra/Player/` — gapless AVQueuePlayer engine, Now Playing,
  downloads.
- `Sources/Spectra/Scrobble/`, `Radio/` — Last.fm and Radio ♥.
- `Sources/Spectra/UI/` — SwiftUI: the main window (`MusicWindow.swift`), the
  library pages (`LibraryPages.swift`), search, queue, settings, mini player.
- `Tools/` — icon generator and the YouTube Music bridge.

## Licence

MIT — see [LICENSE](LICENSE). Not affiliated with Apple, Plex or Google.

[ytmusicapi]: https://github.com/sigma67/ytmusicapi
[`yt-dlp`]: https://github.com/yt-dlp/yt-dlp
[GRDB]: https://github.com/groue/GRDB.swift
