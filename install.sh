#!/bin/sh
# install.sh - one-time iSH setup for the rtorrent remote-control stack.
#
# Self-extracting: bridge.py and work.sh are bundled inside this file and
# written to /root on run. Save just THIS file into iSH's /root (via the
# Shortcut), then run it ONCE:  sh install.sh
#
# It does only the parts a file-copy can't: installs packages, writes
# .rtorrent.rc, makes work.sh executable, and installs a .profile autostart
# hook so future iSH launches auto-start rtorrent. It never runs work.sh
# itself - the first launch stays manual (for the location permission popup).
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
    GET  /prefs                                 -> {"ok": true, "lastPath": "<str>"}
    POST /add     {"url":..., "directory":...}  -> {"ok": true}
    POST /pause   {"hash":...}                  -> {"ok": true}
    POST /remove  {"hash":..., "deleteFile":bool} -> {"ok": true}
    POST /prefs   {"lastPath":...}              -> {"ok": true}

Error codes: DAEMON_UNREACHABLE, INVALID_LINK, BAD_REQUEST, NOT_FOUND.

No third-party packages are used — only the Python standard library — so
`apk add python3` is the only iSH-side dependency.
"""

import json
import os
import shutil
import socket
from http.server import BaseHTTPRequestHandler, HTTPServer
from xmlrpc.client import dumps, loads

RTORRENT_HOST = "127.0.0.1"
RTORRENT_PORT = 5000
BRIDGE_PORT = 5001

# Replaces the a-Shell torrent_prefs.json. Lives in iSH's filesystem (root's
# home), which is also where rtorrent's download directories live — so paths
# stored here are valid iSH paths, not iOS Files paths.
PREFS_PATH = os.path.expanduser("~/.torrent_prefs.json")


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
        raise RuntimeError("DAEMON_UNREACHABLE") from e
    finally:
        sock.close()

    response = b"".join(chunks)
    header_end = response.find(b"\r\n\r\n")
    body = response[header_end + 4:] if header_end != -1 else response
    result, _ = loads(body)
    return result[0] if result else None


# --- command logic (copied verbatim from the retired rtorrent_rpc.py) --------

def get_status():
    fields = (
        "d.hash=", "d.name=", "d.is_open=", "d.is_active=",
        "d.complete=", "d.down.rate=", "d.up.rate=", "d.message=",
        "d.bytes_done=", "d.size_bytes=",
    )
    rows = scgi_call("d.multicall2", ("", "main") + fields)
    torrents = []
    for row in rows or []:
        h, name, is_open, is_active, complete, down_rate, up_rate, message, done, size = row
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
        raise RuntimeError("INVALID_LINK")

    os.makedirs(os.path.expanduser(directory), exist_ok=True)
    scgi_call(
        "load.start",
        ("", url, f'd.directory.set="{directory}"'),
    )


def do_pause(h):
    scgi_call("d.pause", (h,))


def do_remove(h, delete_file):
    """Stop + erase a torrent, optionally deleting its data. Copied from
    rtorrent_rpc.py's cmd_remove."""
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
            if self.path == "/ping":
                scgi_call("system.pid")
                self._send_json({"ok": True})
            elif self.path == "/status":
                self._send_json({"ok": True, "torrents": get_status()})
            elif self.path == "/prefs":
                self._send_json({"ok": True, "lastPath": read_prefs().get("lastPath", "")})
            else:
                self._send_json({"ok": False, "error": "NOT_FOUND"}, status=404)
        except RuntimeError as e:
            self._send_json({"ok": False, "error": str(e)})
        except Exception as e:  # noqa: BLE001 - surface anything else as JSON
            self._send_json({"ok": False, "error": str(e)})

    def do_POST(self):
        try:
            try:
                data = self._read_body()
            except ValueError:
                self._send_json({"ok": False, "error": "BAD_REQUEST"}, status=400)
                return

            if self.path == "/add":
                url = data.get("url")
                directory = data.get("directory")
                if not url or not directory:
                    self._send_json({"ok": False, "error": "BAD_REQUEST"}, status=400)
                    return
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
                do_remove(h, bool(data.get("deleteFile", False)))
                self._send_json({"ok": True})
            elif self.path == "/prefs":
                prefs = read_prefs()
                prefs["lastPath"] = data.get("lastPath", "")
                write_prefs(prefs)
                self._send_json({"ok": True})
            else:
                self._send_json({"ok": False, "error": "NOT_FOUND"}, status=404)
        except RuntimeError as e:
            self._send_json({"ok": False, "error": str(e)})
        except Exception as e:  # noqa: BLE001 - surface anything else as JSON
            self._send_json({"ok": False, "error": str(e)})


if __name__ == "__main__":
    server = HTTPServer((RTORRENT_HOST, BRIDGE_PORT), Handler)
    print(f"bridge.py listening on {RTORRENT_HOST}:{BRIDGE_PORT}")
    server.serve_forever()
__GCTORRENT_BRIDGE_PY__
cat > /root/work.sh << '__GCTORRENT_WORK_SH__'
#!/bin/sh
# work.sh — boots the background keep-alive trick, sanity-checks it,
# and only then launches rtorrent. Run this instead of `rtorrent` directly.

LOCATION_LOG="/root/.location_check"
FLAG_FILE="/root/.location_always_confirmed"

rm -f "$LOCATION_LOG"

echo "Starting background keep-alive (location)..."
cat /dev/location > "$LOCATION_LOG" 2>&1 &
LOC_PID=$!

sleep 3

if [ ! -s "$LOCATION_LOG" ]; then
    echo ""
    echo "!!! Location permission is NOT working. !!!"
    echo "rtorrent will be suspended as soon as you switch away from iSH."
    echo ""
    echo "Fix: Settings -> iSH -> Location -> Always"
    echo "Then run this script again."
    kill "$LOC_PID" 2>/dev/null
    exit 1
fi

echo "Location feed is active (PID $LOC_PID)."

if [ ! -f "$FLAG_FILE" ]; then
    echo ""
    echo "=========================================================="
    echo " FIRST-TIME CHECK (only needed once per iSH install)"
    echo " Please confirm manually right now:"
    echo "   Settings -> iSH -> Location -> should say 'Always'"
    echo " (this script can only confirm location works in the"
    echo "  foreground, not that it's specifically set to Always)"
    echo "=========================================================="
    echo ""
    printf "Type 'yes' once you've confirmed it says Always: "
    read answer
    if [ "$answer" != "yes" ]; then
        echo "Aborting — please confirm the setting, then rerun this script."
        kill "$LOC_PID" 2>/dev/null
        exit 1
    fi
    touch "$FLAG_FILE"
fi

echo "Starting rtorrent..."
python3 /root/bridge.py > /root/.bridge.log 2>&1 &
BRIDGE_PID=$!
echo "Status bridge running (PID $BRIDGE_PID) on 127.0.0.1:5001"

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
if ! grep -q 'torrent-autostart' /root/.profile 2>/dev/null; then
    cat >> /root/.profile << 'PROFEOF'
# torrent-autostart
if [ -f "$HOME/.location_always_confirmed" ] && ! pgrep -x rtorrent >/dev/null 2>&1; then
    /root/work.sh
fi
PROFEOF
fi

echo ""
echo "Setup done. Now run:  ./work.sh"
echo "First run only: allow the location popup, set Settings > iSH > Location > Always, type yes."
echo "After that, just opening iSH auto-starts rtorrent (via the .profile hook)."
