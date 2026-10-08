#!/bin/sh
# Run every simulator script; frames land in /tmp/sim/<app>/
HERE=$(cd "$(dirname "$0")" && pwd)
WEB_PORT=${WEB_PORT:-8770}
python3 "$HERE/mock_web.py" $WEB_PORT 2>/tmp/mock_web.log & WEB=$!
sleep 0.6
export EINK_NET_REDIRECT=http://127.0.0.1:$WEB_PORT
DATA="$HERE/../extension/einkapps/data"
mkdir -p "$DATA"
# wipe runtime state but keep the tracked README.txt
find "$DATA" -mindepth 1 ! -name README.txt -exec rm -rf {} + 2>/dev/null
echo '{"feeds":["https://news.ycombinator.com/rss","https://www.reddit.com/r/kindle/.rss"]}' > "$DATA/rss.json"
fail=0
for app in ${APPS:-calculator dice sudoku chess clock settings weather wikipedia rss duckduckgo}; do
  "$HERE/sim.sh" "$app" "$HERE/scripts/$app.lua" "${SIM_OUT:-/tmp/sim}/$app" >${SIM_OUT:-/tmp/sim}_$app.log 2>&1
  rc=$?
  grep -E "^ok:|level|gen time" ${SIM_OUT:-/tmp/sim}_$app.log | sed "s/^/  [$app] /"
  if [ $rc -ne 0 ]; then echo "FAIL $app (rc=$rc)"; grep -v "^\s" ${SIM_OUT:-/tmp/sim}_$app.log | head -5; fail=1; else echo "PASS $app"; fi
done
kill $WEB
exit $fail
