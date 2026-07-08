#!/bin/sh
# install.sh - one-time iSH setup for the rtorrent remote-control stack.
#
# Self-extracting: bridge.py and work.sh are bundled inside this file and
# written to /root on run. The Torrent Downloader shortcut fetches this file
# via wget and runs it once:  sh install.sh && ./work.sh
#
# It installs packages, writes .rtorrent.rc, makes work.sh executable, and
# installs a .profile autostart hook so future iSH launches auto-start the
# stack. work.sh is non-interactive (no "type yes"); it just needs the iOS
# Location permission granted (Always) to keep running in the background.
set -e

echo "[0/4] extracting bundled bridge.py and work.sh..."
cat > /root/bridge.py << '__GCTORRENT_BRIDGE_PY__'
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
    GET  /ping                                  -> {"ok": true, "detached": bool}
    GET  /status                                -> {"ok": true, "torrents": [...]}
    GET  /status?short=<6hex>                    -> {"ok": true, "torrents": [<0 or 1>]}
    GET  /prefs                                 -> {"ok": true, "lastPath": "<str>"}
    POST /add     {"url":..., "directory":...}  -> {"ok": true}
    POST /add     {"data":<base64 .torrent>, "directory":...} -> {"ok": true}
    POST /pause   {"hash":...}                  -> {"ok": true}
    POST /remove  {"hash":..., "deleteFile":bool} -> {"ok": true}
    POST /prefs   {"lastPath":...}              -> {"ok": true}
    POST /detach                                -> {"ok": true}
    POST /attach                                -> {"ok": true}

Error codes: DAEMON_UNREACHABLE, INVALID_LINK, BAD_REQUEST, NOT_FOUND.

No third-party packages are used — only the Python standard library — so
`apk add python3` is the only iSH-side dependency.
"""

import base64
import json
import os
import shutil
import socket
import subprocess
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
from xmlrpc.client import Binary, dumps, loads

RTORRENT_HOST = "127.0.0.1"
RTORRENT_PORT = 5000
BRIDGE_PORT = 5001

# Replaces the a-Shell torrent_prefs.json. Lives in iSH's filesystem (root's
# home), which is also where rtorrent's download directories live — so paths
# stored here are valid iSH paths, not iOS Files paths.
PREFS_PATH = os.path.expanduser("~/.torrent_prefs.json")

# Sentinel for "maintenance mode": while this file exists, work.sh keeps the
# bridge up but does NOT start rtorrent, so iSH opens to a shell prompt (even
# across restarts) while /ping still answers. POST /detach creates it;
# POST /attach and install.sh remove it.
DETACH_FLAG = os.path.expanduser("~/.detached")


def log(*args):
    """One timestamped line of bridge activity. work.sh redirects the bridge's
    stdout+stderr to ~/bridge.log, so these land there (read it in iSH with
    `cat ~/bridge.log` / `tail -f ~/bridge.log`) to trace rtorrent calls and
    surface errors — e.g. "rtorrent isn't responding" or "added but nothing
    happened"."""
    print(time.strftime("%H:%M:%S"), *args, flush=True)


