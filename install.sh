#!/bin/sh
# install.sh - one-time iSH setup for the rtorrent remote-control stack, in ONE
# self-contained file. It extracts the bundled bridge.py / work.sh / app.html to
# /root/gctorrent, installs the packages itself (python3, rtorrent), writes
# .rtorrent.rc + a .profile autostart hook, then execs work.sh — so the Torrent
# Downloader shortcut fetches and runs the whole first install in a single step:
#   … && sh install.sh
# work.sh is non-interactive; it just needs the iOS Location permission granted
# (Always) to keep running in the background.
set -e

echo "[0/4] extracting bundled bridge.py and work.sh..."
mkdir -p /root/gctorrent/state
cat > /root/gctorrent/bridge.py << '__GCTORRENT_BRIDGE_PY__'
#!/usr/bin/env python3
"""
bridge.py — runs INSIDE iSH, alongside rtorrent itself.

rtorrent's own SCGI port speaks the SCGI/XML-RPC protocol, which neither a
browser's fetch() nor the iOS Shortcuts "Get Contents of URL" action can talk
to directly. This script is the single translator: it listens on a plain-HTTP
port (127.0.0.1:5001) and exposes the whole control surface as JSON over the
shared iOS loopback network.

Endpoints (all responses are JSON; errors are {"ok": false, "error": "<CODE>"}):
    GET  /ping                                  -> {"ok": true}
      not-running states come back as {"ok": false, "error": <CODE>} where CODE
      is DETACHED (maintenance) / DAEMON_BUSY (hash-checking) / DAEMON_UNREACHABLE.
    GET  /status                                -> {"ok": true, "torrents": [...]}
    GET  /status?short=<6hex>                    -> {"ok": true, "torrents": [<0 or 1>]}
      each torrent includes a "label": "<icon> (<pct>%) <name> (#<shortHash>)"
    GET  /settings                              -> {"ok": true, "lastPath": "<str>", "pollMs": <int>}
    GET  /help/howto_downloads.gif               -> image/gif (the "find downloads" help clip)
    POST /add     {"url":..., "directory":...}  -> {"ok": true}
    POST /add     {"data":<base64>, "directory":...} -> {"ok": true}
      data is base64 of EITHER a magnet/HTTP link OR a .torrent file; the bridge
      auto-detects which, so the Shortcut can always base64 its input.
    POST /pause   {"hash":...}                  -> {"ok": true}   (rtorrent d.stop)
    POST /resume  {"hash":...}                  -> {"ok": true}   (rtorrent d.start)
    POST /remove  {"hash":..., "deleteFile":bool} -> {"ok": true}
    POST /settings {"lastPath":...} and/or {"pollMs":...} -> {"ok": true}
    POST /detach                                -> {"ok": true}
    POST /attach                                -> {"ok": true}

Error codes: DAEMON_UNREACHABLE, DAEMON_BUSY, DETACHED, INVALID_LINK,
NOT_A_TORRENT, BAD_REQUEST, NOT_FOUND.
(DAEMON_BUSY = connected but rtorrent didn't answer in time, i.e. alive but
pinned hash-checking; the Shortcut treats it as "wait a moment and re-run".
DETACHED = maintenance mode: rtorrent is intentionally off but the bridge still
answers /ping. NOT_A_TORRENT = an http(s) link that didn't return a .torrent —
a login page, 404, or wrong link; use a magnet or the .torrent file instead.)

No third-party packages are used — only the Python standard library — so
`apk add python3` is the only iSH-side dependency.
"""

import atexit
import base64
import json
import os
import shutil
import socket
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
from urllib.request import Request, urlopen
from xmlrpc.client import Binary, dumps, loads

# The bridge's own HTTP listener lives on iOS loopback so the Shortcut and the
# Scriptable WebView (same device) can reach it; only the local device talks to
# it, never the network.
BRIDGE_HOST = "127.0.0.1"
BRIDGE_PORT = 5001
# rtorrent now listens on a Unix domain socket instead of TCP loopback.
# AF_UNIX avoids the emulated TCP-stack overhead in iSH, which was the source
# of the "[Errno 107] Socket not connected" drops under heavy disk I/O.
RTORRENT_SOCK = "/root/gctorrent/state/rtorrent.sock"

# All app files live under ~/gctorrent/. settings.json holds user preferences
# (the save path, the dashboard poll rate, and whatever we add later); paths
# stored here are valid iSH paths (root's home, where rtorrent's download
# directories also live), not iOS Files paths.
APP_DIR = os.path.expanduser("~/gctorrent")
STATE_DIR = os.path.join(APP_DIR, "state")
SETTINGS_PATH = os.path.join(APP_DIR, "settings.json")
# Persisted command queue. The PWA sends control actions (add/pause/resume/
# remove) as commands; the bridge drains them on one background worker so a busy
# rtorrent never blocks the HTTP layer. Persisted to disk on every mutation so a
# bridge restart (work.sh relaunch) restores the in-flight chain.
QUEUE_PATH = os.path.join(APP_DIR, "queue.json")
# "How to find your downloads folder" help clip, fetched by install.sh and
# served over loopback so the Shortcut's Help menu can Quick Look it.
HELP_GIF_PATH = os.path.join(APP_DIR, "howto_downloads.gif")
# Standalone PWA page. bridge.py serves it at GET /app so it can be opened in a
# real browser (Orion/Safari) and installed via Share -> "Add to Home Screen",
# instead of only running inside the Scriptable WebView (dashboard.js). Lives
# next to bridge.py in the app dir.
APP_HTML_PATH = os.path.join(APP_DIR, "app.html")

# Dashboard poll rate bounds (milliseconds). DEFAULT is what /settings reports
# when nothing is stored yet; the clamp matches dashboard.js's own 0.1s..1h range.
DEFAULT_POLL_MS = 1000
MIN_POLL_MS = 100
MAX_POLL_MS = 3600000

# Sentinel for "maintenance mode": while this file exists, work.sh keeps the
# bridge up but does NOT start rtorrent, so iSH opens to a shell prompt (even
# across restarts) while /ping still answers. POST /detach creates it;
# POST /attach and install.sh remove it.
DETACH_FLAG = os.path.join(STATE_DIR, "detached")

# Readiness marker: written once the HTTP server has bound :5001, so work.sh can
# wait for it before launching rtorrent — which otherwise starves the bridge's
# bind for CPU in the slow iSH emulator and makes an early /ping refuse. work.sh
# clears it before spawning a fresh bridge; the bridge removes it on exit.
READY_FLAG = os.path.join(STATE_DIR, "bridge_ready")


def log(*args):
    """One timestamped line of bridge activity. work.sh redirects the bridge's
    stdout+stderr to ~/gctorrent/bridge.log, so these land there (read it in iSH
    with `cat ~/gctorrent/bridge.log` / `tail -f ~/gctorrent/bridge.log`) to trace rtorrent calls and
    surface errors — e.g. "rtorrent isn't responding" or "added but nothing
    happened"."""
    print(time.strftime("%H:%M:%S"), *args, flush=True)


def scgi_call(method, params=(), retries=1):
    """Send a single XML-RPC call over the SCGI protocol to rtorrent.

    Raises RuntimeError with one of two codes so callers can tell the states
    apart:
      * "DAEMON_UNREACHABLE" — the connect was refused (or otherwise failed),
        i.e. nothing is listening on the SCGI port: rtorrent is down or still
        coming up.
      * "DAEMON_BUSY" — we connected fine but rtorrent didn't answer within the
        timeout. Its single main loop is alive but pinned (almost always mid
        hash-check on iSH's slow CPU), so this is a transient "try again in a
        moment", not a crash. The Shortcut surfaces it as a wait-and-retry.
    """
    payload = dumps(params, methodname=method).encode("utf-8")
    headers = "CONTENT_LENGTH\x00%d\x00SCGI\x001\x00" % len(payload)
    header_block = ("%d:%s," % (len(headers), headers)).encode("utf-8")
    request = header_block + payload

    last_error = None
    for attempt in range(retries + 1):
        # AF_UNIX instead of AF_INET: no TCP stack, far more stable in iSH.
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        # iSH is slow; when rtorrent is writing big files, I/O can be
        # very laggy. 10s is safer for the slow emulated CPU.
        sock.settimeout(10)
        try:
            sock.connect(RTORRENT_SOCK)
            sock.sendall(request)
            sock.shutdown(socket.SHUT_WR)
            chunks = []
            while True:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                chunks.append(chunk)
            
            response = b"".join(chunks)
            header_end = response.find(b"\r\n\r\n")
            body = response[header_end + 4:] if header_end != -1 else response
            result, _ = loads(body)
            return result[0] if result else None

        except socket.timeout as e:
            # Connecting to loopback succeeds instantly unless nothing is listening
            # (that raises ConnectionRefused, below), so a timeout here means
            # rtorrent accepted the socket but is too busy to answer in time —
            # alive, just pinned (hash-checking). Report it distinctly so the
            # Shortcut can say "busy, wait a moment and re-run" instead of failing.
            if method != "d.multicall2":
                log("rtorrent call %s timed out: %s (busy hash-checking?)" % (method, e))
            last_error = RuntimeError("DAEMON_BUSY")
        except (ConnectionRefusedError, OSError) as e:
            # OSError covers [Errno 107] Socket not connected (observed in iSH
            # logs when rtorrent is under heavy load) and other transient drops.
            if method != "d.multicall2":
                log("rtorrent call %s failed (attempt %d/%d): %s" % (method, attempt + 1, retries + 1, e))
            last_error = RuntimeError("DAEMON_UNREACHABLE")
        finally:
            sock.close()
        
        if attempt < retries:
            time.sleep(1) # short breather before retry

    raise last_error


# --- command logic (copied verbatim from the retired rtorrent_rpc.py) --------

# status -> emoji for the ready-made `label` row. Mirrors dashboard.js's icons.
STATUS_ICONS = {
    "DOWNLOADING": "⬇️", "UPLOADING": "⬆️", "DOWNLOADING&UPLOADING": "↕️",
    "DONE": "✅", "CHECKING": "🔍", "PAUSED": "⏸️", "IDLE": "⏳", "ERROR": "⚠️",
}

# action -> emoji for queued-command tiles in the PWA. Uses the iOS media-style
# glyphs the user picked so a tile reads like a transport control: ▶️ resume
# (play), ⏸️ pause, ⏹️ remove (stop), ⤵️ add (right-arrow-curving-down).
# Mirrored in the JS (dashboard.js and the /app PWA page).
ACTION_ICONS = {
    "add": "⤵️", "resume": "▶️", "pause": "⏸️", "remove": "⏹️",
}


