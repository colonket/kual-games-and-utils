#!/bin/sh
# KUAL launcher for Tabletop Apps. Usage: run.sh <app-id>
# Runs the apps with KOReader's LuaJIT while the Kindle UI is paused,
# the same way KOReader itself starts from KUAL.

APP="${1:-home}"
EXT_DIR="/mnt/us/extensions/einkapps"
KO_DIR="/mnt/us/koreader"
DATA="${EXT_DIR}/data"
LOG="${DATA}/log.txt"
mkdir -p "${DATA}"

msg() {
    if [ -x "${KO_DIR}/fbink" ]; then
        "${KO_DIR}/fbink" -q -m -y -6 "$1" >/dev/null 2>&1
    else
        eips 0 0 "$1" >/dev/null 2>&1
    fi
}

if [ ! -x "${KO_DIR}/luajit" ] && [ ! -f "${KO_DIR}/luajit" ]; then
    msg "Tabletop Apps needs KOReader in /mnt/us/koreader"
    exit 1
fi

# keep the log small
if [ -f "${LOG}" ] && [ "$(wc -c <"${LOG}")" -gt 200000 ]; then
    tail -c 100000 "${LOG}" >"${LOG}.tmp" && mv "${LOG}.tmp" "${LOG}"
fi
echo "=== $(date) run.sh ${APP}" >>"${LOG}"

# Kindlet-spawned processes run with nice 5; undo that.
[ "$(nice)" = "5" ] && renice -n -5 $$ >/dev/null 2>&1

# Pause the Kindle UI so it doesn't draw over us (same steps as koreader.sh).
usleep 250000 2>/dev/null || sleep 1
cat /dev/fb0 >/var/tmp/einkapps-fb.dump 2>/dev/null
lipc-set-prop com.lab126.pillow disableEnablePillow disable 2>/dev/null
killall -STOP awesome 2>/dev/null
STOPPED_STATUSBAR=no
if [ -f /etc/upstart/statusbar.conf ]; then
    stop statusbar >/dev/null 2>&1 && STOPPED_STATUSBAR=yes
fi

cleanup() {
    lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null
    [ "${STOPPED_STATUSBAR}" = "yes" ] && start statusbar >/dev/null 2>&1
    killall -CONT awesome 2>/dev/null
    if [ -f /var/tmp/einkapps-fb.dump ]; then
        cat /var/tmp/einkapps-fb.dump >/dev/fb0 2>/dev/null
        rm -f /var/tmp/einkapps-fb.dump
    fi
    lipc-set-prop com.lab126.pillow disableEnablePillow enable 2>/dev/null
    lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home 2>/dev/null
}
trap cleanup EXIT INT TERM

cd "${EXT_DIR}" || exit 1
EINK_APPS_ROOT="${EXT_DIR}" KOREADER_DIR="${KO_DIR}" "${KO_DIR}/luajit" lua/main.lua "${APP}" >>"${LOG}" 2>&1
RC=$?
if [ ${RC} -ne 0 ]; then
    echo "exit code ${RC}" >>"${LOG}"
fi
exit 0
