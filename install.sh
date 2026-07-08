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
    GET  /ping                                  -> {"ok": true}
    GET  /status                                -> {"ok": true, "torrents": [...]}
    GET  /status?short=<6hex>                    -> {"ok": true, "torrents": [<0 or 1>]}
    GET  /prefs                                 -> {"ok": true, "lastPath": "<str>"}
    POST /add     {"url":..., "directory":...}  -> {"ok": true}
    POST /add     {"data":<base64 .torrent>, "directory":...} -> {"ok": true}
    POST /pause   {"hash":...}                  -> {"ok": true}
    POST /remove  {"hash":..., "deleteFile":bool} -> {"ok": true}
    POST /prefs   {"lastPath":...}              -> {"ok": true}
    POST /detach                                -> {"ok": true}

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

# Sentinel for "maintenance mode": while this file exists, the .profile autostart
# hook skips launching the backend, so iSH opens to a shell prompt (even across
# restarts). POST /detach creates it; install.sh removes it on (re)install.
DETACH_FLAG = os.path.expanduser("~/.detached")


def log(*args):
    """One timestamped line of bridge activity. work.sh redirects the bridge's
    stdout+stderr to ~/.bridge.log, so these land there (read it in iSH with
    `cat ~/.bridge.log` / `tail -f ~/.bridge.log`) to trace rtorrent calls and
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

    Writes the ~/.detached sentinel that the .profile autostart hook checks, so
    rtorrent stays stopped even if iSH is closed and reopened during the
    reinstall; install.sh removes the sentinel, re-enabling autostart. Then
    SIGTERM rtorrent (clean session save); -x matches the exact process name,
    like the autostart guard does.

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
                scgi_call("system.pid")
                self._send_json({"ok": True})
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
# work.sh — boots the background location keep-alive, then launches
# bridge.py + rtorrent. Run instead of `rtorrent` directly. Non-interactive.

LOCATION_LOG="/root/.location_check"
FLAG_FILE="/root/.location_always_confirmed"

# Mark that setup has run, up front — so the .profile autostart hook will
# retry on the next iSH open even if this run aborts before location is
# granted. No manual re-run/typing needed.
touch "$FLAG_FILE"

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
python3 /root/bridge.py > /root/.bridge.log 2>&1 &
BRIDGE_PID=$!
echo "Status bridge running (PID $BRIDGE_PID) on 127.0.0.1:5001"

# Skip rtorrent if a POST /detach put us into maintenance mode (e.g. before a
# reinstall). No startup countdown here — rtorrent launches immediately; to get
# a shell when iSH opens straight into rtorrent, press Ctrl-Q (quit rtorrent).
DETACH_FLAG="/root/.detached"
if [ -f "$DETACH_FLAG" ]; then
    echo "Detached (maintenance mode) — not starting rtorrent."
    kill "$BRIDGE_PID" 2>/dev/null
    exit 0
fi

echo "Starting rtorrent..."
rtorrent

# rtorrent only returns here when it exits (crash or manual quit) — clean up
# the bridge process too, so a stale one isn't left listening on the port.
kill "$BRIDGE_PID" 2>/dev/null
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
RCEOF

echo "[3/4] making work.sh executable..."
chmod +x /root/work.sh

echo "[4/4] installing .profile autostart hook..."
# The mutable hook logic lives in its own file so a reinstall always refreshes
# it; .profile only ever gets one stable line that sources this file.
cat > /root/.torrent_autostart.sh << 'AUTOEOF'
# Sourced from .profile on every iSH launch. Starts the backend unless the user
# detached it: the bridge's POST /detach writes ~/.detached for maintenance mode
# (e.g. before a reinstall), so iSH opens straight to a shell prompt.
if [ -f "$HOME/.location_always_confirmed" ] && [ ! -f "$HOME/.detached" ] && ! pgrep -x rtorrent >/dev/null 2>&1; then
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

echo ""
echo "Setup done - starting rtorrent now..."
echo "Allow the Location popup, then set Settings > iSH > Location > Always."
echo "After that, just opening iSH auto-starts everything (via the .profile hook)."
