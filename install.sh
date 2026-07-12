#!/bin/sh
# install.sh - one-time iSH setup for the rtorrent remote-control stack.
#
# Self-extracting: bridge.py and work.sh are bundled inside this file and
# written to /root/gctorrent on run (alongside the log, settings, and state
# flags). It finishes by removing itself and exec'ing work.sh, so the Torrent
# Downloader shortcut fetches and runs it in a single step:
#   … && sh install.sh
#
# It installs packages, writes .rtorrent.rc, makes work.sh executable, and
# installs a .profile autostart hook so future iSH launches auto-start the
# stack. work.sh is non-interactive (no "type yes"); it just needs the iOS
# Location permission granted (Always) to keep running in the background.
set -e

echo "[0/4] extracting bundled bridge.py and work.sh..."
# All app files (source, log, prefs, state flags) live under /root/gctorrent/.
# .rtorrent.rc and .profile stay pinned in $HOME (rtorrent and the shell read
# them from there); downloads/ and .session/ stay in /root as they are data.
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

It is now the ONLY control path. The old a-Shell + rtorrent_rpc.py + "|||"
plain-text pipeline has been retired — everything (ping, list, add, pause,
remove, prefs) goes through the endpoints below and returns JSON.

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
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
from urllib.request import Request, urlopen
from xmlrpc.client import Binary, dumps, loads

RTORRENT_HOST = "127.0.0.1"
RTORRENT_PORT = 5000
BRIDGE_PORT = 5001

# All app files live under ~/gctorrent/. settings.json holds user preferences
# (the save path, the dashboard poll rate, and whatever we add later); paths
# stored here are valid iSH paths (root's home, where rtorrent's download
# directories also live), not iOS Files paths.
APP_DIR = os.path.expanduser("~/gctorrent")
STATE_DIR = os.path.join(APP_DIR, "state")
SETTINGS_PATH = os.path.join(APP_DIR, "settings.json")
# "How to find your downloads folder" help clip, fetched by install.sh and
# served over loopback so the Shortcut's Help menu can Quick Look it.
HELP_GIF_PATH = os.path.join(APP_DIR, "howto_downloads.gif")

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


def scgi_call(method, params=()):
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

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(5)
    try:
        sock.connect((RTORRENT_HOST, RTORRENT_PORT))
        sock.sendall(request)
        sock.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
    except socket.timeout as e:
        # Connecting to loopback succeeds instantly unless nothing is listening
        # (that raises ConnectionRefused, below), so a timeout here means
        # rtorrent accepted the socket but is too busy to answer in time —
        # alive, just pinned (hash-checking). Report it distinctly so the
        # Shortcut can say "busy, wait a moment and re-run" instead of failing.
        if method != "d.multicall2":
            log("rtorrent call %s timed out: %s (busy hash-checking?)" % (method, e))
        raise RuntimeError("DAEMON_BUSY") from e
    except (ConnectionRefusedError, OSError) as e:
        # Skip the high-frequency status poll (d.multicall2) so a down rtorrent
        # being polled by the dashboard doesn't flood the log; still record the
        # user-initiated calls (add/pause/remove/ping) that we want to trace.
        if method != "d.multicall2":
            log("rtorrent call %s failed: %s (is rtorrent running?)" % (method, e))
        raise RuntimeError("DAEMON_UNREACHABLE") from e
    finally:
        sock.close()

    response = b"".join(chunks)
    header_end = response.find(b"\r\n\r\n")
    body = response[header_end + 4:] if header_end != -1 else response
    result, _ = loads(body)
    return result[0] if result else None


# --- command logic (copied verbatim from the retired rtorrent_rpc.py) --------

# status -> emoji for the ready-made `label` row. Mirrors dashboard.js's icons.
STATUS_ICONS = {
    "DOWNLOADING": "⬇️", "UPLOADING": "⬆️", "DOWNLOADING&UPLOADING": "↕️",
    "DONE": "✅", "CHECKING": "🔍", "PAUSED": "⏸️", "IDLE": "⏳", "ERROR": "⚠️",
}