def get_status(short=None, full=None):
    # `short`, if given, is a shortHash prefix (first 6 hex of the info-hash).
    # `full`, if given, is a complete info-hash (used by /status?hash= to fetch a
    # single torrent's detail for the Info popup). rtorrent only knows the full
    # 40-char hash, so we filter here in the bridge.
    short = short.lower() if short else None
    full = full.lower() if full else None
    fields = (
        "d.hash=", "d.name=", "d.is_open=", "d.is_active=", "d.state=",
        "d.hashing=", "d.complete=", "d.down.rate=", "d.up.rate=", "d.message=",
        "d.bytes_done=", "d.size_bytes=",
        # Extra detail for the PWA's "Info" popup (and the size shown in each row).
        "d.directory=", "d.ratio=", "d.peers_connected=", "d.peers_complete=",
        "d.up.total=",
    )
    rows = scgi_call("d.multicall2", ("", "main") + fields)
    torrents = []
    for row in rows or []:
        (h, name, is_open, is_active, state, hashing, complete, down_rate,
         up_rate, message, done, size, directory, ratio, peers_connected,
         peers_complete, up_total) = row
        if short and h[:6].lower() != short:
            continue
        if full and h.lower() != full:
            continue
        downloading = int(down_rate) > 0
        uploading = int(up_rate) > 0

        if int(hashing):
            # rtorrent is verifying pieces (d.hashing != 0), e.g. after adding a
            # torrent over existing data or a manual recheck. Reported before the
            # paused/rate branches so it doesn't look IDLE while it's busy — no
            # network transfer happens during a check, so rates are 0.
            status = "CHECKING"
        elif not int(state) or not int(is_active):
            # Stopped (d.stop -> state 0) or paused (is_active 0). Checked before
            # the rate branches so a just-paused torrent reports PAUSED at once,
            # instead of lingering as DOWNLOADING while rtorrent's rolling rate
            # decays to 0.
            status = "PAUSED"
        elif int(complete):
            # Complete → nothing left to fetch. rtorrent's d.down.rate is a
            # rolling average that keeps decaying for a few seconds after the
            # final piece, so a just-finished torrent would otherwise still report
            # a phantom download rate and land in the DOWNLOADING branch below.
            # Checked before the rate branches: UPLOADING while it's actively
            # seeding, otherwise DONE (the stale down rate is zeroed further down).
            status = "UPLOADING" if uploading else "DONE"
        elif downloading and uploading:
            status = "DOWNLOADING&UPLOADING"
        elif downloading:
            status = "DOWNLOADING"
        elif uploading:
            status = "UPLOADING"
        elif message:
            # d.message is mostly a sticky *tracker* note ("unable to connect to
            # UDP tracker" and the like) that rtorrent leaves on the torrent and
            # never clears on its own — it's non-fatal and coexists with a healthy
            # download (DHT/PEX/other trackers). So only report ERROR when the
            # torrent is otherwise idle: stalled, with a message explaining why.
            # The message stays on the torrent object regardless, so the UI can
            # still surface it as a warning while downloading.
            status = "ERROR"
        else:
            status = "IDLE"

        percent = round(100 * int(done) / int(size), 1) if int(size) else 0
        # A paused torrent isn't transferring, and a complete torrent has nothing
        # left to download — but rtorrent keeps returning the last d.down.rate/
        # d.up.rate (a rolling average that decays for seconds after d.stop or the
        # final piece), which would otherwise freeze a stale speed on the
        # dashboard. Report 0 down for a paused or complete torrent, and 0 up for
        # a paused one.
        rep_down = 0 if (int(complete) or status == "PAUSED") else int(down_rate)
        rep_up = 0 if status == "PAUSED" else int(up_rate)
        short_hash = h[:6].lower()
        # Ready-made menu row so the Shortcut can list torrents without building
        # the string itself: "<icon> (<percent>%) <name> (#<shortHash>)". The
        # trailing (#<shortHash>) is what the Shortcut regex reads back on tap.
        label = "%s (%g%%) %s (#%s)" % (
            STATUS_ICONS.get(status, "•"), percent, name, short_hash,
        )

        torrents.append({
            "hash": h,
            "shortHash": short_hash,
            "name": name,
            "status": status,
            "message": message,
            "downRate": rep_down,
            "upRate": rep_up,
            "percent": percent,
            "label": label,
            # Extra fields for the PWA "Info" popup and the size shown per row.
            "sizeBytes": int(size),
            "bytesDone": int(done),
            "uploaded": int(up_total),
            # d.ratio is in per-mille (1000 == 1.0); expose it as a float ratio.
            "ratio": round(int(ratio) / 1000.0, 3),
            "peers": int(peers_connected),
            "seeds": int(peers_complete),
            "directory": directory,
        })
    return torrents


# Cap the metafile we'll pull from an http(s) link; matches the rtorrent
# network.xmlrpc.size_limit so load.raw_start can't be handed something bigger.
MAX_TORRENT_BYTES = 8 * 1024 * 1024
FETCH_TIMEOUT = 10  # seconds; a dead/slow link fails fast off the UI path


def looks_like_torrent(raw):
    """A .torrent is a bencoded dict: starts 'd', and always carries the info
    dict, encoded literally as b'4:info'. An HTML login page / error body starts
    with '<' and has no such key, so this reliably tells the two apart without
    trusting Content-Type."""
    stripped = raw.lstrip()
    return stripped[:1] == b"d" and b"4:info" in stripped


def fetch_torrent(url):
    """Download an http(s) link ourselves and return its bytes only if they are
    actually a .torrent. Raises RuntimeError("NOT_A_TORRENT") on any fetch
    failure OR non-torrent body (e.g. a tracker login page like rutracker's
    dl.php). Doing the fetch here — instead of letting rtorrent load.start it
    asynchronously — is what lets us report the failure at all: load.start
    returns 0 ("queued") and then fails silently on non-torrent data."""
    req = Request(url, headers={"User-Agent": "Mozilla/5.0 gctorrent"})
    try:
        with urlopen(req, timeout=FETCH_TIMEOUT) as resp:
            data = resp.read(MAX_TORRENT_BYTES + 1)
    except Exception as e:  # noqa: BLE001 - URLError/HTTPError/timeout/TLS/etc.
        log("add: fetch failed for %r: %s" % (url[:100], e))
        raise RuntimeError("NOT_A_TORRENT")
    if len(data) > MAX_TORRENT_BYTES:
        log("add: %r exceeds %d bytes — refusing" % (url[:100], MAX_TORRENT_BYTES))
        raise RuntimeError("NOT_A_TORRENT")
    if not looks_like_torrent(data):
        log("add: %r did not return a .torrent (%d bytes)" % (url[:100], len(data)))
        raise RuntimeError("NOT_A_TORRENT")
    return data


# Where the Shortcut's paths are rooted. Its prompt is "Save to folder (related
# to iSH/root/)", so the folder the user types is relative to HOME (/root) and
# already includes "downloads" when they want it there. Anchoring a relative path
# under /root/downloads instead would double it -> /root/downloads/downloads/...
HOME_DIR = "/root"
# Fallback when the folder is left blank: the conventional downloads directory,
# which is also rtorrent's directory.default.set.
DEFAULT_DIR = "/root/downloads"


def resolve_directory(directory):
    """Normalise the Shortcut's destination into ONE absolute path, used both to
    create the folder and to tell rtorrent where to save — so the two can never
    resolve to different places. The Shortcut asks for a folder "related to
    iSH/root/", i.e. relative to HOME, so a bare/relative path is anchored under
    /root (NOT under /root/downloads — the typed path already carries its own
    "downloads" prefix); ~ is expanded; a blank path falls back to the default
    downloads dir.

    Anchoring to an absolute path also matters across restarts: rtorrent stores
    d.directory in its session file verbatim and, on the next launch, resolves a
    relative or ~ path against its own current working directory — which iSH does
    not pin (work.sh starts rtorrent with no cd). If that resolves anywhere other
    than where the data was actually written, the recheck finds no chunks and the
    torrent comes back as "Download registered as completed, but hash check
    returned unfinished chunks." An absolute path removes the ambiguity."""
    d = os.path.expanduser((directory or "").strip())
    if not d:
        return DEFAULT_DIR
    if not os.path.isabs(d):
        d = os.path.join(HOME_DIR, d)
    return os.path.normpath(d)


# --- magnet directory reconciliation (rtorrent bug rakshasa/rtorrent#376) -----
#
# A magnet loaded with d.directory.set keeps that directory only on its temporary
# <hash>.meta download. Once the metadata resolves, rtorrent reloads the torrent
# from the fetched .torrent and drops d.directory back to directory.default — so
# the folder the user picked is created but stays empty while the data lands in
# /root/downloads. (.torrent-file adds don't hit this; their directory sticks.)
#
# We remember each magnet's intended directory by info-hash and a background
# thread re-applies it (stop -> d.directory.set -> start) the moment the magnet
# resolves. In-memory only: a bridge restart mid-resolution forgets the intent
# (rare — the user can re-add).
RECONCILE_INTERVAL = 2      # seconds between reconcile passes
RECONCILE_MAX_TRIES = 5     # stop re-trying a stubborn one after this many passes
_pending_lock = threading.Lock()
_pending_magnets = {}       # info-hash (40-hex upper) -> {"dir": <abs>, "tries": int}


def magnet_infohash(url):
    """The BitTorrent info-hash from a magnet's xt=urn:btih:<hash>, as uppercase
    40-char hex (rtorrent's d.hash form), or None if absent/unparseable. Accepts
    both the 40-char hex and 32-char base32 encodings."""
    for xt in parse_qs(urlparse(url).query).get("xt", []):
        prefix = "urn:btih:"
        if not xt.startswith(prefix):
            continue
        h = xt[len(prefix):].strip()
        if len(h) == 40:
            try:
                int(h, 16)
                return h.upper()
            except ValueError:
                return None
        if len(h) == 32:
            try:
                return base64.b32decode(h.upper()).hex().upper()
            except (ValueError, TypeError):
                return None
    return None


def track_magnet(url, directory):
    """Remember a just-added magnet's intended (already absolute) directory so the
    reconciler can restore it after rtorrent reverts it on metadata resolution."""
    ih = magnet_infohash(url)
    if not ih:
        return
    with _pending_lock:
        _pending_magnets[ih] = {"dir": directory, "tries": 0}
    log("add: tracking magnet %s -> %s for directory reconcile" % (ih, directory))


def reconcile_pending_magnets():
    """One reconcile pass: for each tracked magnet, once rtorrent has resolved the
    metadata re-apply the user's directory if rtorrent reverted it, then stop
    tracking it. Best-effort — rtorrent being down/busy is ignored and retried
    next pass.

    "Resolved" is detected by name, not size: while a magnet is still fetching its
    metadata rtorrent lists it as the placeholder "<HASH>.meta" (and reports a
    dummy d.size_bytes of 1, so size is no signal). The directory revert we're
    fixing only happens when that placeholder is replaced by the real torrent, so
    we must keep tracking until the ".meta" name is gone."""
    with _pending_lock:
        pending = list(_pending_magnets.items())  # inner dicts are shared refs
    if not pending:
        return
    try:
        rows = scgi_call("d.multicall2",
                         ("", "main", "d.hash=", "d.name=", "d.directory="))
    except RuntimeError:
        return  # rtorrent down/busy — try again next pass
    current = {r[0].upper(): (r[1], r[2]) for r in (rows or [])}
    done = []
    for ih, info in pending:
        if ih not in current:
            done.append(ih)                       # removed before it resolved
            continue
        name, cur_dir = current[ih]
        if name.lower().endswith(".meta"):
            continue                              # metadata not resolved yet
        want = info["dir"]
        if os.path.normpath(cur_dir) == os.path.normpath(want):
            done.append(ih)                       # already correct — nothing to do
            continue
        try:
            scgi_call("d.stop", (ih,))
            scgi_call("d.directory.set", (ih, want))
            scgi_call("d.start", (ih,))
            log("reconcile: moved magnet %s to %s (was %s)" % (ih, want, cur_dir))
            done.append(ih)
        except RuntimeError:
            info["tries"] += 1                    # mutates the shared registry dict
            if info["tries"] >= RECONCILE_MAX_TRIES:
                log("reconcile: giving up on magnet %s after %d tries"
                    % (ih, info["tries"]))
                done.append(ih)
    with _pending_lock:
        for ih in done:
            _pending_magnets.pop(ih, None)


def reconcile_loop():
    while True:
        time.sleep(RECONCILE_INTERVAL)
        try:
            reconcile_pending_magnets()
        except Exception as e:  # noqa: BLE001 - never let the reconciler thread die
            log("reconcile loop error: %s" % e)


