#!/bin/sh
# core/ws.lua tests: plain + TLS echo servers, then the Lua test script.
# usage: tests/ws_test.sh   (WS_PORT/WSS_PORT default 8723/8724)
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$HERE/../extension/einkapps"
LUAJIT=${LUAJIT:-/home/claude/opt/luajit/bin/luajit}
LUA_OPT=${LUA_OPT:-/home/claude/opt/lua}
export WS_PORT=${WS_PORT:-8723} WSS_PORT=${WSS_PORT:-8724}
TMP=$(mktemp -d)
# self-signed cert for 127.0.0.1 (+ an unrelated CA to check rejection)
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=127.0.0.1" \
  -addext "subjectAltName=IP:127.0.0.1" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=other" \
  -keyout "$TMP/okey.pem" -out "$TMP/other.pem" 2>/dev/null
python3 "$HERE/ws_echo_server.py" $WS_PORT 2>"$TMP/ws.log" & P1=$!
python3 "$HERE/ws_echo_server.py" $WSS_PORT "$TMP/cert.pem" "$TMP/key.pem" 2>"$TMP/wss.log" & P2=$!
sleep 0.6
export LUA_PATH="$ROOT/lua/?.lua;$LUA_OPT/share/?.lua;$HERE/?.lua;;"
export LUA_CPATH="$LUA_OPT/lib/?.so;;"
WS_CERT="$TMP/cert.pem" WS_OTHER_CA="$TMP/other.pem" "$LUAJIT" "$HERE/ws_test.lua"; rc=$?
EINK_NET_REDIRECT=http://127.0.0.1:$WS_PORT "$LUAJIT" "$HERE/ws_test.lua" || rc=1
kill $P1 $P2 2>/dev/null
[ $rc -ne 0 ] && { echo "--- server logs"; tail -n 20 "$TMP/ws.log" "$TMP/wss.log"; }
rm -rf "$TMP"
[ $rc -eq 0 ] && echo "PASS ws_test" || echo "FAIL ws_test"
exit $rc
