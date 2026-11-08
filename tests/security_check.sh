#!/bin/sh
# Checks a running bridge refuses cross-site POSTs and folder names that could
# inject rtorrent commands. Usage: sh tests/security_check.sh [base-url]
B=${1:-http://127.0.0.1:5001}
fail=0
check() {
    case "$2" in
        *"$3"*) echo "ok   $1" ;;
        *) echo "FAIL $1: $2"; fail=1 ;;
    esac
}
check "POST from another site is refused" \
    "$(curl -s -X POST -H 'Origin: https://example.com' -d '{}' "$B/nope")" '"error":"FORBIDDEN"'
check "POST from the bridge's own page is allowed" \
    "$(curl -s -X POST -H "Origin: $B" -d '{}' "$B/nope")" '"error":"NOT_FOUND"'
check "folder name with a quote is refused" \
    "$(curl -s -X POST -d '{"url":"magnet:?xt=urn:btih:0000000000000000000000000000000000000000","directory":"x\";y"}' "$B/add")" '"error":"BAD_REQUEST"'
check "no CORS header on responses" \
    "$(curl -s -D - -o /dev/null "$B/ping" | grep -i -c 'access-control-allow-origin')" '0'
exit $fail