def do_add(url, directory):
    """Validate + load a magnet/.torrent link into rtorrent. Raises
    RuntimeError("INVALID_LINK") (not a magnet/http link),
    RuntimeError("NOT_A_TORRENT") (http link that isn't a .torrent) or
    RuntimeError("DAEMON_UNREACHABLE")."""
    url = (url or "").strip()
    directory = resolve_directory(directory)
    is_magnet = url.startswith("magnet:")
    is_torrent_url = url.startswith("http://") or url.startswith("https://")
    if not (is_magnet or is_torrent_url):
        log("add rejected (not a magnet/http link): %r" % url[:100])
        raise RuntimeError("INVALID_LINK")

    os.makedirs(os.path.expanduser(directory), exist_ok=True)

    if is_torrent_url:
        # Fetch + verify here so a login page / 404 / wrong link returns a clear
        # NOT_A_TORRENT, and hand rtorrent the bytes directly (load.raw_start) so
        # it never re-fetches and can't swallow non-torrent data silently.
        raw = fetch_torrent(url)
        log("add: loading %d-byte .torrent from %r into %s"
            % (len(raw), url[:100], directory))
        result = scgi_call(
            "load.raw_start",
            ("", Binary(raw), f'd.directory.set="{directory}"'),
        )
        log("add: rtorrent load.raw_start returned %r" % (result,))
        return

    # Magnet: no metafile to fetch (the info-hash is inline), so hand it straight
    # to load.start. It still has to pull metadata from peers before it shows up
    # in /status, so "added" is not the same as "downloading".
    log("add: loading magnet %r into %s" % (url[:100], directory))
    result = scgi_call(
        "load.start",
        ("", url, f'd.directory.set="{directory}"'),
    )
    log("add: rtorrent load.start returned %r" % (result,))
    # rtorrent drops d.directory when the magnet's metadata resolves (bug #376),
    # so remember the intended folder for the reconciler to restore.
    track_magnet(url, directory)


def do_add_raw(data_b64, directory):
    """Add whatever the Shortcut base64-encoded, auto-detecting the kind: a
    magnet/HTTP link (base64 of the text) OR a .torrent file (base64 of its
    bytes). This lets the Shortcut always base64 its input and POST it as `data`,
    with no magnet-vs-file branch of its own. Non-base64 chars (e.g. line breaks
    Shortcuts may add) are dropped by b64decode's default mode. Raises
    RuntimeError("INVALID_LINK") if it's neither a link nor a bencoded .torrent."""
    directory = resolve_directory(directory)
    try:
        raw = base64.b64decode(data_b64 or "")
    except (ValueError, TypeError):
        log("add rejected (undecodable base64 data)")
        raise RuntimeError("INVALID_LINK")

    # A magnet/HTTP link decodes back to that text — hand it to do_add, which
    # validates it and calls load.start.
    stripped = raw.lstrip()
    low = stripped[:8].lower()
    if low.startswith(b"magnet:") or low.startswith(b"http"):
        do_add(stripped.decode("utf-8", "replace").strip(), directory)
        return

    # Otherwise it must be a bencoded .torrent (a dict: starts 'd', ends 'e').
    if raw[:1] == b"d" and raw[-1:] == b"e":
        os.makedirs(os.path.expanduser(directory), exist_ok=True)
        log("add: loading %d-byte .torrent file into %s" % (len(raw), directory))
        result = scgi_call(
            "load.raw_start",
            ("", Binary(raw), f'd.directory.set="{directory}"'),
        )
        log("add: rtorrent load.raw_start returned %r" % (result,))
        return

    log("add rejected (not a link or .torrent: %d bytes)" % len(raw))
    raise RuntimeError("INVALID_LINK")


def do_detach():
    """Put the backend into 'maintenance mode' and stop rtorrent, so the Shortcut
    can free the iSH terminal *before* opening it for a reinstall — the user
    pastes the reinstall command once, at a real shell prompt, instead of
    quitting rtorrent by hand (Ctrl-Q).

    Writes the ~/.detached sentinel that work.sh checks, so rtorrent stays stopped
    across iSH restarts (the bridge itself keeps running, so /ping still answers
    and reports error=DETACHED). do_attach / a reinstall removes the sentinel to
    resume. Then SIGTERM rtorrent (clean session save); -x matches the exact
    process name, like the autostart guard does.

    Always succeeds from the caller's side: a missing pkill or an already-stopped
    rtorrent still leaves us detached."""
    try:
        open(DETACH_FLAG, "w").close()
    except OSError:
        pass
    try:
        subprocess.run(["pkill", "-TERM", "-x", "rtorrent"], timeout=5, check=False)
    except Exception:  # noqa: BLE001 - pkill missing/odd env: still report ok
        pass


def do_attach():
    """Leave maintenance mode: remove the ~/.detached sentinel so the next iSH
    launch (autostart) starts rtorrent again. The bridge can't spawn rtorrent
    itself — rtorrent needs the foreground TTY — so it resumes on the next open,
    not instantly."""
    try:
        os.remove(DETACH_FLAG)
    except OSError:
        pass


def do_pause(h):
    # Hard stop (d.stop), not a soft pause (d.pause). d.stop sets d.state=0, which
    # IS saved in the session — so a paused torrent stays paused across an rtorrent
    # restart (iSH relaunch). A soft d.pause is only a runtime flag, so the torrent
    # would silently auto-resume on the next launch, which isn't what "pause"
    # should mean. get_status reports PAUSED from state/is_active either way.
    # (The resume problems that once argued for soft pause turned out to be the
    # restart re-hash and the no-peers/dead-tracker stall — not d.stop/d.start.)
    log("pause (stop): %s" % h)
    scgi_call("d.stop", (h,))
    # Checkpoint the session now that this torrent is quiescent: it's stopped and
    # not being written, so the saved fast-resume data still matches on disk and
    # rtorrent skips the hash check on the next launch. Non-fatal — a failed
    # checkpoint must not fail the pause itself.
    try:
        scgi_call("session.save")
    except RuntimeError as e:
        log("pause: session.save failed (non-fatal): %s" % e)


def do_resume(h):
    # d.start restarts the stopped torrent from where it left off (the download
    # stayed open, so no hash re-check). But d.start only queues a "started"
    # announce for the next *scheduled* slot, so a resumed torrent can sit with no
    # peers for minutes — which is exactly why fully restarting rtorrent (a fresh
    # announce) "un-sticks" it.
    #
    # We automate the "restart rtorrent" dance here: start the torrent, save the
    # session so the "started" state persists, then kill rtorrent. work.sh will
    # immediately respawn it, giving it the fresh start it needs to find peers.
    log("resume (start + restart): %s" % h)
    try:
        scgi_call("d.start", (h,))
        scgi_call("session.save")
    except RuntimeError as e:
        log("resume: d.start/session.save failed: %s" % e)
        raise

    # Kill rtorrent. work.sh handles the auto-restart loop.
    try:
        subprocess.run(["pkill", "-TERM", "-x", "rtorrent"], timeout=5, check=False)
    except Exception as e:
        log("resume: pkill failed: %s" % e)


def as_bool(v):
    """Coerce a JSON value to bool, treating the *strings* "false"/"0"/"no"/""
    as False. iOS Shortcuts sends JSON boolean fields as text ("true"/"false"),
    and Python's bool("false") is True — so a naive bool() would delete data on
    a "Keep data" request. This makes the flag correct for text or real bools."""
    if isinstance(v, str):
        return v.strip().lower() in ("1", "true", "yes", "on")
    return bool(v)


def do_remove(h, delete_file):
    """Stop + erase a torrent, optionally deleting its data. Copied from
    rtorrent_rpc.py's cmd_remove."""
    log("remove: %s (deleteFile=%s)" % (h, delete_file))
    directory = scgi_call("d.directory", (h,))
    scgi_call("d.stop", (h,))
    scgi_call("d.close", (h,))
    scgi_call("d.erase", (h,))
    if delete_file and directory and os.path.exists(directory):
        if os.path.isdir(directory):
            shutil.rmtree(directory, ignore_errors=True)
        else:
            os.remove(directory)


def read_settings():
    try:
        with open(SETTINGS_PATH) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def write_settings(settings):
    os.makedirs(APP_DIR, exist_ok=True)
    with open(SETTINGS_PATH, "w") as f:
        json.dump(settings, f)


def clamp_poll_ms(value):
    """Coerce a poll-rate value (number or numeric string) to an int clamped to
    [MIN_POLL_MS, MAX_POLL_MS]. Returns None if it isn't a usable number, so the
    caller can leave the stored value untouched."""
    try:
        ms = int(float(value))
    except (TypeError, ValueError):
        return None
    return max(MIN_POLL_MS, min(MAX_POLL_MS, ms))


# --- command queue -----------------------------------------------------------
#
# The PWA never calls rtorrent directly. It POSTs a *command* (add/pause/resume/
# remove), which is appended to a persisted queue and returned instantly. One
# background worker drains the queue serially — rtorrent has a single main loop
# and iSH is slow, so parallel calls would only contend. While rtorrent answers,
# the bridge is ONLINE; the moment a call fails with DAEMON_BUSY or
# DAEMON_UNREACHABLE the bridge flips to a DEGRADED state, keeps the command at
# the head of the queue and retries it until rtorrent recovers, and new commands
# simply pile up behind it. /status carries the whole chain so the UI can render
# it. Every mutation is written to QUEUE_PATH so a bridge restart restores it.

# rtorrent connectivity, as seen by the queue worker / status poll:
#   "ONLINE"               — last call answered.
#   "DAEMON_BUSY"          — connected but pinned (hash-checking); self-heals.
#   "DAEMON_UNREACHABLE"   — nothing listening (rtorrent down/restarting).
_rtorrent_state = "ONLINE"

_cmd_lock = threading.RLock()
_commands = []                 # ordered list of command dicts (the chain)
_worker_wake = threading.Event()  # pinged on enqueue so the worker doesn't idle-sleep

CMD_RETRY_DELAY = 2            # seconds to wait before re-trying a degraded head


def _persist_queue():
    """Write the current chain to disk. Caller must hold _cmd_lock. Best-effort:
    a failed write must not break command handling."""
    try:
        with open(QUEUE_PATH, "w") as f:
            json.dump(_commands, f)
    except OSError as e:
        log("queue persist failed: %s" % e)


def load_queue():
    """Restore the chain saved before the last exit. A command caught mid-run
    when the bridge died is reset to 'queued' so the worker re-runs it."""
    global _commands
    try:
        with open(QUEUE_PATH) as f:
            data = json.load(f)
    except (OSError, ValueError):
        data = []
    if not isinstance(data, list):
        data = []
    for c in data:
        if c.get("state") == "running":
            c["state"] = "queued"
    with _cmd_lock:
        _commands = data
    if data:
        log("queue restored: %d command(s)" % len(data))


def enqueue_command(action, hash=None, args=None, cmd_id=None):
    """Append a command to the chain and wake the worker. Returns its id. A
    client-supplied id is honoured (lets the UI reference the tile it drew and
    de-dupe rapid double-taps); otherwise one is generated."""
    cmd = {
        "id": cmd_id or uuid.uuid4().hex,
        "action": action,
        "hash": hash,
        "args": args or {},
        "ts": time.time(),
        "state": "queued",
        "error": "",
    }
    with _cmd_lock:
        _commands.append(cmd)
        _persist_queue()
    _worker_wake.set()
    return cmd["id"]