def scgi_call(method, params=()):
    """Send a single XML-RPC call over the SCGI protocol to rtorrent.

    Raises RuntimeError("DAEMON_UNREACHABLE") on any socket failure — same
    contract the retired rtorrent_rpc.py used, so callers map it straight to a
    JSON error.
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
    except (ConnectionRefusedError, socket.timeout, OSError) as e:
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

def get_status(short=None):
    # `short`, if given, is a shortHash prefix (first 6 hex of the info-hash).
    # rtorrent only knows the full 40-char hash, so we filter here in the bridge.
    short = short.lower() if short else None
    fields = (
        "d.hash=", "d.name=", "d.is_open=", "d.is_active=",
        "d.complete=", "d.down.rate=", "d.up.rate=", "d.message=",
        "d.bytes_done=", "d.size_bytes=",
    )
    rows = scgi_call("d.multicall2", ("", "main") + fields)
    torrents = []
    for row in rows or []:
        h, name, is_open, is_active, complete, down_rate, up_rate, message, done, size = row
        if short and h[:6].lower() != short:
            continue
        downloading = int(down_rate) > 0
        uploading = int(up_rate) > 0

        if message:
            status = "ERROR"
        elif downloading and uploading:
            status = "DOWNLOADING&UPLOADING"
        elif downloading:
            status = "DOWNLOADING"
        elif uploading:
            status = "UPLOADING"
        elif int(complete):
            status = "DONE"
        else:
            status = "IDLE"

        percent = round(100 * int(done) / int(size), 1) if int(size) else 0

        torrents.append({
            "hash": h,
            "shortHash": h[:6].lower(),
            "name": name,
            "status": status,
            "message": message,
            "downRate": int(down_rate),
            "upRate": int(up_rate),
            "percent": percent,
        })
    return torrents


def do_add(url, directory):
    """Validate + load a magnet/.torrent into rtorrent. Copied from
    rtorrent_rpc.py's cmd_add. Raises RuntimeError("INVALID_LINK") or
    RuntimeError("DAEMON_UNREACHABLE")."""
    url = (url or "").strip()
    is_magnet = url.startswith("magnet:")
    is_torrent_url = url.startswith("http://") or url.startswith("https://")
    if not (is_magnet or is_torrent_url):
        log("add rejected (not a magnet/http link): %r" % url[:100])
        raise RuntimeError("INVALID_LINK")

    os.makedirs(os.path.expanduser(directory), exist_ok=True)
    log("add: loading %r into %s" % (url[:100], directory))
    result = scgi_call(
        "load.start",
        ("", url, f'd.directory.set="{directory}"'),
    )
    # load.start returns 0 when rtorrent accepted the request. The torrent then
    # has to fetch metadata (magnets) before it shows up in /status, so "added"
    # is not the same as "downloading" — this line tells the two apart.
    log("add: rtorrent load.start returned %r" % (result,))


def do_add_raw(data_b64, directory):
    """Load a .torrent from its raw bytes (base64) rather than a link — used when
    the Shortcut passes the file itself (clipboard file / Share Sheet). rtorrent's
    load.raw_start takes the bencoded content directly. Non-base64 chars (e.g. the
    line breaks Shortcuts may add) are discarded by b64decode's default mode."""
    try:
        raw = base64.b64decode(data_b64 or "")
    except (ValueError, TypeError):
        log("add rejected (undecodable base64 .torrent data)")
        raise RuntimeError("INVALID_LINK")
    # A bencoded .torrent is a dict, so it starts with 'd' and ends with 'e'.
    if not (raw[:1] == b"d" and raw[-1:] == b"e"):
        log("add rejected (not a valid .torrent: %d bytes)" % len(raw))
        raise RuntimeError("INVALID_LINK")

    os.makedirs(os.path.expanduser(directory), exist_ok=True)
    log("add: loading %d-byte .torrent file into %s" % (len(raw), directory))
    result = scgi_call(
        "load.raw_start",
        ("", Binary(raw), f'd.directory.set="{directory}"'),
    )
    log("add: rtorrent load.raw_start returned %r" % (result,))


