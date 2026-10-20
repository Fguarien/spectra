#!/usr/bin/env python3
"""Spectra ↔ YouTube Music bridge.

Usage: ytmusic_bridge.py <auth.json|-> <command> [arg]
Emits normalized JSON {"items":[{id,title,subtitle?,type,thumb?,duration?,year?}]}
so the Swift side has one stable shape regardless of ytmusicapi internals.

Auth is only needed for the personal library (library_*, playlists, liked,
playlist_tracks). search / album_tracks / artist_albums are public and work
without it, so an unreadable auth path falls back to an anonymous client.
"""
import sys
import json

from ytmusicapi import YTMusic


def thumb(x):
    ts = (x or {}).get("thumbnails") or []
    return ts[-1].get("url") if ts else None


def arts(x):
    a = x.get("artists") or []
    return ", ".join(p.get("name", "") for p in a if p.get("name"))


def client(auth_path):
    if auth_path and auth_path != "-":
        try:
            return YTMusic(auth_path)
        except Exception:
            pass
    return YTMusic()


def main():
    auth_path = sys.argv[1] if len(sys.argv) > 1 else "-"
    cmd = sys.argv[2] if len(sys.argv) > 2 else ""
    arg = sys.argv[3] if len(sys.argv) > 3 else None
    yt = client(auth_path)
    items = []

    if cmd == "library_artists":
        for a in yt.get_library_artists(limit=1000):
            if a.get("browseId"):
                items.append({"id": a["browseId"], "title": a.get("artist"), "type": "artist", "thumb": thumb(a)})

    elif cmd == "library_albums":
        for a in yt.get_library_albums(limit=1000):
            if a.get("browseId"):
                items.append({"id": a["browseId"], "title": a.get("title"), "subtitle": arts(a),
                              "type": "album", "thumb": thumb(a), "year": a.get("year")})

    elif cmd == "library_songs":
        for t in yt.get_library_songs(limit=5000):
            if t.get("videoId"):
                al = t.get("album") or {}
                items.append({"id": t["videoId"], "title": t.get("title"), "subtitle": arts(t),
                              "type": "track", "duration": t.get("duration_seconds"), "thumb": thumb(t),
                              "album": al.get("name"), "albumId": al.get("id")})

    elif cmd == "artist_albums":
        d = yt.get_artist(arg)
        for sect in ("albums", "singles"):
            for a in ((d.get(sect) or {}).get("results") or []):
                if a.get("browseId"):
                    items.append({"id": a["browseId"], "title": a.get("title"), "type": "album",
                                  "thumb": thumb(a), "year": a.get("year")})

    elif cmd == "album_tracks":
        d = yt.get_album(arg)
        at = thumb(d)
        for t in (d.get("tracks") or []):
            if t.get("videoId"):
                items.append({"id": t["videoId"], "title": t.get("title"), "subtitle": arts(t) or d.get("title"),
                              "type": "track", "duration": t.get("duration_seconds"), "thumb": at})

    elif cmd == "playlists":
        items.append({"id": "LM", "title": "Liked Music", "type": "playlist", "thumb": None})
        for p in yt.get_library_playlists(limit=200):
            if p.get("playlistId"):
                items.append({"id": p["playlistId"], "title": p.get("title"), "type": "playlist", "thumb": thumb(p)})

    elif cmd == "playlist_tracks":
        d = yt.get_liked_songs(limit=2000) if arg == "LM" else yt.get_playlist(arg, limit=2000)
        for t in (d.get("tracks") or []):
            if t.get("videoId"):
                items.append({"id": t["videoId"], "title": t.get("title"), "subtitle": arts(t),
                              "type": "track", "duration": t.get("duration_seconds"), "thumb": thumb(t)})

    elif cmd == "search":
        for t in yt.search(arg or "", filter="songs", limit=25):
            if t.get("videoId"):
                items.append({"id": t["videoId"], "title": t.get("title"), "subtitle": arts(t),
                              "type": "track", "duration": t.get("duration_seconds"), "thumb": thumb(t)})

    else:
        print(json.dumps({"error": "unknown command: %s" % cmd}))
        return

    print(json.dumps({"items": items}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(json.dumps({"error": str(e)[:400]}))
        sys.exit(1)
