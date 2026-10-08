#!/bin/sh
# usage: tests/sim.sh <app> <script.lua> <outdir> [W H DPI]
HERE=$(cd "$(dirname "$0")/.." && pwd)
APP=$1; SCRIPT=$(cd "$(dirname "$2")" && pwd)/$(basename "$2"); OUT=$3
rm -rf "$OUT"; mkdir -p "$OUT"
export EINK_SIM="$OUT" EINK_SIM_W=${4:-1072} EINK_SIM_H=${5:-1448} EINK_SIM_DPI=${6:-300}
export EINK_SIM_SCRIPT="$SCRIPT"
export EINK_APPS_ROOT="$HERE/extension/einkapps"
export EINK_LUA_PATH="/home/claude/opt/lua/share/?.lua;$HERE/tests/?.lua;"
export EINK_LUA_CPATH="/home/claude/opt/lua/lib/?.so;"
export KOREADER_DIR=/nonexistent
mkdir -p "$EINK_APPS_ROOT/data"
cd "$EINK_APPS_ROOT" && timeout 300 /home/claude/opt/luajit/bin/luajit lua/main.lua "$APP"