def cancel_command(cmd_id):
    """Remove a command from the chain (the bin / drag&drop). A command that is
    currently 'running' can't be pulled out from under the worker, so report
    failure and leave it. Returns True if removed."""
    with _cmd_lock:
        for c in _commands:
            if c["id"] == cmd_id:
                _commands.remove(c)
                _persist_queue()
                log("command cancelled: %s (%s)" % (cmd_id, c["action"]))
                return True
    return False


def queue_public():
    """The chain as the PWA needs it: action icon, short hash badge and live
    state. Kept compact so it rides along in every /status poll."""
    with _cmd_lock:
        out = []
        for c in _commands:
            h = c.get("hash") or ""
            out.append({
                "id": c["id"],
                "action": c["action"],
                "icon": ACTION_ICONS.get(c["action"], "•"),
                "shortHash": h[:6].lower() if h else "",
                "state": c["state"],
                "error": c.get("error", ""),
                "ts": c["ts"],
            })
        return out


def _set_rtorrent_state(state):
    global _rtorrent_state
    with _cmd_lock:
        _rtorrent_state = state


def _mark(cmd, state, error=""):
    with _cmd_lock:
        cmd["state"] = state
        cmd["error"] = error
        _persist_queue()


def _next_queued():
    """The head command still waiting to run, or None."""
    with _cmd_lock:
        for c in _commands:
            if c["state"] == "queued":
                return c
    return None


def execute_command(cmd):
    """Run one command against rtorrent using the existing do_* helpers, so the
    rtorrent logic lives in exactly one place. Raises RuntimeError with the same
    codes scgi_call / the do_* helpers already use."""
    action = cmd["action"]
    args = cmd.get("args") or {}
    if action == "add":
        if args.get("data"):
            do_add_raw(args.get("data"), args.get("directory"))
        else:
            do_add(args.get("url"), args.get("directory"))
    elif action == "pause":
        do_pause(cmd["hash"])
    elif action == "resume":
        do_resume(cmd["hash"])
    elif action == "remove":
        do_remove(cmd["hash"], as_bool(args.get("deleteFile", False)))
    else:
        raise RuntimeError("BAD_REQUEST")


def _drain_done():
    """Drop commands that finished successfully. Called after each success so the
    chain redraws 'minus one from the front' on the next poll. Failed commands
    stay (surfaced red) until the user bins them."""
    with _cmd_lock:
        before = len(_commands)
        _commands[:] = [c for c in _commands if c["state"] != "done"]
        if len(_commands) != before:
            _persist_queue()


def worker_loop():
    """Serial drain of the command chain. One command at a time; a transient
    rtorrent failure (busy/unreachable) flips the bridge DEGRADED and retries the
    same head after a short delay, so later commands wait behind it."""
    while True:
        cmd = _next_queued()
        if cmd is None:
            _worker_wake.wait(1)
            _worker_wake.clear()
            continue
        _mark(cmd, "running")
        try:
            execute_command(cmd)
            _mark(cmd, "done")
            _set_rtorrent_state("ONLINE")
            _drain_done()
        except RuntimeError as e:
            code = str(e)
            if code in ("DAEMON_BUSY", "DAEMON_UNREACHABLE"):
                # Transient: keep the command queued at the head and retry it
                # once rtorrent answers again. New commands pile up behind it.
                _set_rtorrent_state(code)
                _mark(cmd, "queued")
                time.sleep(CMD_RETRY_DELAY)
            else:
                # Permanent (INVALID_LINK, NOT_A_TORRENT, BAD_REQUEST, ...):
                # surface it as a failed tile instead of retrying forever.
                _mark(cmd, "failed", error=code)
                log("command %s (%s) failed: %s" % (cmd["id"], cmd["action"], code))
        except Exception as e:  # noqa: BLE001 - never let the worker thread die
            _mark(cmd, "failed", error=str(e))
            log("command %s (%s) crashed: %s" % (cmd["id"], cmd["action"], e))


# --- HTTP layer --------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # keep iSH's console quiet

    def _send_json(self, obj, status=200):
        # Compact separators (no space after ':' or ',') so the iOS Shortcut's
        # locale-proof `Contains "key":value` text checks match the raw body.
        # Every endpoint replies through here, so this covers all APIs/fields.
        try:
            body = json.dumps(obj, separators=(",", ":")).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            # CORS header so the Scriptable WebView (loaded via loadHTML, treated
            # as a different origin) is allowed to fetch() these endpoints.
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _send_file(self, path, content_type):
        """Stream a static file (e.g. the help GIF) with the given MIME type.
        Falls back to a JSON 404 if the file is missing — the help clip is
        optional (install.sh may have failed to fetch it)."""
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError:
            self._send_json({"ok": False, "error": "NOT_FOUND"}, status=404)
            return
        try:
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _read_body(self):
        """Parse the JSON request body. Raises ValueError on malformed input."""
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return {}
        return json.loads(raw.decode("utf-8"))

    def do_GET(self):
        try:
            parsed = urlparse(self.path)
            path = parsed.path
            if path == "/ping":
                # All "not fully running" states report through the single error
                # field so the Shortcut switches on one value:
                #   DETACHED           -> maintenance mode (rtorrent off on
                #                         purpose); the bridge still answers.
                #   DAEMON_BUSY        -> rtorrent alive but pinned (hash-check);
                #                         wait a moment and re-run.
                #   DAEMON_UNREACHABLE -> rtorrent down/crashed; start it.
                # Detach means rtorrent is intentionally down, so skip the
                # (doomed, 5s) scgi_call and report it straight away.
                if os.path.exists(DETACH_FLAG):
                    self._send_json({"ok": False, "error": "DETACHED"})
                else:
                    try:
                        scgi_call("system.pid")
                        self._send_json({"ok": True})
                    except RuntimeError as e:
                        self._send_json({"ok": False, "error": str(e)})
            elif path == "/status":
                qs = parse_qs(parsed.query)
                short = qs.get("short", [None])[0]
                full = qs.get("hash", [None])[0]
                # The status poll also serves as a heartbeat: a successful
                # d.multicall2 means rtorrent answered, so clear a stale DEGRADED
                # state even when the queue is idle (nothing for the worker to
                # retry). A failure is surfaced through the normal error path.
                try:
                    torrents = get_status(short, full)
                except RuntimeError as e:
                    code = str(e)
                    if code in ("DAEMON_BUSY", "DAEMON_UNREACHABLE"):
                        # rtorrent is degraded — but this is *exactly* when the
                        # PWA needs to render the queued-command chain. Still
                        # carry queue + rtorrentState so the degraded banner and
                        # tiles can draw; just flag ok:false + the error code.
                        _set_rtorrent_state(code)
                        self._send_json({
                            "ok": False,
                            "error": code,
                            "rtorrentState": _rtorrent_state,
                            "queue": queue_public(),
                        })
                        return
                    raise
                _set_rtorrent_state("ONLINE")
                self._send_json({
                    "ok": True,
                    "torrents": torrents,
                    "rtorrentState": _rtorrent_state,
                    "queue": queue_public(),
                })
            elif path == "/settings":
                settings = read_settings()
                self._send_json({
                    "ok": True,
                    "lastPath": settings.get("lastPath", ""),
                    "pollMs": settings.get("pollMs", DEFAULT_POLL_MS),
                })
            elif path == "/help/howto_downloads.gif":
                # Static help clip for the Shortcut's Help menu (Quick Look).
                # Route mirrors the on-disk filename (HELP_GIF_PATH).
                self._send_file(HELP_GIF_PATH, "image/gif")
            elif path == "/" or path == "/app":
                # The standalone "Torrent Saver" PWA. Open http://127.0.0.1:5001/app
                # in Orion/Safari, then Share -> "Add to Home Screen" to install
                # it. Everything it fetches (/status, /command, ...) is same-origin,
                # so no CORS dance and no host injection like the WebView needs.
                self._send_file(APP_HTML_PATH, "text/html; charset=utf-8")
            elif path == "/manifest.json":
                # Web app manifest so the browser offers a standalone install with
                # its own name/colour instead of a plain bookmark. Kept inline (no
                # extra file to ship); icons are left to the apple-touch fallback.
                self._send_json({
                    "name": "Torrent Saver",
                    "short_name": "Torrent Saver",
                    "start_url": "/app",
                    "scope": "/",
                    "display": "standalone",
                    "orientation": "portrait",
                    "background_color": "#0d1117",
                    "theme_color": "#0d1117",
                })
            else:
                self._send_json({"ok": False, "error": "NOT_FOUND"}, status=404)
        except RuntimeError as e:
            self._send_json({"ok": False, "error": str(e)})
        except Exception as e:  # noqa: BLE001 - surface anything else as JSON
            log("GET %s crashed: %s" % (self.path, e))
            self._send_json({"ok": False, "error": str(e)})

    def do_POST(self):
        log("POST", self.path)
        try:
            try:
                data = self._read_body()
            except ValueError:
                self._send_json({"ok": False, "error": "BAD_REQUEST"}, status=400)
                return

            if self.path == "/add":
                url = data.get("url")
                raw_data = data.get("data")
                directory = data.get("directory")
                if not directory or not (url or raw_data):
                    self._send_json({"ok": False, "error": "BAD_REQUEST"}, status=400)
                    return
                if raw_data:
                    do_add_raw(raw_data, directory)
                else:
                    do_add(url, directory)
                self._send_json({"ok": True})
            elif self.path == "/pause":
                h = data.get("hash")
                if not h:
                    self._send_json({"ok": False, "error": "BAD_REQUEST"}, status=400)
                    return
                do_pause(h)
                self._send_json({"ok": True})
            elif self.path == "/resume":
                h = data.get("hash")
                if not h:
                    self._send_json({"ok": False, "error": "BAD_REQUEST"}, status=400)
                    return
                do_resume(h)
                self._send_json({"ok": True})
            elif self.path == "/remove":
                h = data.get("hash")
                if not h:
                    self._send_json({"ok": False, "error": "BAD_REQUEST"}, status=400)
                    return
                do_remove(h, as_bool(data.get("deleteFile", False)))
                self._send_json({"ok": True})
            elif self.path == "/settings":
                # Partial update: only the keys present in the body change, so
                # saving the path doesn't clobber the poll rate and vice versa.
                settings = read_settings()
                if "lastPath" in data:
                    settings["lastPath"] = data["lastPath"]
                if "pollMs" in data:
                    ms = clamp_poll_ms(data["pollMs"])
                    if ms is not None:
                        settings["pollMs"] = ms
                write_settings(settings)
                self._send_json({"ok": True})
            elif self.path == "/command":
                # PWA control path: enqueue a command and return instantly. The
                # background worker runs it against rtorrent so a busy daemon
                # never blocks this response.
                action = data.get("action")
                if action not in ACTION_ICONS:
                    self._send_json({"ok": False, "error": "BAD_REQUEST"}, status=400)
                    return
                h = data.get("hash")
                # add carries {url|data, directory} in args; the torrent actions
                # need a hash. Reject early so a bad tap doesn't sit in the queue.
                if action != "add" and not h:
                    self._send_json({"ok": False, "error": "BAD_REQUEST"}, status=400)
                    return
                cmd_id = enqueue_command(
                    action, hash=h, args=data.get("args") or {}, cmd_id=data.get("id"),
                )
                self._send_json({"ok": True, "id": cmd_id})
            elif self.path == "/command/cancel":
                # Bin / drag&drop: pull a queued command out of the chain.
                cmd_id = data.get("id")
                if not cmd_id:
                    self._send_json({"ok": False, "error": "BAD_REQUEST"}, status=400)
                    return
                removed = cancel_command(cmd_id)
                self._send_json({"ok": removed, "id": cmd_id})
            elif self.path == "/detach":
                do_detach()
                self._send_json({"ok": True})
            elif self.path == "/attach":
                do_attach()
                self._send_json({"ok": True})
            else:
                self._send_json({"ok": False, "error": "NOT_FOUND"}, status=404)
        except RuntimeError as e:
            log("POST %s -> %s" % (self.path, e))
            self._send_json({"ok": False, "error": str(e)})
        except Exception as e:  # noqa: BLE001 - surface anything else as JSON
            log("POST %s crashed: %s" % (self.path, e))
            self._send_json({"ok": False, "error": str(e)})


