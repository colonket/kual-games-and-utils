#!/bin/sh
# core/net.lua security tests (URL sanitising, cert names, redirects, size caps)
# against tests/mock_web.py.  usage: tests/net_test.sh   (WEB_PORT default 8747)
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$HERE/../extension/einkapps"
LUAJIT=${LUAJIT:-/home/claude/opt/luajit/bin/luajit}
LUA_OPT=${LUA_OPT:-/home/claude/opt/lua}
export WEB_PORT=${WEB_PORT:-8747}
LOG=$(mktemp)
python3 "$HERE/mock_web.py" $WEB_PORT 2>"$LOG" & WEB=$!
sleep 0.6
export LUA_PATH="$ROOT/lua/?.lua;$LUA_OPT/share/?.lua;$HERE/?.lua;;"
export LUA_CPATH="$LUA_OPT/lib/?.so;;"
"$LUAJIT" "$HERE/net_test.lua"; rc=$?
kill $WEB 2>/dev/null
[ $rc -ne 0 ] && { echo "--- mock log"; tail -n 20 "$LOG"; }
rm -f "$LOG"
[ $rc -eq 0 ] && echo "PASS net_test" || echo "FAIL net_test"
exit $rc
