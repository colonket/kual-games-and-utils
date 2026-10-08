#!/bin/sh
# Whole test suite with distinct ports (8740-8749) and a summary.
# usage: tests/test_all.sh            frames land in ${SIM_OUT:-/tmp/sim_all}_*
# Suites share extension/einkapps/data, so they run one after another.
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$HERE/.."
OUT=${SIM_OUT:-/tmp/sim_all}
LUAJIT=${LUAJIT:-/home/claude/opt/luajit/bin/luajit}
SUMMARY=""
FAILED=0

run() { # run <name> <command...>
  name=$1; shift
  log="${OUT}_$name.log"
  "$@" >"$log" 2>&1; rc=$?
  if [ $rc -eq 0 ]; then SUMMARY="$SUMMARY\nPASS  $name"
  else SUMMARY="$SUMMARY\nFAIL  $name   (see $log)"; FAILED=1; fi
  printf '%s %s\n' "$([ $rc -eq 0 ] && echo PASS || echo FAIL)" "$name"
}

cd "$ROOT" || exit 1
run run_all        env WEB_PORT=8740 SIM_OUT="${OUT}_apps" "$HERE/run_all.sh"
run go_test        "$LUAJIT" "$HERE/go_test.lua"
run ws_test        env WS_PORT=8743 WSS_PORT=8744 "$HERE/ws_test.sh"
run net_test       env WEB_PORT=8747 "$HERE/net_test.sh"
run ogs_test       env OGS_PORT=8742 SIM_OUT="${OUT}_ogs_rt" "$HERE/ogs_test.sh"
run ogs_e2e        env OGS_PORT=8745 "$HERE/ogs_e2e.sh" "${OUT}_ogs_e2e"
run ogs_e2e_600    env OGS_PORT=8746 MODE=redirect "$HERE/ogs_e2e.sh" "${OUT}_ogs_e2e600" 600 800 167
run ogs_ui_stub    "$HERE/sim.sh" calculator "$HERE/scripts/ogs_ui.lua" "${OUT}_ogs_ui"
run goboard_demo   "$HERE/sim.sh" calculator "$HERE/scripts/goboard_demo.lua" "${OUT}_goboard"
run mtg            "$HERE/sim.sh" mtg "$HERE/mtg_script.lua" "${OUT}_mtg"
run home           "$HERE/sim.sh" home "$HERE/scripts/home.lua" "${OUT}_home"

# Lichess against its mock (needs a saved token)
python3 "$HERE/mock_lichess.py" 8741 2>"${OUT}_mock_lichess.log" & LI=$!
sleep 0.6
echo "lip_testtoken123" > "$ROOT/extension/einkapps/data/lichess_token.txt"
run lichess        env LICHESS_BASE=http://127.0.0.1:8741 "$HERE/sim.sh" lichess "$HERE/lichess_script.lua" "${OUT}_li"
run lichess_seek   env LICHESS_BASE=http://127.0.0.1:8741 "$HERE/sim.sh" lichess "$HERE/lichess_seek.lua" "${OUT}_li_seek"
kill $LI 2>/dev/null

git -C "$ROOT" diff --quiet -- extension/einkapps/data/README.txt 2>/dev/null \
  && [ -f "$ROOT/extension/einkapps/data/README.txt" ] \
  || { SUMMARY="$SUMMARY\nFAIL  data/README.txt was modified or deleted"; FAILED=1; }

printf "\n== summary ==$SUMMARY\n"
exit $FAILED
