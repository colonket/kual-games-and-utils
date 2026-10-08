#!/bin/sh
# End-to-end OGS test: the real app in the simulator against tests/mock_ogs.py.
# usage: tests/ogs_e2e.sh [OUTDIR] [W H DPI]
#   OGS_PORT (default 8745)   mock port
#   MODE=env (default)        OGS_BASE/OGS_WS point at the mock
#   MODE=redirect             EINK_NET_REDIRECT routes https://online-go.com and wss:// to the mock
#   PNG=1                     also convert the frames to PNG (needs python3 + PIL)
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-/tmp/sim_ogs_e2e}
shift 2>/dev/null
OGS_PORT=${OGS_PORT:-8745}
LOG=${OGS_MOCK_LOG:-/tmp/mock_ogs_e2e_$OGS_PORT.log}
python3 "$HERE/mock_ogs.py" $OGS_PORT 2>"$LOG" & MOCK=$!
sleep 0.6
if [ "${MODE:-env}" = redirect ]; then
  export EINK_NET_REDIRECT=http://127.0.0.1:$OGS_PORT
  unset OGS_BASE OGS_WS
else
  export OGS_BASE=http://127.0.0.1:$OGS_PORT OGS_WS=ws://127.0.0.1:$OGS_PORT/
fi
"$HERE/sim.sh" home "$HERE/scripts/ogs_e2e.lua" "$OUT" "$@"; rc=$?
kill $MOCK 2>/dev/null
if [ "${PNG:-0}" = 1 ]; then
  python3 -c "
import sys, glob
from PIL import Image
for p in glob.glob(sys.argv[1] + '/*.pgm'):
    Image.open(p).save(p[:-4] + '.png')
" "$OUT"
fi
[ $rc -ne 0 ] && { echo "--- mock log ($LOG)"; tail -n 30 "$LOG"; }
[ $rc -eq 0 ] && echo "PASS ogs_e2e" || echo "FAIL ogs_e2e"
exit $rc