def get_status(short=None):
    # `short`, if given, is a shortHash prefix (first 6 hex of the info-hash).
    # rtorrent only knows the full 40-char hash, so we filter here in the bridge.
    short = short.lower() if short else None
    fields = (
        "d.hash=", "d.name=", "d.is_open=", "d.is_active=", "d.state=",
        "d.hashing=", "d.complete=", "d.down.rate=", "d.up.rate=", "d.message=",
        "d.bytes_done=", "d.size_bytes=",
    )
    rows = scgi_call("d.multicall2", ("", "main") + fields)
    torrents = []
    for row in rows or []:
        h, name, is_open, is_active, state, hashing, complete, down_rate, up_rate, message, done, size = row
        if short and h[:6].lower() != short:
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
    # announce) "un-sticks" it. Force an immediate tracker re-announce here so
    # resume re-fetches peers now instead of waiting. Non-fatal: a torrent with no
    # usable tracker (pure magnet / DHT-only) just no-ops or errors harmlessly.
    log("resume (start): %s" % h)
    scgi_call("d.start", (h,))
    try:
        scgi_call("d.tracker_announce", (h,))
    except RuntimeError as e:
        log("resume: tracker_announce failed (non-fatal): %s" % e)


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


# --- HTTP layer --------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # keep iSH's console quiet

    def _send_json(self, obj, status=200):
        # Compact separators (no space after ':' or ',') so the iOS Shortcut's
        # locale-proof `Contains "key":value` text checks match the raw body.
        # Every endpoint replies through here, so this covers all APIs/fields.
        body = json.dumps(obj, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        # CORS header so the Scriptable WebView (loaded via loadHTML, treated
        # as a different origin) is allowed to fetch() these endpoints.
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

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
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

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
                short = parse_qs(parsed.query).get("short", [None])[0]
                self._send_json({"ok": True, "torrents": get_status(short)})
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
    server = HTTPServer((RTORRENT_HOST, BRIDGE_PORT), Handler)
    # The bind above succeeded — announce readiness so work.sh stops waiting and
    # launches rtorrent. Remove it on exit so a stale marker never outlives us.
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(READY_FLAG, "w") as f:
        f.write(str(os.getpid()))
    atexit.register(
        lambda: os.path.exists(READY_FLAG) and os.remove(READY_FLAG)
    )
    # Background thread that restores a magnet's chosen directory after rtorrent
    # reverts it on metadata resolution (bug #376). Daemon so it dies with us.
    threading.Thread(target=reconcile_loop, daemon=True).start()
    log("magnet directory reconciler started")
    log(f"bridge.py listening on {RTORRENT_HOST}:{BRIDGE_PORT}")
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

# Location keep-alive (needed only for the live torrent session).
rm -f "$LOCATION_LOG"

echo "Starting background keep-alive (location)..."
cat /dev/location > "$LOCATION_LOG" 2>&1 &
LOC_PID=$!

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

echo "Starting rtorrent..."
rtorrent

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
apk_retry update || true
apk_retry add python3 rtorrent

# Fetch the "how to find your downloads folder" help clip. The bridge serves
# it over loopback at GET /help/downloads.gif and the Shortcut's Help menu shows
# it via Quick Look. Non-fatal: if this download fails the app is unaffected —
# only the Help clip is missing (the endpoint then returns 404).
echo "  fetching help clip (howto_downloads.gif)..."
wget -qO /root/gctorrent/howto_downloads.gif \
  https://raw.githubusercontent.com/Dimoniada/claude-apple-gcTorrent/main/howto_downloads.gif \
  || echo "  (help clip download skipped)"

echo "[2/4] directories + .rtorrent.rc..."
# Only the session dir is needed up front (rtorrent reads it at startup). The
# downloads folder is NOT pre-created: the bridge makes the destination folder on
# the first add (the name the user picks, or "downloads" as the fallback when the
# folder is left blank), so a fresh install doesn't leave an empty ~/downloads
# sitting around before anything has actually been downloaded.
mkdir -p /root/.session
cat > /root/.rtorrent.rc << 'RCEOF'
network.scgi.open_port = 127.0.0.1:5000
directory.default.set = /root/downloads
session.path.set = /root/.session
# Peer discovery beyond trackers. Many torrents here ride on flaky public
# trackers, and iSH often can't even reach UDP ones — so without DHT/PEX a
# torrent whose tracker is down finds no peers and stalls at a fixed percent.
# DHT (auto: enabled for public torrents, off for private) plus peer exchange
# let it find peers independently of the tracker; the dht_node schedule bootstraps
# the DHT so it can join the swarm even when the torrent's own tracker is dead.
# Random high ports (not the classic, DPI-throttled 6881-6889 range); inbound is
# moot behind carrier NAT anyway. Note: this joins the device to the public DHT
# swarm (slightly more network/battery, less private than tracker-only).
dht.mode.set = auto
protocol.pex.set = yes
network.port_range.set = 6890-9999
network.port_random.set = yes
schedule2 = dht_node, 5, 0, "dht.add_node=dht.transmissionbt.com:6881"
# Periodically flush session state (piece bitfield + file mtimes) to the session
# dir so rtorrent can fast-resume instead of re-hashing every torrent on the next
# launch. iSH can't guarantee a clean shutdown — iOS usually SIGKILLs the app, so
# there's no chance to save on exit — and a bare rtorrent doesn't schedule this on
# its own. A 5-minute checkpoint keeps an unclean kill from costing a full
# re-check. (First run at 300s, then every 300s.)
schedule2 = session_save, 300, 300, ((session.save))
# Raise the XML-RPC request cap from the 512 KiB default so larger .torrent
# files fit. The bridge sends the file as base64 inside the XML-RPC body
# (load.raw_start), which inflates ~500 KB to ~690 KB and hit "Fault -503:
# XML-RPC request too large. Max allowed is 524288 bytes". 8 MiB leaves room
# for even multi-MB .torrent files.
network.xmlrpc.size_limit.set = 8388608
RCEOF

echo "[3/4] making work.sh executable..."
chmod +x /root/gctorrent/work.sh

echo "[4/4] installing .profile autostart hook..."
# The mutable hook logic lives in its own file so a reinstall always refreshes
# it; .profile only ever gets one stable line that sources this file.
cat > /root/gctorrent/autostart.sh << 'AUTOEOF'
# Sourced from .profile on every iSH launch. Runs work.sh, which always brings
# the status bridge up and — unless detached — starts rtorrent too. The detached
# case is handled inside work.sh so the bridge still answers /ping.
if [ -f "/root/gctorrent/state/location_confirmed" ] && ! pgrep -x rtorrent >/dev/null 2>&1; then
    /root/gctorrent/work.sh
fi
AUTOEOF

# Migrate .profile: drop the old inline autostart block (pre-sourcing installs)
# AND the old hook-sourcing line (pre-reorg /root/.torrent_autostart.sh), then
# add the new one below. Guard on existence: on a clean install .profile doesn't
# exist yet, and a bare `sed -i` on a missing file returns non-zero, which under
# `set -e` would abort here — before the hook line is added (leaving .profile
# empty and rtorrent never auto-starting).
if [ -f /root/.profile ]; then
    sed -i -e '/# torrent-autostart/,/^fi$/d' -e '/\.torrent_autostart\.sh/d' /root/.profile
fi

# Make .profile source the hook file (idempotent single line).
if ! grep -q 'gctorrent/autostart.sh' /root/.profile 2>/dev/null; then
    echo '[ -f /root/gctorrent/autostart.sh ] && . /root/gctorrent/autostart.sh' >> /root/.profile
fi

# Migrate saved settings into gctorrent/settings.json from either older location
# (pre-reorg ~/.torrent_prefs.json, or the short-lived gctorrent/prefs.json) so a
# saved save-path/poll rate survives. First existing source wins; never clobber.
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

# A (re)install means "return to normal": clear any maintenance flag so the next
# iSH launch autostarts the backend again, and drop the readiness marker so the
# freshly-spawned bridge is the one that recreates it.
rm -f /root/gctorrent/state/detached /root/gctorrent/state/bridge_ready

# Stop any bridge from a previous version (old /root or new /root/gctorrent path)
# so the freshly-written bridge.py is the one that runs when work.sh (re)starts it.
pkill -f "python3 /root/.*bridge.py" 2>/dev/null || true

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
