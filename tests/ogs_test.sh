#!/bin/sh
# OGS api + realtime tests against tests/mock_ogs.py.
#   1. tests/ogs_api_test.lua: standalone LuaJIT, full login -> game -> scoring flow
#   2. tests/ogs_rt_sim.lua:  the same socket driven by ui.run inside the simulator
# usage: tests/ogs_test.sh     (OGS_PORT default 8722, SIM_OUT default /tmp/sim_ogs_rt)
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$HERE/../extension/einkapps"
LUAJIT=${LUAJIT:-luajit}
LUA_OPT=${LUA_OPT:-}   # optional prefix holding share/?.lua and lib/?.so (LuaSocket, LuaSec)
OGS_PORT=${OGS_PORT:-8722}
LOG=${OGS_MOCK_LOG:-/tmp/mock_ogs_$OGS_PORT.log}
python3 "$HERE/mock_ogs.py" $OGS_PORT 2>"$LOG" & MOCK=$!
sleep 0.6
export OGS_BASE=http://127.0.0.1:$OGS_PORT OGS_WS=ws://127.0.0.1:$OGS_PORT/
TMP=$(mktemp -d)
rc=0
OGS_TEST_DATA="$TMP" EINK_SIM="$TMP/sim" \
  LUA_PATH="$ROOT/lua/?.lua;$LUA_OPT/share/?.lua;$HERE/?.lua;;" LUA_CPATH="$LUA_OPT/lib/?.so;;" \
  "$LUAJIT" "$HERE/ogs_api_test.lua" || rc=1
"$HERE/sim.sh" calculator "$HERE/ogs_rt_sim.lua" "${SIM_OUT:-/tmp/sim_ogs_rt}" || rc=1
kill $MOCK 2>/dev/null
rm -rf "$TMP"
[ $rc -ne 0 ] && { echo "--- mock log ($LOG)"; tail -n 30 "$LOG"; }
[ $rc -eq 0 ] && echo "PASS ogs_test" || echo "FAIL ogs_test"
exit $rc
