#!/bin/sh
# Run every simulator script; frames land in /tmp/sim/<app>/
HERE=$(cd "$(dirname "$0")" && pwd)
python3 "$HERE/mock_web.py" 8770 2>/tmp/mock_web.log & WEB=$!
sleep 0.6
export EINK_NET_REDIRECT=http://127.0.0.1:8770
DATA="$HERE/../extension/einkapps/data"
rm -rf "$DATA"; mkdir -p "$DATA"
echo '{"feeds":["https://news.ycombinator.com/rss","https://www.reddit.com/r/kindle/.rss"]}' > "$DATA/rss.json"
fail=0
for app in ${APPS:-calculator dice sudoku chess clock settings weather wikipedia rss duckduckgo}; do
  "$HERE/sim.sh" "$app" "$HERE/scripts/$app.lua" "/tmp/sim/$app" >/tmp/sim_$app.log 2>&1
  rc=$?
  grep -E "^ok:|level|gen time" /tmp/sim_$app.log | sed "s/^/  [$app] /"
  if [ $rc -ne 0 ]; then echo "FAIL $app (rc=$rc)"; grep -v "^\s" /tmp/sim_$app.log | head -5; fail=1; else echo "PASS $app"; fi
done
kill $WEB
exit $fail