if __name__ == "__main__":
    # ThreadingHTTPServer (not the single-threaded HTTPServer) so a /status poll
    # stays responsive while the worker thread is blocked on a slow scgi_call.
    server = ThreadingHTTPServer((BRIDGE_HOST, BRIDGE_PORT), Handler)
    # The bind above succeeded — announce readiness so work.sh stops waiting and
    # launches rtorrent. Remove it on exit so a stale marker never outlives us.
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(READY_FLAG, "w") as f:
        f.write(str(os.getpid()))
    atexit.register(
        lambda: os.path.exists(READY_FLAG) and os.remove(READY_FLAG)
    )
    # Restore any command chain persisted before the last exit, then start the
    # single serialized worker that drains it. Daemon so it dies with us.
    load_queue()
    threading.Thread(target=worker_loop, daemon=True).start()
    log("command queue worker started")
    # Background thread that restores a magnet's chosen directory after rtorrent
    # reverts it on metadata resolution (bug #376). Daemon so it dies with us.
    threading.Thread(target=reconcile_loop, daemon=True).start()
    log("magnet directory reconciler started")
    log(f"bridge.py listening on {BRIDGE_HOST}:{BRIDGE_PORT}")
    server.serve_forever()
__GCTORRENT_BRIDGE_PY__
cat > /root/gctorrent/work.sh << '__GCTORRENT_WORK_SH__'
#!/bin/sh
# work.sh — starts the status bridge (always), and unless detached, the location
# keep-alive + rtorrent. Run instead of `rtorrent` directly. Non-interactive.

APP_DIR="/root/gctorrent"
STATE_DIR="$APP_DIR/state"
LOCATION_LOG="$STATE_DIR/location_check"
FLAG_FILE="$STATE_DIR/location_confirmed"
DETACH_FLAG="$STATE_DIR/detached"
READY_FLAG="$STATE_DIR/bridge_ready"

mkdir -p "$STATE_DIR"

# On a normal exit or a TERM, stop the location reader we started so it can't
# linger and collide with a second /dev/location reader on the next run
# (duplicate readers make iSH tear down and relaunch). INT is deliberately NOT
# trapped: ^C during the respawn wait must abort work.sh back to the shell and
# must leave the bridge + location reader running (background processes ignore
# SIGINT on their own, so a terminal ^C hits only sleep/rtorrent). The bridge is
# left up on purpose (the Shortcut still needs it); it's already pgrep-guarded.
cleanup() {
    [ -n "$LOC_PID" ] && kill "$LOC_PID" 2>/dev/null
}
trap cleanup EXIT TERM

# Remove the one-shot installer bootstrap if it's still around (install.sh execs
# us at the end of a fresh install/update). By now install.sh is a closed file,
# so this is an ordinary unlink; harmless -f no-op on normal autostart launches.
rm -f /root/install.sh

# Mark that setup has run, up front — so the autostart hook keeps launching us on
# future iSH opens even if this run aborts before location is granted.
touch "$FLAG_FILE"

# Start the status bridge FIRST and unconditionally (guarded so we never run a
# second copy). Keeping it up whenever iSH is open lets the Shortcut always reach
# 127.0.0.1:5001 — even with rtorrent down or in maintenance mode — so /ping
# answers (ok:false, error:DETACHED) instead of refusing the connection and
# hard-halting the Shortcut.
if ! pgrep -f "python3 $APP_DIR/bridge.py" >/dev/null 2>&1; then
    # Clear any stale readiness marker so the wait before rtorrent tracks THIS
    # bridge's bind, not a dead one's. Only the spawn path clears it — when the
    # bridge is already running (else branch), its marker persists so the wait
    # passes at once.
    rm -f "$READY_FLAG"
    python3 "$APP_DIR/bridge.py" > "$APP_DIR/bridge.log" 2>&1 &
    # Record the bridge PID so the installer can stop a previous-version bridge
    # by PID (deterministic) instead of matching command lines with pkill -f
    # (which kept matching the killer's own process line in busybox).
    echo $! > "$STATE_DIR/bridge.pid"
    echo "Status bridge started on 127.0.0.1:5001"
else
    echo "Status bridge already running on 127.0.0.1:5001"
fi

# Maintenance mode: bridge stays up (above), rtorrent stays down, shell is free.
# POST /attach (or a reinstall) removes the sentinel to resume on the next open.
if [ -f "$DETACH_FLAG" ]; then
    echo "Detached (maintenance mode) — rtorrent not started."
    exit 0
fi

# Location keep-alive (needed only for the live torrent session). Only start one
# reader — a second concurrent open of /dev/location makes iSH tear down and
# relaunch, so reuse an existing reader if a previous run left one behind.
if ! pgrep -f "cat /dev/location" >/dev/null 2>&1; then
    rm -f "$LOCATION_LOG"
    echo "Starting background keep-alive (location)..."
    cat /dev/location > "$LOCATION_LOG" 2>&1 &
    LOC_PID=$!
    # Record the reader PID so the installer can stop a stale reader by PID
    # instead of pattern-matching command lines.
    echo "$LOC_PID" > "$STATE_DIR/location.pid"
else
    echo "Location keep-alive already running."
fi

# Wait up to ~20s for the Location popup to be granted (data to start flowing),
# instead of a hard 3s cutoff that loses the race with the permission dialog.
i=0
while [ ! -s "$LOCATION_LOG" ] && [ "$i" -lt 20 ]; do
    sleep 1
    i=$((i + 1))
done

if [ ! -s "$LOCATION_LOG" ]; then
    echo ""
    echo "!!! Location permission is NOT working yet. !!!"
    echo "Set  Settings -> iSH -> Location -> Always, then just reopen iSH."
    echo "It will start automatically - nothing to type."
    kill "$LOC_PID" 2>/dev/null
    exit 1
fi

echo "Location feed is active (PID $LOC_PID)."

# Wait for the bridge to finish binding :5001 before rtorrent grabs the CPU. In
# the slow iSH emulator an immediate rtorrent launch starves the bridge's bind,
# so a Shortcut /ping in that window gets refused (a hard halt). bridge.py writes
# the marker the moment it's listening, so this usually passes at once — the
# location wait above already gave it a head start.
i=0
while [ ! -f "$READY_FLAG" ] && [ "$i" -lt 15 ]; do
    sleep 1
    i=$((i + 1))
done

