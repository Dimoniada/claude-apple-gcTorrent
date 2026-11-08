#!/bin/sh
# Checks "remove + delete file" deletes only the torrent's own data, never the
# folder it was saved into. Uses a throwaway folder; needs a running bridge,
# curl and python3 (e.g. on a Mac). Usage: sh tests/remove_check.sh [base-url]
B=${1:-http://127.0.0.1:5001}
D=$(mktemp -d)
echo keep > "$D/neighbour.txt"
# Writes the torrents' data into $D and prints "hash base64" per torrent.
python3 -I - "$D" > "$D/torrents" <<'EOF'
import base64, hashlib, os, sys
d = sys.argv[1]
def be(x):
    if isinstance(x, int): return b"i%de" % x
    if isinstance(x, str): x = x.encode()
    if isinstance(x, bytes): return b"%d:" % len(x) + x
    if isinstance(x, list): return b"l" + b"".join(map(be, x)) + b"e"
    return b"d" + b"".join(be(k) + be(x[k]) for k in sorted(x)) + b"e"
a, b = os.urandom(3000), os.urandom(4000)
open(os.path.join(d, "single.bin"), "wb").write(a)
os.makedirs(os.path.join(d, "multi"))
open(os.path.join(d, "multi", "f.bin"), "wb").write(b)
for info in ({"name": "single.bin", "length": 3000, "piece length": 16384, "pieces": hashlib.sha1(a).digest()},
             {"name": "multi", "files": [{"length": 4000, "path": ["f.bin"]}], "piece length": 16384,
              "pieces": hashlib.sha1(b).digest()}):
    t = be({"announce": "http://127.0.0.1:1/a", "info": info})
    print(hashlib.sha1(be(info)).hexdigest().upper(), base64.b64encode(t).decode())
EOF
while read -r h t; do
    curl -s -X POST -d "{\"data\":\"$t\",\"directory\":\"$D\"}" "$B/add" > /dev/null
done < "$D/torrents"
sleep 3
while read -r h t; do
    curl -s -X POST -d "{\"hash\":\"$h\",\"deleteFile\":true}" "$B/remove" > /dev/null
done < "$D/torrents"
sleep 1
fail=0
[ -f "$D/neighbour.txt" ] && echo "ok   other files in the folder survive" || { echo "FAIL the whole folder was deleted"; fail=1; }
[ ! -e "$D/single.bin" ] && echo "ok   single-file torrent's file deleted" || { echo "FAIL single.bin still there"; fail=1; }
[ ! -e "$D/multi" ] && echo "ok   multi-file torrent's folder deleted" || { echo "FAIL multi/ still there"; fail=1; }
rm -rf "$D"
exit $fail