def do_detach():
    """Put the backend into 'maintenance mode' and stop rtorrent, so the Shortcut
    can free the iSH terminal *before* opening it for a reinstall — the user
    pastes the reinstall command once, at a real shell prompt, instead of
    quitting rtorrent by hand (Ctrl-Q).

    Writes the ~/.detached sentinel that work.sh checks, so rtorrent stays stopped
    across iSH restarts (the bridge itself keeps running, so /ping still answers
    and reports detached=true). do_attach / a reinstall removes the sentinel to
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
    log("pause: %s" % h)
    scgi_call("d.pause", (h,))


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


def read_prefs():
    try:
        with open(PREFS_PATH) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def write_prefs(prefs):
    with open(PREFS_PATH, "w") as f:
        json.dump(prefs, f)


# --- HTTP layer --------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # keep iSH's console quiet

    def _send_json(self, obj, status=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        # CORS header so the Scriptable WebView (loaded via loadHTML, treated
        # as a different origin) is allowed to fetch() these endpoints.
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

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
                # Report maintenance mode regardless of rtorrent's state, so the
                # Shortcut can tell "detached on purpose" from "rtorrent crashed".
                detached = os.path.exists(DETACH_FLAG)
                try:
                    scgi_call("system.pid")
                    self._send_json({"ok": True, "detached": detached})
                except RuntimeError as e:
                    self._send_json({"ok": False, "detached": detached, "error": str(e)})
            elif path == "/status":
                short = parse_qs(parsed.query).get("short", [None])[0]
                self._send_json({"ok": True, "torrents": get_status(short)})
            elif path == "/prefs":
                self._send_json({"ok": True, "lastPath": read_prefs().get("lastPath", "")})
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
            elif self.path == "/remove":
                h = data.get("hash")
                if not h:
                    self._send_json({"ok": False, "error": "BAD_REQUEST"}, status=400)
                    return
                do_remove(h, as_bool(data.get("deleteFile", False)))
                self._send_json({"ok": True})
            elif self.path == "/prefs":
                prefs = read_prefs()
                prefs["lastPath"] = data.get("lastPath", "")
                write_prefs(prefs)
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
    log(f"bridge.py listening on {RTORRENT_HOST}:{BRIDGE_PORT}")
    server.serve_forever()
__GCTORRENT_BRIDGE_PY__
cat > /root/work.sh << '__GCTORRENT_WORK_SH__'
#!/bin/sh
# work.sh — starts the status bridge (always), and unless detached, the location
# keep-alive + rtorrent. Run instead of `rtorrent` directly. Non-interactive.

LOCATION_LOG="/root/.location_check"
FLAG_FILE="/root/.location_always_confirmed"
DETACH_FLAG="/root/.detached"

# Mark that setup has run, up front — so the autostart hook keeps launching us on
# future iSH opens even if this run aborts before location is granted.
touch "$FLAG_FILE"

# Start the status bridge FIRST and unconditionally (guarded so we never run a
# second copy). Keeping it up whenever iSH is open lets the Shortcut always reach
# 127.0.0.1:5001 — even with rtorrent down or in maintenance mode — so /ping
# answers (ok:false / detached) instead of refusing the connection and
# hard-halting the Shortcut.
if ! pgrep -f "python3 /root/bridge.py" >/dev/null 2>&1; then
    python3 /root/bridge.py > /root/bridge.log 2>&1 &
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
echo "Starting rtorrent..."
rtorrent

# rtorrent exited (crash or Ctrl-Q). Leave the bridge running so the Shortcut can
# still reach it; work.sh reuses it (the pgrep guard above) on the next launch.
__GCTORRENT_WORK_SH__

for f in bridge.py work.sh; do
    if [ ! -f "/root/$f" ]; then
        echo "Missing /root/$f after extraction - aborting."
        exit 1
    fi
done

echo "[1/4] installing packages (python3, rtorrent)..."
apk update
apk add python3 rtorrent

echo "[2/4] directories + .rtorrent.rc..."
mkdir -p /root/downloads /root/.session
cat > /root/.rtorrent.rc << 'RCEOF'
network.scgi.open_port = 127.0.0.1:5000
directory.default.set = /root/downloads
session.path.set = /root/.session
# Raise the XML-RPC request cap from the 512 KiB default so larger .torrent
# files fit. The bridge sends the file as base64 inside the XML-RPC body
# (load.raw_start), which inflates ~500 KB to ~690 KB and hit "Fault -503:
# XML-RPC request too large. Max allowed is 524288 bytes". 8 MiB leaves room
# for even multi-MB .torrent files.
network.xmlrpc.size_limit.set = 8388608
RCEOF

echo "[3/4] making work.sh executable..."
chmod +x /root/work.sh

echo "[4/4] installing .profile autostart hook..."
# The mutable hook logic lives in its own file so a reinstall always refreshes
# it; .profile only ever gets one stable line that sources this file.
cat > /root/.torrent_autostart.sh << 'AUTOEOF'
# Sourced from .profile on every iSH launch. Runs work.sh, which always brings
# the status bridge up and — unless detached (~/.detached) — starts rtorrent too.
# The detached case is handled inside work.sh so the bridge still answers /ping.
if [ -f "$HOME/.location_always_confirmed" ] && ! pgrep -x rtorrent >/dev/null 2>&1; then
    /root/work.sh
fi
AUTOEOF

# Migrate away from the old inline autostart block (pre-sourcing installs).
# Guard on existence: on a clean install .profile doesn't exist yet, and a bare
# `sed -i` on a missing file returns non-zero, which under `set -e` would abort
# the script here — before the autostart hook below is written (leaving .profile
# empty and rtorrent never auto-starting).
if [ -f /root/.profile ]; then
    sed -i '/# torrent-autostart/,/^fi$/d' /root/.profile
fi

# Make .profile source the hook file (idempotent single line).
if ! grep -q 'torrent_autostart.sh' /root/.profile 2>/dev/null; then
    echo '[ -f /root/.torrent_autostart.sh ] && . /root/.torrent_autostart.sh' >> /root/.profile
fi

# A (re)install means "return to normal": clear any maintenance flag so the next
# iSH launch autostarts the backend again.
rm -f /root/.detached

# Stop any bridge from a previous version so the freshly-written bridge.py is the
# one that runs when work.sh (re)starts it.
pkill -f "python3 /root/bridge.py" 2>/dev/null || true

echo ""
echo "Setup done - starting rtorrent now..."
echo "Allow the Location popup, then set Settings > iSH > Location > Always."
echo "After that, just opening iSH auto-starts everything (via the .profile hook)."