# Start rtorrent in a loop so bridge.py can trigger a restart by killing it.
# To stop for real, use the "Detach" feature (which sets $DETACH_FLAG). Give up
# after 3 start attempts so a persistent crash doesn't loop forever. The 5s wait
# gives the user time to hit ^C to cancel the respawn — ^C is untrapped (see the
# trap above), so it aborts work.sh to the shell while the bridge + location
# reader keep running.
attempt=0
while [ ! -f "$DETACH_FLAG" ] && [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    echo "Starting rtorrent... (attempt $attempt/3)"
    rtorrent
    [ -f "$DETACH_FLAG" ] && break
    echo "restarting rtorrent in 5 sec (attempt $attempt of 3)"
    sleep 5
done

if [ "$attempt" -ge 3 ] && [ ! -f "$DETACH_FLAG" ]; then
    echo "rtorrent failed to stay up after 3 attempts — giving up on restarts."
    echo "Bridge + location keep-alive stay running; reopen iSH to retry rtorrent."
    trap - EXIT
    exit 0
fi

# rtorrent exited (crash or Ctrl-Q). Leave the bridge running so the Shortcut can
# still reach it; work.sh reuses it (the pgrep guard above) on the next launch.
__GCTORRENT_WORK_SH__

for f in bridge.py work.sh; do
    if [ ! -f "/root/gctorrent/$f" ]; then
        echo "Missing /root/gctorrent/$f after extraction - aborting."
        exit 1
    fi
done

# apk over iSH's emulated network is flaky — a single dropped index or package
# fetch returns non-zero and, under `set -e`, would abort the whole install
# (seen as "DNS lookup error" or "network error (check Internet connection...)").
# Retry transient failures a few times before giving up. apk exits 1 for every
# kind of error, so we can't tell "network blip" from "no such package" by exit
# code — but the package set below is fixed and valid, so the only realistic
# failure IS the network, and retry-on-failure never masks a real bug: a genuine
# permanent error just exhausts the attempts and fails with the same message.
apk_retry() {
    n=0
    until apk "$@"; do
        n=$((n + 1))
        if [ "$n" -ge 4 ]; then
            echo "apk $* failed after $n attempts — check the connection and re-run."
            return 1
        fi
        echo "  apk failed (attempt $n) — retrying in 3s..."
        sleep 3
    done
}

# Guarantee a working DNS resolver before any fetch. iSH fills /etc/resolv.conf
# from the network, but some networks — a PC or phone hotspot especially — hand
# it a DNS server it can't actually reach, so every lookup fails ("could not
# resolve host") and the apk/wget fetches below die before they start. Append
# Google's public resolver as a *fallback* rather than overwriting: iSH runs on
# musl libc, whose resolver queries all listed nameservers in parallel and takes
# the first reply — so a working network DNS is unaffected (it still answers
# first) while a dead hotspot resolver is transparently bypassed. Idempotent.
grep -qsF 'nameserver 8.8.8.8' /etc/resolv.conf \
  || echo "nameserver 8.8.8.8" >> /etc/resolv.conf

echo "[1/4] installing packages (python3, rtorrent)..."
# update is best-effort: if the index refresh ultimately fails but a cached
# index exists, `apk add` can still install from it. add MUST succeed, so its
# failure stays fatal (set -e aborts) — there's no app without the packages.
# Install one package at a time so each apk's peak memory is freed before the
# next starts (this is why the install was once split into separate scripts) —
# iSH is memory-tight and installing both together can OOM.
apk_retry update || true
apk_retry add python3
apk_retry add rtorrent

# Fetch the help clip served at GET /help/downloads.gif. Non-fatal.
echo "  fetching help clip (howto_downloads.gif)..."
wget -qO /root/gctorrent/howto_downloads.gif \
  https://raw.githubusercontent.com/Dimoniada/claude-apple-gcTorrent/main/howto_downloads.gif \
  || echo "  (help clip download skipped)"

# Write the PWA page served at GET /app. Embedded (not fetched) so it ships in
# lock-step with this installer's bridge.py; quoted heredoc = verbatim.
echo "  writing PWA page (app.html)..."
cat > /root/gctorrent/app.html << '__GCTORRENT_APP_HTML__'
<!DOCTYPE html>
<!-- Standalone "Torrent Saver" PWA, served by bridge.py at GET /app. Unlike
     dashboard.js (which runs inside a Scriptable WebView via loadHTML), this
     page is loaded straight from the bridge origin (http://127.0.0.1:5001/app),
     so every fetch() is same-origin — no CORS needed and no host injection.
     Open it in Orion or Safari and use Share -> "Add to Home Screen" to install
     it as a standalone app (see the manifest + apple-mobile-web-app meta tags).
     UI is kept in lock-step with dashboard.js; icons mirror bridge.py's
     STATUS_ICONS / ACTION_ICONS. -->
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<meta name="color-scheme" content="dark light">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Torrent Saver">
<meta name="theme-color" content="#0d1117">
<link rel="manifest" href="/manifest.json">
<title>Torrent Saver</title>
<style>
  :root{
    --bg:#0d1117; --panel:#161b22; --line:#30363d;
    --txt:#e6edf3; --muted:#8b949e; --accent:#2f81f7;
    --red:#f85149; --green:#3fb950; --amber:#d29922;
  }
  *{box-sizing:border-box; -webkit-user-select:none; user-select:none;
    -webkit-tap-highlight-color:transparent;}
  html,body{margin:0; height:100%; background:var(--bg); color:var(--txt);
    font:15px/1.3 -apple-system,system-ui,sans-serif;}
  #app{display:flex; flex-direction:column; height:100vh;}

  /* ---- title (fixed) ---- */
  .title{flex:0 0 auto; text-align:center;
    padding:calc(10px + env(safe-area-inset-top)) 12px 10px;
    font-weight:600; font-size:18px; border-bottom:1px solid var(--line);}

  /* ---- torrent list: 1/2 height ---- */
  .torrents{flex:0 0 50%; overflow-y:auto; padding:6px;}
  .row{display:flex; align-items:center; gap:10px; padding:10px 8px;
    border-radius:8px; cursor:pointer; border:1px solid transparent;}
  .row .ic{font-size:20px; width:28px; text-align:center; flex:0 0 auto;}
  .row .name-col{flex:1; overflow:hidden;}
  .row .name{overflow:hidden; text-overflow:ellipsis; white-space:nowrap;}
  .row .err{font-size:12px; color:var(--red); margin-top:2px;
    overflow:hidden; text-overflow:ellipsis; white-space:nowrap;}
  .row .meta{font-size:12px; color:var(--muted); margin-top:2px;}
  .row .sub{font-size:12px; color:var(--muted); margin-top:2px;}
  .row .sub .hash{font-family:ui-monospace,monospace;}
  .row.sel{background:rgba(47,129,247,.18); border-color:var(--accent);}
  .row.dragging{opacity:.4;}
  .empty{text-align:center; color:var(--muted); padding:30px 0;}

  /* ---- action buttons ---- */
  .actions{flex:0 0 auto; display:flex; gap:6px; padding:8px;
    border-top:1px solid var(--line); border-bottom:1px solid var(--line);}
  /* icon on top, wrapped title on the next line, so buttons stay uniform */
  .btn{flex:1; padding:8px 2px; border:1px solid var(--line); border-radius:10px;
    background:var(--panel); color:var(--txt); font-size:11px; cursor:pointer;
    display:flex; flex-direction:column; align-items:center; gap:2px;
    line-height:1.1; text-align:center; word-break:break-word;}
  .btn .bic{font-size:18px;}
  .btn:disabled{opacity:.35; cursor:default;}

  /* ---- degraded banner + queue: 1/4 height ---- */
  .degraded{flex:0 0 25%; display:flex; flex-direction:column;
    padding:6px 8px; overflow:hidden; border-bottom:1px solid var(--line);}
  .degraded[hidden]{display:none;}
  .banner{color:var(--amber); font-size:13px; margin-bottom:6px; flex:0 0 auto;}
  .queue{display:flex; gap:14px; overflow-x:auto; overflow-y:hidden;
    padding:6px 2px; flex:1; align-items:center;}
  .cmd{position:relative; flex:0 0 auto; width:58px; height:58px;
    border-radius:14px; background:var(--panel); border:1px solid var(--line);
    display:flex; align-items:center; justify-content:center; font-size:30px;
    cursor:grab;}
  .cmd.running{outline:2px solid var(--accent);}
  .cmd.failed{border-color:var(--red); box-shadow:0 0 0 1px var(--red);}
  .cmd.dragging{opacity:.4;}
  .cmd .badge{position:absolute; top:-6px; right:-6px;
    background:#000; color:var(--txt); font:600 10px ui-monospace,monospace;
    padding:2px 4px; border-radius:6px; border:1px solid var(--line);}

  /* ---- bottom bar ---- */
  .bar{flex:0 0 auto; display:grid; grid-template-columns:1fr auto 1fr;
    align-items:center; padding:10px 12px calc(10px + env(safe-area-inset-bottom));
    border-top:1px solid var(--line);}
  .opts{grid-column:1; justify-self:start; width:140px; text-align:center; padding:10px 16px;
    border-radius:10px; background:var(--panel); border:1px solid var(--line);
    color:var(--txt); font-weight:600; cursor:pointer;}
  .bin{grid-column:2; justify-self:center; font-size:28px; color:var(--muted);
    width:54px; height:54px; border:2px dashed var(--line); border-radius:14px;
    display:flex; align-items:center; justify-content:center;}
  .bin.armed{color:#fff; border-color:var(--red); background:rgba(248,81,73,.22);}
  .exit{grid-column:3; justify-self:end; width:140px; text-align:center; padding:10px 16px;
    border-radius:10px; background:var(--red); color:#fff; border:none;
    font-weight:600; cursor:pointer;}

  /* ---- modal popups (error info + add) ---- */
  .overlay{position:fixed; inset:0; background:rgba(0,0,0,.6);
    display:flex; align-items:center; justify-content:center; padding:20px;}
  .overlay[hidden]{display:none;}
  /* Ensure the `hidden` attribute always wins, even on elements with a class
     that sets `display` (e.g. .popup .lbl{display:block}); the UA rule
     [hidden]{display:none} loses on specificity, so force it here. */
  [hidden]{display:none!important;}
  .popup{background:var(--panel); border:1px solid var(--line); border-radius:14px;
    padding:20px; width:min(380px,92vw); text-align:center;}
  .popup h3{margin:0 0 10px;}
  .popup p{color:var(--muted); margin:0 0 16px; word-break:break-word;}
  .popup input{width:100%; margin:6px 0; padding:10px; border-radius:8px;
    border:1px solid var(--line); background:var(--bg); color:var(--txt);
    font-size:14px; -webkit-user-select:text; user-select:text;}
  .popup .lbl{display:block; text-align:left; color:var(--txt); font-size:13px;
    margin:10px 0 0;}
  .popup .prow{display:flex; gap:8px; margin-top:12px;}
  .popup button{flex:1; padding:10px 12px; border-radius:10px; border:none;
    background:var(--accent); color:#fff; font-weight:600; cursor:pointer;
    white-space:nowrap;}
  .popup button.ghost{background:var(--panel); border:1px solid var(--line);
    color:var(--txt);}
  .popup button.danger{background:var(--red);}
  .popup img{max-width:100%; border-radius:8px; margin:6px 0;}
  /* Info popup: a compact key/value table + optional red error at the top */
  .info{text-align:left; margin:0 0 8px;}
  .info .ierr{color:var(--red); font-weight:600; margin:0 0 10px;
    word-break:break-word;}
  .info .irow{display:flex; justify-content:space-between; gap:12px;
    padding:4px 0; border-bottom:1px solid var(--line); font-size:13px;}
  .info .ik{color:var(--muted); flex:0 0 auto;}
  .info .iv{text-align:right; word-break:break-word;}
  .updated{position:fixed; bottom:2px; left:0; right:0; text-align:center;
    font-size:10px; color:var(--muted); opacity:.5; pointer-events:none;}
  /* pull-to-refresh indicator above the torrent list */
  .ptr{flex:0 0 auto; text-align:center; font-size:12px; color:var(--muted);
    height:0; overflow:hidden; transition:height .15s ease; opacity:.8;}
  .ptr.show{height:22px;}
  .ptr.spin{color:var(--accent);}
</style>
</head>
<body>
<div id="app">
  <div class="title">🏴‍☠️ Torrent Saver</div>

  <div class="ptr" id="ptr">↓ Pull to refresh</div>
  <div class="torrents" id="list"><div class="empty">Loading…</div></div>

  <div class="actions">
    <button class="btn" id="bAdd"><span class="bic">⤵️</span><span>Add</span></button>
    <button class="btn" id="bResume"><span class="bic">▶️</span><span>Resume</span></button>
    <button class="btn" id="bPause"><span class="bic">⏸️</span><span>Pause</span></button>
    <button class="btn" id="bStop"><span class="bic">⏹️</span><span>Stop</span></button>
    <button class="btn" id="bErr"><span class="bic">⚠️</span><span>Info</span></button>
  </div>

  <div class="degraded" id="degraded" hidden>
    <div class="banner" id="banner"></div>
    <div class="queue" id="queue"></div>
  </div>

  <div class="bar">
    <button class="opts" id="options">Options</button>
    <div class="bin" id="bin">🗑</div>
    <button class="exit" id="exit">Exit</button>
  </div>
</div>

<!-- info popup (per-torrent details; error shown in red at the top if any) -->
<div class="overlay" id="errPop" hidden>
  <div class="popup">
    <h3>⚠️ Info</h3>
    <div class="info" id="infoBody"></div>
    <button onclick="document.getElementById('errPop').hidden=true">OK</button>
  </div>
</div>

<!-- add popup -->
<div class="overlay" id="addPop" hidden>
  <div class="popup">
    <h3>⤵️ Add Torrent</h3>
    <label class="lbl" for="addFile">By magnet/torrent URL:</label>
    <input id="addUrl" type="text" placeholder="magnet/torrent URL" autocapitalize="off" autocorrect="off">
    <label class="lbl" for="addFile">By *.torrent file:</label>
    <input id="addFile" type="file" accept=".torrent" placeholder="*.torrent file">
    <label class="lbl" id="addDirLbl" for="addDir">Download folder name:</label>
    <input id="addDir" type="text" placeholder="download folder name" autocapitalize="off" autocorrect="off">
    <div class="prow">
      <button class="ghost" onclick="document.getElementById('addPop').hidden=true">Cancel</button>
      <button onclick="submitAdd()">Add</button>
    </div>
  </div>
</div>

<!-- stop confirm popup (keep vs delete files) -->
<div class="overlay" id="stopPop" hidden>
  <div class="popup">
    <h3>⏹️ Stop Torrent</h3>
    <p id="stopMsg">Remove this torrent?</p>
    <div class="prow">
      <button class="ghost" onclick="document.getElementById('stopPop').hidden=true">Cancel</button>
      <button onclick="confirmStop(false)">Keep files</button>
      <button class="danger" onclick="confirmStop(true)">Delete files</button>
    </div>
  </div>
</div>

<!-- options popup -->
<div class="overlay" id="optPop" hidden>
  <div class="popup">
    <h3>⚙️ Options</h3>
    <label class="lbl" for="optPoll">Set control panel refresh rate (0.1-3600) sec:</label>
    <input id="optPoll" type="text" inputmode="decimal" placeholder="1.0" autocapitalize="off" autocorrect="off">
    <label class="lbl" for="optDir">Download folder name:</label>
    <input id="optDir" type="text" placeholder="(default: downloads)" autocapitalize="off" autocorrect="off">
    <div class="prow">
      <button class="ghost" onclick="openHelp()">Where to find my downloads</button>
    </div>
    <div class="prow">
      <button class="ghost" onclick="document.getElementById('optPop').hidden=true">Cancel</button>
      <button onclick="saveOptions()">Save</button>
    </div>
  </div>
</div>

<!-- help gif popup -->
<div class="overlay" id="helpPop" hidden>
  <div class="popup">
    <h3>Where to find my downloads</h3>
    <img src="/help/howto_downloads.gif" alt="How to find your downloads">
    <button onclick="document.getElementById('helpPop').hidden=true">OK</button>
  </div>
</div>

<div class="updated" id="updated"></div>

<script>
  // Served from the bridge origin, so all endpoints are same-origin (relative).
  const BRIDGE = "";
  const DEFAULT_POLL_MS = 1000;
  let POLL_MS = DEFAULT_POLL_MS;
  let timer = null;
  let running = true;

  let selectedHash = null;          // full info-hash of the selected row, or null
  let torrentsByHash = {};          // hash -> torrent, for the Info popup
  let lastPath = "";                // remembered download dir (from /settings)
  let pendingStopHash = null;       // torrent awaiting the keep/delete choice

  // Mirrors bridge.py STATUS_ICONS — what a torrent *is*.
  const ICONS = {
    "DOWNLOADING":"⬇️","UPLOADING":"⬆️","DOWNLOADING&UPLOADING":"↕️",
    "DONE":"✅","CHECKING":"🔍","PAUSED":"⏸️","IDLE":"⏳","ERROR":"⚠️"
  };

  function esc(s){
    return String(s==null?"":s).replace(/[&<>"']/g,c=>(
      {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  }
  function fmtRate(bps){
    if(!bps) return "";
    const u=["B","KB","MB","GB"]; let v=bps,i=0;
    while(v>=1024&&i<u.length-1){v/=1024;i++;}
    return (v<10&&i>0?v.toFixed(1):Math.round(v))+" "+u[i]+"/s";
  }
  // Human size: integer while under 1000 of a unit, then roll to the next unit
  // with one decimal place (e.g. 1.2 GB). Base 1000 as the user specified.
  function fmtSize(bytes){
    if(bytes==null) return "";
    const u=["B","KB","MB","GB","TB"]; let v=bytes,i=0;
    while(v>=1000&&i<u.length-1){v/=1000;i++;}
    return (i===0?Math.round(v):v.toFixed(1))+" "+u[i];
  }
  function fillColor(st){
    if(st==="DONE") return "#3fb950";
    if(st==="ERROR") return "#f85149";
    if(st==="PAUSED") return "#8b949e";
    if(st==="CHECKING") return "#d29922";
    return "#2f81f7";
  }

  // ---- selection + button enablement ----
  function refreshButtons(){
    const on = selectedHash!==null;
    ["bResume","bPause","bStop","bErr"].forEach(id=>
      document.getElementById(id).disabled=!on);
    document.getElementById("bAdd").disabled=false; // Add always active
  }
  function selectRow(hash){
    // toggle off if the same row is tapped again
    selectedHash = (selectedHash===hash) ? null : hash;
    document.querySelectorAll(".row").forEach(r=>
      r.classList.toggle("sel", r.dataset.hash===selectedHash));
    refreshButtons();
  }

  // ---- command dispatch ----
  async function sendCommand(action, extra){
    const body = Object.assign({action}, extra||{});
    try{
      const res = await fetch(BRIDGE+"/command",{
        method:"POST", headers:{"Content-Type":"application/json"},
        body:JSON.stringify(body)
      });
      await res.json();
    }catch(e){ /* bridge down — next /status poll surfaces it */ }
    refresh(); // pull the freshly-queued tile straight away
  }
  function cmdOnSelected(action){
    if(selectedHash===null) return;
    sendCommand(action,{hash:selectedHash});
  }

  // ---- add popup ----
  function openAdd(){
    document.getElementById("addUrl").value="";
    document.getElementById("addFile").value="";
    // Once a download folder is remembered (lastPath), hide the folder field and
    // reuse it; it only reappears after lastPath is cleared (via Options).
    const hasPath=!!(lastPath&&lastPath.trim());
    document.getElementById("addDir").value=lastPath||"";
    // Toggle via the `hidden` property; the global [hidden]{display:none!important}
    // rule guarantees it wins over the .lbl class's display:block.
    document.getElementById("addDir").hidden=hasPath;
    document.getElementById("addDirLbl").hidden=hasPath;
    document.getElementById("addPop").hidden=false;
  }
  function submitAdd(){
    const url=document.getElementById("addUrl").value.trim();
    // A .torrent picked from the Files app (via the native file input) is sent
    // as base64 `data`; the bridge auto-detects a .torrent vs a link, so `data`
    // covers both. A typed URL takes second place.
    const fileEl=document.getElementById("addFile");
    const file=fileEl&&fileEl.files&&fileEl.files[0];
    // Use the typed folder if the field is shown, else the remembered lastPath.
    // Both may be blank -> the bridge falls back to the default downloads dir.
    const dirEl=document.getElementById("addDir");
    const dir=(dirEl.hidden?(lastPath||""):dirEl.value.trim());
    if(!url && !file) return;
    document.getElementById("addPop").hidden=true;
    if(dir && !dirEl.hidden){
      lastPath=dir;
      fetch(BRIDGE+"/settings",{method:"POST",
        headers:{"Content-Type":"application/json"},
        body:JSON.stringify({lastPath:dir})}).catch(()=>{});
    }
    if(file){
      // `accept` can't be enforced by the iOS Files picker, so validate here:
      // reject anything not named *.torrent up front.
      const name=(file.name||"").toLowerCase();
      if(!name.endsWith(".torrent")){
        alert("Please choose a .torrent file.");
        return;
      }
      const reader=new FileReader();
      reader.onload=function(){
        const res=String(reader.result||"");
        // strip the "data:...;base64," prefix readAsDataURL adds
        const b64=res.indexOf(",")>=0?res.slice(res.indexOf(",")+1):res;
        // A real .torrent is a bencoded dict that starts with "d8:announce"
        // (or at least "d"); sniff the decoded bytes and reject impostors
        // (e.g. a photo that was force-picked despite the .torrent name).
        try{
          const head=atob(b64.slice(0,32));
          if(head.charAt(0)!=="d"){
            alert("That file is not a valid .torrent.");
            return;
          }
        }catch(e){ /* if we can't decode, let the bridge make the call */ }
        sendCommand("add",{args:{data:b64,directory:dir}});
      };
      reader.readAsDataURL(file);
    }else{
      sendCommand("add",{args:{url:url,directory:dir}});
    }
  }

  // ---- info popup (per-torrent details; error in red at the top if present) ----
  function irow(k,v){
    return '<div class="irow"><span class="ik">'+esc(k)
      +'</span><span class="iv">'+esc(v)+'</span></div>';
  }
  function showInfo(){
    if(selectedHash===null) return;
    const t=torrentsByHash[selectedHash];
    let html="";
    if(t&&t.message){
      html+='<div class="ierr">'+esc(t.message)+'</div>';
    }
    if(t){
      const done=fmtSize(t.bytesDone), total=fmtSize(t.sizeBytes);
      html+=irow("Name", t.name);
      html+=irow("Hash", "#"+t.shortHash);
      html+=irow("State", t.status);
      html+=irow("Progress", t.percent+"%  ("+done+" / "+total+")");
      html+=irow("Download", t.downRate?fmtRate(t.downRate):"—");
      html+=irow("Upload", t.upRate?fmtRate(t.upRate):"—");
      html+=irow("Uploaded", fmtSize(t.uploaded||0));
      html+=irow("Ratio", (t.ratio!=null?t.ratio:0).toFixed(2));
      html+=irow("Peers / Seeds", (t.peers||0)+" / "+(t.seeds||0));
      html+=irow("Folder", t.directory||"—");
    }else{
      html='<div class="ierr">No info available for this torrent.</div>';
    }
    document.getElementById("infoBody").innerHTML=html;
    document.getElementById("errPop").hidden=false;
  }

  // ---- stop confirm (keep vs delete files) ----
  function openStop(hash){
    if(!hash) return;
    pendingStopHash=hash;
    const t=torrentsByHash[hash];
    document.getElementById("stopMsg").textContent=
      "Remove \""+(t?t.name:("#"+hash.slice(0,6)))+"\"?";
    document.getElementById("stopPop").hidden=false;
  }
  function confirmStop(deleteFile){
    document.getElementById("stopPop").hidden=true;
    if(!pendingStopHash) return;
    sendCommand("remove",{hash:pendingStopHash,args:{deleteFile:deleteFile}});
    pendingStopHash=null;
  }

  // ---- options popup ----
  function openOptions(){
    document.getElementById("optPoll").value=(POLL_MS/1000).toFixed(1);
    document.getElementById("optDir").value=lastPath||"";
    document.getElementById("optPop").hidden=false;
  }
  function saveOptions(){
    const secStr=document.getElementById("optPoll").value.trim();
    const dir=document.getElementById("optDir").value.trim();
    const body={};
    const sec=parseFloat(secStr);
    if(!isNaN(sec)&&sec>=0.1&&sec<=3600){
      POLL_MS=Math.round(sec*1000);
      body.pollMs=POLL_MS;
      if(timer){ clearInterval(timer); timer=setInterval(refresh,POLL_MS); }
    }
    // Clearing the folder empties lastPath, which re-enables the Add dialog's
    // folder field; the bridge then falls back to the default downloads dir.
    lastPath=dir;
    body.lastPath=dir;
    fetch(BRIDGE+"/settings",{method:"POST",
      headers:{"Content-Type":"application/json"},
      body:JSON.stringify(body)}).catch(()=>{});
    document.getElementById("optPop").hidden=true;
  }
  function openHelp(){ document.getElementById("helpPop").hidden=false; }

  // ---- render torrent list ----
  function renderTorrents(torrents){
    const list=document.getElementById("list");
    torrentsByHash={};
    if(!torrents||torrents.length===0){
      list.innerHTML='<div class="empty">No active torrents</div>';
      if(selectedHash!==null){ selectedHash=null; refreshButtons(); }
      return;
    }
    let stillSelected=false;
    list.innerHTML=torrents.map(t=>{
      torrentsByHash[t.hash]=t;
      if(t.hash===selectedHash) stillSelected=true;
      const icon=ICONS[t.status]||"•";
      const sel=t.hash===selectedHash?" sel":"";
      const rates=[];
      if(t.downRate) rates.push("⬇ "+fmtRate(t.downRate));
      if(t.upRate) rates.push("⬆ "+fmtRate(t.upRate));
      const metaLine=rates.length
        ? '<div class="meta">'+rates.join("&nbsp;&nbsp;")+'</div>' : '';
      const errLine=(t.status==="ERROR"&&t.message)
        ? '<div class="err">'+esc(t.message)+'</div>' : '';
      // "<pct>% <size> (#<shortHash>)" — the # stays, matching the queue badges.
      const sub='<div class="sub">'+t.percent+'% &middot; '+esc(fmtSize(t.sizeBytes))
        +' &middot; <span class="hash">(#'+esc(t.shortHash)+')</span></div>';
      return '<div class="row'+sel+'" draggable="true" data-hash="'+esc(t.hash)+'">'
        +'<span class="ic">'+icon+'</span>'
        +'<div class="name-col"><div class="name">'+esc(t.name)+'</div>'
        +sub+errLine+metaLine+'</div></div>';
    }).join("");
    list.querySelectorAll(".row").forEach(r=>{
      r.addEventListener("click",()=>selectRow(r.dataset.hash));
      // Dragging a torrent onto the bin is a Stop request (with the keep/delete
      // confirm) — a torrent is tagged "torrent:<hash>" so the bin can tell it
      // apart from a queued-command tile ("cmd:<id>").
      r.addEventListener("dragstart",e=>{
        e.dataTransfer.setData("text/plain","torrent:"+r.dataset.hash);
        e.dataTransfer.effectAllowed="move";
        r.classList.add("dragging");
      });
      r.addEventListener("dragend",()=>r.classList.remove("dragging"));
    });
    if(!stillSelected&&selectedHash!==null){ selectedHash=null; refreshButtons(); }
  }

  // ---- render degraded banner + command chain ----
  function renderQueue(state, queue){
    const block=document.getElementById("degraded");
    const online = state==="ONLINE" || !state;
    const empty = !queue || queue.length===0;
    if(online && empty){ block.hidden=true; return; }   // hide during normal ops
    block.hidden=false;

    let word;
    if(state==="DAEMON_UNREACHABLE") word="rtorrent is down (unreachable)";
    else if(state==="DAEMON_BUSY") word="rtorrent is busy (hash-checking)";
    else word="rtorrent recovered — draining queued commands";
    document.getElementById("banner").textContent="⚠️ "+word+" — queued commands:";

    const q=document.getElementById("queue");
    if(empty){ q.innerHTML='<div class="empty">— empty —</div>'; return; }
    q.innerHTML=(queue||[]).map(c=>{
      const cls=c.state==="running"?" running":(c.state==="failed"?" failed":"");
      const badge=c.shortHash
        ? '<span class="badge">'+esc(c.shortHash)+'</span>' : '';
      return '<div class="cmd'+cls+'" draggable="true" data-id="'+esc(c.id)+'">'
        +(c.icon||"•")+badge+'</div>';
    }).join("");
    wireDrag();
  }

  // ---- drag & drop a queued command to the bin ----
  const bin=document.getElementById("bin");
  function wireDrag(){
    document.querySelectorAll(".cmd").forEach(c=>{
      c.addEventListener("dragstart",e=>{
        e.dataTransfer.setData("text/plain", "cmd:"+c.dataset.id);
        e.dataTransfer.effectAllowed="move";
        c.classList.add("dragging");
      });
      c.addEventListener("dragend",()=>c.classList.remove("dragging"));
    });
  }
  bin.addEventListener("dragover",e=>{e.preventDefault();
    e.dataTransfer.dropEffect="move"; bin.classList.add("armed");});
  bin.addEventListener("dragleave",()=>bin.classList.remove("armed"));
  bin.addEventListener("drop",async e=>{
    e.preventDefault(); bin.classList.remove("armed");
    const payload=e.dataTransfer.getData("text/plain");
    if(!payload) return;
    if(payload.indexOf("torrent:")===0){
      // Dropping a torrent removes it — ask keep vs delete first (never silent).
      openStop(payload.slice(8));
      return;
    }
    const id=payload.indexOf("cmd:")===0?payload.slice(4):payload;
    try{
      await fetch(BRIDGE+"/command/cancel",{method:"POST",
        headers:{"Content-Type":"application/json"},
        body:JSON.stringify({id:id})});
    }catch(err){ /* ignore — poll reflects the truth */ }
    refresh();
  });

  // ---- poll loop ----
  async function refresh(){
    if(!running) return;
    try{
      const res=await fetch(BRIDGE+"/status");
      const data=await res.json();
      // queue + rtorrentState ride along in BOTH the ok and degraded payloads.
      renderQueue(data.rtorrentState, data.queue);
      if(data.ok){
        renderTorrents(data.torrents);
        const totDown=(data.torrents||[]).reduce((a,t)=>a+(t.downRate||0),0);
        const totUp=(data.torrents||[]).reduce((a,t)=>a+(t.upRate||0),0);
        const totals=(totDown||totUp)?"⬇ "+fmtRate(totDown)+"  ⬆ "+fmtRate(totUp)+" · ":"";
        document.getElementById("updated").textContent=
          totals+"updated "+new Date().toLocaleTimeString();
      }else{
        document.getElementById("updated").textContent=
          "⚠️ "+(data.error||"bridge error");
      }
    }catch(e){
      document.getElementById("list").innerHTML=
        '<div class="empty">Cannot reach bridge (is iSH open?)</div>';
      document.getElementById("updated").textContent="";
      renderQueue("ONLINE", []);
    }
  }

  // ---- Exit: stop polling immediately, never wait on rtorrent ----
  function doExit(){
    running=false;
    if(timer){ clearInterval(timer); timer=null; }
    document.getElementById("app").innerHTML=
      '<div class="empty" style="margin:auto">👋 Stopped.<br>'
      +'You can exit, iSH is closed now.</div>';
    // Best-effort: close the tab if the browser allows a script-initiated close.
    try{ window.close(); }catch(e){}
  }

  // ---- wire buttons ----
  document.getElementById("bAdd").addEventListener("click",openAdd);
  document.getElementById("bResume").addEventListener("click",()=>cmdOnSelected("resume"));
  document.getElementById("bPause").addEventListener("click",()=>cmdOnSelected("pause"));
  document.getElementById("bStop").addEventListener("click",()=>{ if(selectedHash!==null) openStop(selectedHash); });
  document.getElementById("bErr").addEventListener("click",showInfo);
  document.getElementById("options").addEventListener("click",openOptions);
  document.getElementById("exit").addEventListener("click",doExit);

  // ---- pull-to-refresh on the torrent list ----
  // iOS has no built-in pull-to-refresh for an in-app scroll container, so we
  // detect the gesture ourselves and call refresh() (soft reload of all tiles).
  (function(){
    const list=document.getElementById("list");
    const ptr=document.getElementById("ptr");
    const THRESHOLD=70;      // px the finger must travel down to trigger
    let startY=0, pulling=false, dist=0;

    list.addEventListener("touchstart",function(e){
      // Only arm the gesture when the list is scrolled to the very top.
      if(list.scrollTop<=0 && e.touches.length===1){
        startY=e.touches[0].clientY; pulling=true; dist=0;
      }else{
        pulling=false;
      }
    },{passive:true});

    list.addEventListener("touchmove",function(e){
      if(!pulling) return;
      dist=e.touches[0].clientY-startY;
      if(dist>0 && ptr){
        ptr.classList.add("show");
        ptr.textContent = dist>THRESHOLD ? "↑ Release to refresh" : "↓ Pull to refresh";
      }
    },{passive:true});

    list.addEventListener("touchend",function(){
      if(!pulling) return;
      pulling=false;
      if(dist>THRESHOLD){
        if(ptr){ ptr.classList.add("spin"); ptr.textContent="⟳ Refreshing…"; }
        Promise.resolve(refresh()).finally(function(){
          if(ptr){
            ptr.classList.remove("spin");
            ptr.classList.remove("show");
            ptr.textContent="↓ Pull to refresh";
          }
        });
      }else if(ptr){
        ptr.classList.remove("show");
      }
      dist=0;
    });
  })();

  // ---- boot ----
  async function start(){
    try{
      const s=await (await fetch(BRIDGE+"/settings")).json();
      if(s&&s.ok){
        if(s.pollMs) POLL_MS=s.pollMs;
        if(s.lastPath) lastPath=s.lastPath;
      }
    }catch(e){ /* bridge down — keep defaults; /status will show the error */ }
    refreshButtons();
    refresh();
    timer=setInterval(refresh, POLL_MS);
  }
  start();
</script>
</body>
</html>
__GCTORRENT_APP_HTML__

if [ ! -s /root/gctorrent/app.html ]; then
    echo "Missing /root/gctorrent/app.html after write - aborting."
    exit 1
fi

echo "[2/4] directories + .rtorrent.rc..."
# Only the session dir is needed; the bridge creates downloads/ on first add.
mkdir -p /root/.session
mkdir -p /root/gctorrent/state
cat > /root/.rtorrent.rc << 'RCEOF'
# Unix domain socket (lower overhead, avoids "Socket not connected" drops).
network.scgi.open_local = /root/gctorrent/state/rtorrent.sock
# Let rtorrent (re)create the socket file on each start.
schedule2 = scgi_permission, 0, 0, "execute.nothrow=chmod,0777,/root/gctorrent/state/rtorrent.sock"
directory.default.set = /root/downloads
session.path.set = /root/.session
# DHT + PEX + random high ports: find peers when trackers are down/unreachable.
dht.mode.set = auto
protocol.pex.set = yes
network.port_range.set = 6890-9999
network.port_random.set = yes
schedule2 = dht_node, 5, 0, "dht.add_node=dht.transmissionbt.com:6881"
# 5-min session checkpoint so an unclean iOS SIGKILL doesn't force a full re-check.
schedule2 = session_save, 300, 300, ((session.save))
# Raise the XML-RPC cap (512 KiB default) to fit base64'd multi-MB .torrent files.
network.xmlrpc.size_limit.set = 8388608
pieces.memory.max.set = 32M
RCEOF

echo "[3/4] making work.sh executable..."
chmod +x /root/gctorrent/work.sh

echo "[4/4] installing .profile autostart hook..."
# Hook logic lives in its own file; .profile only sources it (one stable line).
cat > /root/gctorrent/autostart.sh << 'AUTOEOF'
# Sourced from .profile on every iSH launch; runs work.sh to bring up the stack.
if [ -f "/root/gctorrent/state/location_confirmed" ] && ! pgrep -x rtorrent >/dev/null 2>&1; then
    /root/gctorrent/work.sh
fi
AUTOEOF

# Migrate .profile: drop the old inline block and hook-sourcing line, guarded
# on existence (sed -i on a missing file fails under set -e).
if [ -f /root/.profile ]; then
    sed -i -e '/# torrent-autostart/,/^fi$/d' -e '/\.torrent_autostart\.sh/d' /root/.profile
fi

# Make .profile source the hook file (idempotent single line).
if ! grep -q 'gctorrent/autostart.sh' /root/.profile 2>/dev/null; then
    echo '[ -f /root/gctorrent/autostart.sh ] && . /root/gctorrent/autostart.sh' >> /root/.profile
fi

# Migrate saved settings from an older location; first source wins, never clobber.
if [ ! -f /root/gctorrent/settings.json ]; then
    if [ -f /root/gctorrent/prefs.json ]; then
        mv /root/gctorrent/prefs.json /root/gctorrent/settings.json
    elif [ -f /root/.torrent_prefs.json ]; then
        mv /root/.torrent_prefs.json /root/gctorrent/settings.json
    fi
fi

# Carry the location grant forward so autostart keeps working without re-granting.
if [ -f /root/.location_always_confirmed ]; then
    touch /root/gctorrent/state/location_confirmed
fi

# Remove pre-reorg orphans now that everything lives under /root/gctorrent/.
rm -f /root/bridge.py /root/work.sh /root/.torrent_autostart.sh \
      /root/.location_check /root/.location_always_confirmed \
      /root/.torrent_prefs.json /root/gctorrent/prefs.json

# (Re)install returns to normal: clear the maintenance + readiness flags.
rm -f /root/gctorrent/state/detached /root/gctorrent/state/bridge_ready

# Stop any previous-version bridge AND a stale location reader so the fresh
# work.sh doesn't open /dev/location twice (that relaunches iSH). Kill by the
# PID that work.sh recorded when it spawned each process — deterministic and
# immune to the busybox `pkill -f` self-match problem (a self-describing
# pattern kept matching the killer's own command line and killing nothing / the
# wrong process). No command-line inspection happens at all.
for pidfile in /root/gctorrent/state/bridge.pid /root/gctorrent/state/location.pid; do
    if [ -f "$pidfile" ]; then
        pid=$(cat "$pidfile" 2>/dev/null)
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
        rm -f "$pidfile"
    fi
done

echo ""
echo "Setup done - starting rtorrent now..."
echo "Allow the Location popup, then set Settings > iSH > Location > Always."
echo "After that, just opening iSH auto-starts everything (via the .profile hook)."

# Hand off to the backend: exec replaces this shell with work.sh, which brings up
# the bridge and rtorrent — so `sh install.sh` alone finishes the whole first run
# and the caller needs no trailing work.sh step. work.sh deletes the one-shot
# /root/install.sh bootstrap on startup, so /root stays clean WITHOUT this script
# unlinking itself mid-run: after exec, install.sh is a closed file the next
# process removes normally (no reliance on unlink-while-open).
exec sh /root/gctorrent/work.sh
