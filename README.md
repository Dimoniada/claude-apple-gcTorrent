# claude-apple-gcTorrent

https://www.icloud.com/shortcuts/7acd2a94bf87412da9d5a707f6d7e3d4

**A gcTorrent client that runs entirely on a stock iPhone or iPad — no jailbreak, no seedbox, no App Store torrent app — driven by an iOS Shortcut.**

The [`rtorrent`](https://github.com/rakshasa/rtorrent) runs inside [iSH](https://ish.app) (an Alpine Linux userland on iOS). A tiny, dependency-free Python **bridge** fronts rtorrent's SCGI interface as a clean HTTP + JSON API on loopback, and the native **Shortcuts** app is the UI: add a magnet or `.torrent`, watch progress, pause/resume/remove — all on the device, over `127.0.0.1`.

---

## Why

- **No jailbreak** and **no App Store torrent client** — everything runs in userland apps you can install today.
- **No remote seedbox / VPS** — the torrents live and download on *your* phone.
- **Native UI** — the control surface is an iOS Shortcut (share-sheet + menu), with an optional live dashboard.

## How it works

```
┌─────────────┐   share / clipboard / tap          all on-device, over loopback
│  Shortcut   │ ────────────────────────────┐
│ "Torrent    │                             │
│   Saver"    │        HTTP + JSON           ▼
└─────────────┘        (127.0.0.1:5001)  ┌──────────┐   SCGI / XML-RPC   ┌──────────┐
┌─────────────┐  fetch()  ──────────────▶│bridge.py │ ─────────────────▶│ rtorrent │
│ Scriptable  │ ────────────────────────▶│  (HTTP)  │  (127.0.0.1:5000) │          │
│ dashboard   │                          └──────────┘                   └──────────┘
└─────────────┘                                    └──── all inside iSH (Alpine) ────┘
```

- **`bridge.py`** translates HTTP + JSON ⇄ rtorrent's SCGI/XML-RPC. **Standard library only** — the only iSH-side dependency is `python3`.
- Everything binds `127.0.0.1`, so nothing is exposed off the device.
- **`work.sh`** keeps the stack alive: it starts the bridge, uses the iOS location API as a background keep-alive, and launches rtorrent.

## Components

| Piece | Where | Role |
|---|---|---|
| **`install.sh`** | this repo | Self-extracting one-time installer. Bundles `bridge.py` + `work.sh` (as heredocs), installs `python3` + `rtorrent`, writes `~/.rtorrent.rc`, and adds a `.profile` autostart hook. |
| **`bridge.py`** | bundled in `install.sh` → `~/gctorrent/bridge.py` | The HTTP + JSON API on `127.0.0.1:5001`. Stdlib-only. |
| **`work.sh`** | bundled in `install.sh` → `~/gctorrent/work.sh` | Boots bridge + location keep-alive + rtorrent on every iSH launch. |
| **`howto_downloads.gif`** | this repo → served at `/help/howto_downloads.gif` | Short clip showing how to find the downloads folder in Files. |
| **`Torrent_Saver.shortcut`** | this repo (also on device) | The UI Shortcut: add from share sheet / clipboard, manage torrents, setup menu. Download and import it (see below). |
| **`dashboard.js`** | device-side ([Scriptable](https://scriptable.app)) | A live, polling status dashboard (WebView). |

## Requirements

- iPhone / iPad with these free apps: **[iSH Shell](https://apps.apple.com/app/ish-shell/id1436902243)**, **[Shortcuts](https://apps.apple.com/app/shortcuts/id915249334)**, and optionally **[Scriptable](https://apps.apple.com/app/scriptable/id1405459188)** for the dashboard.
- **iSH → Settings → Location → Always.** rtorrent runs as iSH's foreground app; the location keep-alive is what lets it survive in the background. Without it, rtorrent only runs while iSH is open in the foreground.
- **iSH → Settings → Files integration ON** if you want to reach the downloads folder from the Files app.

## Install

In iSH, paste and run:

```sh
cd /root && apk update && apk add ca-certificates wget && \
  wget -qO install.sh https://raw.githubusercontent.com/Dimoniada/claude-apple-gcTorrent/main/install.sh && \
  sh install.sh
```

`install.sh` extracts the scripts to `~/gctorrent/`, installs the packages, and starts everything (it `exec`s `work.sh` at the end). On later launches the `.profile` autostart hook starts the stack automatically — nothing to type. Grant the **Location → Always** prompt on first run.

> **Flaky iSH networking?** apk fetches can drop ("DNS lookup error" / "network error"). The installer retries transient failures automatically; if it still fails, toggle Airplane mode or set a resolver (`echo "nameserver 1.1.1.1" > /etc/resolv.conf`) and re-run.

### Get the Shortcut

Download **[`Torrent_Saver.shortcut`](Torrent_Saver.shortcut)** from this repo and open it to import into the Shortcuts app. Importing a file directly needs **Settings → Shortcuts → Allow Untrusted Shortcuts** enabled. (Hosting the file here — rather than only an iCloud share link — keeps it available regardless of Apple's link moderation.)

## Using it — the "Torrent Saver" Shortcut

The Shortcut is the front end; its first action sets `BaseURL` to `http://127.0.0.1:5001`. Before acting it `GET /ping`s and reacts to the state — `DAEMON_BUSY` → "wait a moment and re-run", `DETACHED` → "update was interrupted, reinstall", `DAEMON_UNREACHABLE` → start / reopen iSH. Running it opens a menu:

- **🧲 Use link/file in clipboard** — adds whatever's on the clipboard. You can also **share** a magnet or `.torrent` straight to the Shortcut. Either way it base64-encodes the input and POSTs `/add`, and the bridge auto-detects magnet vs. link vs. `.torrent` file. On the first add it asks once for the download subfolder and remembers it (`/settings` → `lastPath`).
  - Use a **magnet** or an **already-downloaded `.torrent` file**. A login-gated tracker "download" page (e.g. rutracker's `dl.php?t=…`) can't be fetched without your cookies, so the bridge returns `NOT_A_TORRENT` instead of silently adding nothing.
- **📂 Existing torrents** — lists active torrents (via `/status`); tap one for **▶️ Resume**, **⏸ Pause**, **❌ Stop & Remove** (📁 keep or 🗑 delete data), **⚠️ Error info**, or **🎬 Find downloads**.
- **⚙️ Set up / reinstall** — 1) Install iSH · 2) Install backend (⤵️ new install / 🔄 update; the update path `POST /detach`es first) · 3) Install Scriptable · **📊 Dashboard settings** (the poll rate, stored via `/settings` → `pollMs`) · **🛟 Help** (📖 Readme / 🔗 GitHub / 🎬 Find downloads).

### Dashboard

**📊 Dashboard** opens the Scriptable WebView, which polls `/status` and renders a live table (rate, %, status icon). Its refresh rate comes from `/settings` → `pollMs`.

### Where downloads go

rtorrent downloads to iSH-local `/root/downloads`. With iSH Files integration on, that's visible in **Files → On My iPhone → iSH → root → downloads**. The **🎬 Find downloads** item (in Help and in each torrent's menu) shows a short clip on how to get there, fetched from the bridge at `/help/howto_downloads.gif` and shown with Quick Look.

### Maintenance mode (detach / attach)

The Shortcut's **🔄 Update** path `POST /detach`es before reinstalling: rtorrent stops but the bridge keeps answering, so the Shortcut still gets a clean response instead of a connection error. `/ping` then reports `DETACHED` (surfaced as "update was interrupted"). Finishing the reinstall — which clears the flag — resumes it (or `POST /attach` + reopening iSH).

## The bridge API

Base URL `http://127.0.0.1:5001`. All responses are JSON; errors are `{"ok": false, "error": "<CODE>"}`.

| Method | Endpoint | Body | Result |
|---|---|---|---|
| GET | `/ping` | — | `{"ok": true}` when running; otherwise `{"ok": false, "error": <CODE>}` |
| GET | `/status` | — | `{"ok": true, "torrents": [...]}` |
| GET | `/status?short=<6hex>` | — | same, filtered to 0 or 1 torrent by short hash |
| GET | `/settings` | — | `{"ok": true, "lastPath": "<str>", "pollMs": <int>}` |
| GET | `/help/howto_downloads.gif` | — | `image/gif` |
| POST | `/add` | `{"url":…, "directory":…}` **or** `{"data":<base64>, "directory":…}` | `{"ok": true}` — `data` is base64 of a magnet/link **or** a `.torrent` file; the bridge auto-detects |
| POST | `/pause` | `{"hash":…}` | `{"ok": true}` (rtorrent `d.stop`) |
| POST | `/resume` | `{"hash":…}` | `{"ok": true}` (rtorrent `d.start`) |
| POST | `/remove` | `{"hash":…, "deleteFile":bool}` | `{"ok": true}` |
| POST | `/settings` | `{"lastPath":…}` and/or `{"pollMs":…}` | `{"ok": true}` (partial update) |
| POST | `/detach` | — | `{"ok": true}` (enter maintenance mode) |
| POST | `/attach` | — | `{"ok": true}` (leave maintenance mode) |

**Torrent object** (from `/status`):

```json
{
  "hash": "E29C2E…",        "shortHash": "e29c2e",
  "name": "…",              "status": "DOWNLOADING",
  "message": "",            "downRate": 512000,
  "upRate": 0,              "percent": 12.5,
  "label": "⬇️ (12.5%) … (#e29c2e)"
}
```

`status` is one of: `DOWNLOADING`, `UPLOADING`, `DOWNLOADING&UPLOADING`, `DONE`, `CHECKING`, `PAUSED`, `IDLE`, `ERROR`. `label` is a ready-made row (`<icon> (<pct>%) <name> (#<shortHash>)`) so the Shortcut needn't build it.

**Error codes:**

| Code | Meaning |
|---|---|
| `DAEMON_UNREACHABLE` | rtorrent isn't listening (down, or still starting) |
| `DAEMON_BUSY` | rtorrent is alive but pinned (hash-checking) — retry in a moment |
| `DETACHED` | maintenance mode — rtorrent intentionally off, bridge still answers |
| `NOT_A_TORRENT` | an http(s) link that didn't return a `.torrent` (login page / 404 / wrong link) |
| `INVALID_LINK` | not a magnet, http(s) link, or bencoded `.torrent` |
| `BAD_REQUEST` | missing/invalid parameters |
| `NOT_FOUND` | unknown endpoint |

## Security & trust model

- The bridge binds **`127.0.0.1` only** — single-user device, nothing is reachable off-device.
- **No auth token** today (loopback-only makes it unnecessary in practice).
- Torrent names/messages are HTML-escaped in the dashboard.

## Roadmap

- **Asynchronous, command-driven bridge** — actions enqueue a command and return immediately (⏳ pending), applied to rtorrent by a background worker that retries on `DAEMON_BUSY`, with an interactive Scriptable dashboard (per-row buttons) as the primary control surface.

## Repository layout

```
install.sh              self-extracting installer (bundles bridge.py + work.sh)
Torrent_Saver.shortcut  the iOS Shortcut (import into the Shortcuts app)
howto_downloads.gif     help clip served at /help/howto_downloads.gif
README.md               this file
LICENSE                 MIT
```

The Scriptable `dashboard.js` lives on the device.

## License

[MIT](LICENSE).
