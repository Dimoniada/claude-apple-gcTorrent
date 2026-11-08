# claude-apple-gcTorrent

**A gcTorrent client that runs entirely on a stock iPhone or iPad — no jailbreak, no seedbox, no App Store torrent app. An iOS Shortcut installs and launches it; an installable PWA is the UI.** The same Shortcut and installer also run natively on a Mac (no iSH needed there).

The [`rtorrent`](https://github.com/rakshasa/rtorrent) runs inside [iSH](https://ish.app) (an Alpine Linux userland on iOS). A tiny, dependency-free Python **bridge** fronts rtorrent's SCGI interface as a file AF_UNIX socket + JSON API on loopback. The UI is an installable **PWA** (served by the bridge itself at `/app`): add a magnet or `.torrent`, watch progress, pause/resume/remove — all on the device, over `127.0.0.1`. The native **Shortcuts** app is a thin **launcher / installer** — it installs the backend, and its everyday action just opens iSH and then the PWA.

The bridge is **asynchronous and command-driven**: control actions enqueue a command and return instantly, and a single background worker applies them to rtorrent (retrying while the daemon is busy) so the UI never blocks on a slow or pinned daemon.

---

## Why

- **No jailbreak** and **no App Store torrent client** — everything runs in userland apps you can install today.
- **No remote seedbox / VPS** — the torrents live and download on *your* phone.
- **Simple UI** — the control surface is an installable **PWA** served by the bridge itself; a native iOS Shortcut installs the backend and opens it (tap / share / clipboard).

## How it works

```
┌─────────────┐  tap / share / clipboard        all on-device, over loopback
│  Shortcut   │ ── opens iSH + the PWA ──┐  (also POST /detach on update)
│ "Torrent    │                          │
│   Saver"    │                          ▼
└─────────────┘                    ┌──────────┐   SCGI / XML-RPC   ┌──────────┐
┌─────────────┐  fetch()  ────────▶│bridge.py │ ─────────────────▶│ rtorrent │
│  PWA in the │ ──────────────────▶│  (HTTP)  │     (AF_UNIX)      │          │
│  Default    │   (127.0.0.1:5001) └──────────┘                    └──────────┘
│  Browser    │                             └──── all inside iSH (Alpine) ────┘
└─────────────┘
```

- **`bridge.py`** translates HTTP + JSON ⇄ rtorrent's SCGI/XML-RPC. **Standard library only** — the only iSH-side dependency is `python3`.
- Everything binds `127.0.0.1`, so nothing is exposed off the device.
- **`work.sh`** keeps the stack alive: it starts the bridge, uses the iOS location API as a background keep-alive, and launches rtorrent.

## Components

| Piece | Where | Role |
|---|---|---|
| **`install.sh`** | this repo | Self-extracting one-time installer. Bundles `bridge.py` + `work.sh` (as heredocs), installs `python3` + `rtorrent`, writes `~/.rtorrent.rc`, and adds a `.profile` autostart hook. |
| **`bridge.py`** | bundled in `install.sh` → `~/gctorrent/bridge.py` | The HTTP + JSON API on `127.0.0.1:5001`. Stdlib-only. Runs an async command queue + background worker, and serves the PWA. |
| **`work.sh`** | bundled in `install.sh` → `~/gctorrent/work.sh` | Boots bridge + location keep-alive + rtorrent on every iSH launch. |
| **`app.html`** | bundled in `install.sh` → `~/gctorrent/app.html`; served at `/app` | Standalone installable **PWA** ("Torrent Saver"). Same-origin with the bridge, so no CORS. Add to Home Screen for a full-screen app. |
| **`howto_downloads.gif`** | this repo → served at `/help/howto_downloads.gif` | Short clip showing how to find the downloads folder in Files. |
| **`Torrent_Saver.shortcut`** | this repo (also on device) | The launcher / installer Shortcut: install iSH, install/update the backend, and open the PWA. Download and import it (see below). |

## Requirements

- iPhone / iPad with these free apps: **[iSH Shell](https://apps.apple.com/app/ish-shell/id1436902243)** and **[Shortcuts](https://apps.apple.com/app/shortcuts/id915249334)**.
- **iSH → Settings → Location → Always.** rtorrent runs as iSH's foreground app; the location keep-alive is what lets it survive in the background. Without it, rtorrent only runs while iSH is open in the foreground.
- **iSH → Settings → Files integration ON** if you want to reach the downloads folder from the Files app.
- Mac: [Homebrew](https://brew.sh) and the Shortcuts app (built in). No iSH: the iOS version of iSH runs on Apple-silicon Macs, but its Files integration crashes there, and a Mac can run rtorrent natively anyway.

## Install

In iSH, paste and run:

```sh
cd /root && apk update && apk add ca-certificates wget && \
  wget -qO install.sh https://raw.githubusercontent.com/Dimoniada/claude-apple-gcTorrent/main/install.sh && \
  sh install.sh
```

`install.sh` extracts the scripts to `~/gctorrent/`, installs the packages, and starts everything (it `exec`s `work.sh` at the end). On later launches the `.profile` autostart hook starts the stack automatically — nothing to type. Grant the **Location → Always** prompt on first run.

> **Flaky iSH networking?** apk fetches can drop ("DNS lookup error" / "network error" / "could not resolve host"). The installer retries transient failures automatically and appends a public DNS fallback (`8.8.8.8`) so lookups keep working even when the network — a PC/phone hotspot especially — hands iSH an unreachable resolver. If it still fails, toggle Airplane mode or set a resolver manually (`echo "nameserver 8.8.8.8" > /etc/resolv.conf`) and re-run.

### Install on a Mac

The same `install.sh` detects macOS. In **Terminal**, paste and run (the Shortcut's **2) Install backend** copies this for you and opens Terminal):

```sh
curl -fsSL -o /tmp/gctorrent-install.sh https://raw.githubusercontent.com/Dimoniada/claude-apple-gcTorrent/main/install.sh && sh /tmp/gctorrent-install.sh
```

On a Mac it:

- installs `rtorrent` with Homebrew (and `python3` only if neither Homebrew's nor Apple's works);
- puts the scripts in `~/gctorrent/`, with rtorrent's config in `~/gctorrent/config/rtorrent/rtorrent.rc`, so an existing `~/.rtorrent.rc` of yours is never touched;
- installs a LaunchAgent, `~/Library/LaunchAgents/io.github.dimoniada.gctorrent.plist`, in place of iSH's `.profile` hook and Location trick. The backend starts at every login and launchd restarts it if it dies. macOS shows a "Background Items Added" notice the first time;
- runs rtorrent headless (`system.daemon.set`), so there's no terminal UI, and opens `http://127.0.0.1:5001/app` when done.

Homebrew ships rtorrent 0.16, which renamed a few settings compared with iSH's Alpine build. The Mac config uses the new names: `network.listen.port.*`, `schedule`, and log groups `errors`/`events`.

To uninstall on a Mac:

```sh
launchctl bootout gui/$(id -u)/io.github.dimoniada.gctorrent; rm -f ~/Library/LaunchAgents/io.github.dimoniada.gctorrent.plist; rm -rf ~/gctorrent
```

(Your downloads in `~/Downloads` are kept.)

### Get the Shortcut

Download **[`Torrent_Saver.shortcut`](Torrent_Saver.shortcut)** (https://routinehub.co/shortcut/26039/) from this repo and open it to import into the Shortcuts app. Importing a file directly needs **Settings → Shortcuts → Allow Untrusted Shortcuts** enabled. (Hosting the file here — rather than only an iCloud share link — keeps it available regardless of Apple's link moderation.) It's one Shortcut for iPhone, iPad and Mac: it checks the device model and takes the Mac path when it contains "Mac", so the copy synced through iCloud works everywhere.

## Using it — the "Torrent Saver" Shortcut

The Shortcut is a thin **launcher / installer**, not the torrent UI — the actual control surface is the PWA it opens. Its first action sets `BaseURL` to `http://127.0.0.1:5001`. Running it (tap it, or trigger it from the share sheet / with a clipboard item) opens a menu:

- **⚙️ Set up / reinstall** — a setup submenu:
  - **1) Install iSH** — opens the iSH App Store page.
  - **2) Install backend** — **⤵️ New install** or **🔄 Update**: both copy the one-line install command (below) to the clipboard and show a short "paste it into iSH" instruction; the **🔄 Update** path first `POST`s `/detach` so rtorrent steps aside cleanly while you reinstall. **⬅️ Return** goes back.
  - **🛟 Help** — **📖 Readme** (shows the dependency checklist: iSH with Location → Always, free ports 5000 & 5001, a web connection for ~60 Mb), **🔗 GitHub** (opens this repo), **⬅️ Return**.
  - **⬅️ Return** — back to the top menu.
- **🏴‍☠️ Torrent Saver** — the everyday entry point. It opens **iSH** (so the stack comes up), waits a moment, then opens the installable **PWA** (`BaseURL/app`) in your default browser — that's where you add magnets / `.torrent`s and manage torrents.
- **🚼 Exit** — close the Shortcut.

On a Mac there's no iSH step:

- **⚙️ Set up / reinstall** shows a Mac menu: **⤵️ Install / update backend** (copies the Mac install command, shows how to paste it, and opens **Terminal**; no `/detach`, because the installer stops the old backend itself), **🛟 Help** and **⬅️ Return**.
- **🏴‍☠️ Torrent Saver** opens the PWA straight away, because the LaunchAgent keeps the backend running.

### The PWA app — the UI

The bridge serves a standalone **PWA** at `http://127.0.0.1:5001/app`; this is the control surface. The Shortcut's **🏴‍☠️ Torrent Saver** opens it for you, or you can open it directly in Safari or Orion and **Share → Add to Home Screen** to install it as a full-screen app with its own icon and name ("Torrent Saver"). Because the page is served from the bridge's own origin, every `fetch()` is same-origin — no CORS and no host injection. The PWA polls `/status` for a live list and drives every action (add, resume, pause, remove) through the async `/command` queue, so a busy or briefly unreachable rtorrent shows a degraded banner and the pending-command chain instead of erroring out; queued commands can be dragged to the bin (`/command/cancel`) before they run.

### Where downloads go

rtorrent downloads to iSH-local `/root/downloads`. With iSH Files integration on, that's visible in **Files → On My iPhone → iSH → root → downloads**. A short clip on how to get there is served by the bridge at `/help/howto_downloads.gif`.

On a Mac, `~/Downloads` plays the role of `/root`: a blank folder saves to `~/Downloads`, and a typed folder `movies` becomes `~/Downloads/movies`.

### Maintenance mode (detach / attach)

The Shortcut's **🔄 Update** path `POST`s `/detach` before you reinstall: rtorrent stops but the bridge keeps answering, so `/ping` reports `DETACHED` (maintenance) instead of refusing the connection. Finishing the reinstall clears the flag and resumes it (or `POST /attach` + reopening iSH).

## The bridge API

Base URL `http://127.0.0.1:5001`. All responses are JSON; errors are `{"ok": false, "error": "<CODE>"}`.

| Method | Endpoint | Body | Result |
|---|---|---|---|
| GET | `/ping` | — | `{"ok": true}` when running; otherwise `{"ok": false, "error": <CODE>}` |
| GET | `/status` | — | `{"ok": true, "torrents": [...]}` |
| GET | `/status?short=<6hex>` | — | same, filtered to 0 or 1 torrent by short hash |
| GET | `/settings` | — | `{"ok": true, "lastPath": "<str>", "pollMs": <int>}` |
| GET | `/help/howto_downloads.gif` | — | `image/gif` |
| GET | `/app` (also `/`) | — | `text/html` — the standalone "Torrent Saver" PWA page |
| GET | `/manifest.json` | — | Web app manifest for the PWA install |
| POST | `/add` | `{"url":…, "directory":…}` **or** `{"data":<base64>, "directory":…}` | `{"ok": true}` — `data` is base64 of a magnet/link **or** a `.torrent` file; the bridge auto-detects |
| POST | `/pause` | `{"hash":…}` | `{"ok": true}` (rtorrent `d.stop`) |
| POST | `/resume` | `{"hash":…}` | `{"ok": true}` (rtorrent `d.start`) |
| POST | `/remove` | `{"hash":…, "deleteFile":bool}` | `{"ok": true}` |
| POST | `/settings` | `{"lastPath":…}` and/or `{"pollMs":…}` | `{"ok": true}` (partial update) |
| POST | `/command` | `{"action":…, "hash":…, "args":…, "id":…}` | `{"ok": true, "id": <str>}` — enqueue a command; the background worker applies it to rtorrent |
| POST | `/command/cancel` | `{"id":…}` | `{"ok": bool, "id": <str>}` — pull a still-queued command out of the chain |
| POST | `/detach` | — | `{"ok": true}` (enter maintenance mode) |
| POST | `/attach` | — | `{"ok": true}` (leave maintenance mode) |

`/status` also carries `"rtorrentState"` (`ONLINE` / `DAEMON_BUSY` / `DAEMON_UNREACHABLE` / `DETACHED`) and `"queue"` (the public view of pending commands), so the PWA can render the queued-command chain and a degraded banner even when rtorrent is temporarily unreachable.

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

`status` is one of: `DOWNLOADING`, `UPLOADING`, `DOWNLOADING&UPLOADING`, `DONE`, `CHECKING`, `PAUSED`, `IDLE`, `ERROR`. `label` is a ready-made row (`<icon> (<pct>%) <name> (#<shortHash>)`) so the PWA needn't build it.

**Error codes:**

| Code | Meaning |
|---|---|
| `DAEMON_UNREACHABLE` | rtorrent isn't listening (down, or still starting) |
| `DAEMON_BUSY` | rtorrent is alive but pinned (hash-checking) — retry in a moment |
| `DETACHED` | maintenance mode — rtorrent intentionally off, bridge still answers |
| `NOT_A_TORRENT` | an http(s) link that didn't return a `.torrent` (login page / 404 / wrong link) |
| `INVALID_LINK` | not a magnet, http(s) link, or bencoded `.torrent` |
| `BAD_REQUEST` | missing/invalid parameters (including a folder name with `"` or `\`) |
| `FORBIDDEN` | a POST from another web page (its `Origin` isn't the bridge's own) |
| `NOT_FOUND` | unknown endpoint |

## Security & trust model

- The bridge binds **`127.0.0.1` only** — single-user device, nothing is reachable off-device.
- **No auth token today.** Web pages in your browser can still send requests to `127.0.0.1`, so every POST carrying an `Origin` other than the bridge's own (`http://127.0.0.1:5001` / `http://localhost:5001`) is refused with `FORBIDDEN`. The Shortcuts app sends no `Origin`, so it keeps working. There is no CORS header, so other pages can't read `/status` either.
- Folder names with `"` or `\` are refused: the folder goes inside an rtorrent command string, and a quote would let the rest run as extra rtorrent commands.
- `sh tests/security_check.sh` checks both against a running bridge (needs `curl`, e.g. on a Mac).
- Torrent names/messages are HTML-escaped in the PWA.
- On a Mac `127.0.0.1` is shared by every local account, so another user logged in to the same Mac could reach the bridge. rtorrent's SCGI socket, which can run commands, stays private (`~/gctorrent/state` is `chmod 700`, without iSH's `0777`).

## Roadmap

- **Asynchronous, command-driven bridge** — ✅ implemented. Actions enqueue a command and return immediately (⏳ pending), applied to rtorrent by a background worker that retries on `DAEMON_BUSY`. The installable PWA (`/app`) is the interactive control surface with per-row buttons and drag-to-cancel of queued commands.

## Repository layout

```
install.sh              self-extracting installer (bundles bridge.py + work.sh + app.html PWA)
Torrent_Saver.shortcut  the Shortcut for iPhone, iPad and Mac (import into the Shortcuts app)
howto_downloads.gif     help clip served at /help/howto_downloads.gif
README.md               this file
LICENSE                 MIT
```

## License

[MIT](LICENSE).
