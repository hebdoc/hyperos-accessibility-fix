#!/system/bin/sh

#  Stop HyperOS from randomly disabling accessibility services
#  Copyright (C) 2026 chkndrp
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License along
#  with this program; if not, see <https://www.gnu.org/licenses/>.

MODPATH="$1"
SCRIPTDIR="$MODPATH/scripts"

PIDFILE="/tmp/a11y_watchdog.pid"
MONITOR_PIDFILE="/tmp/a11y_watchdog_monitor.pid"
LOGFILE="/tmp/a11y_watchdog.log"
LOCKFILE="/tmp/a11y_watchdog.restart.lock"

# Write PID to file for instant, non-blocking monitoring
printf "%d\n" "$$" > "$MONITOR_PIDFILE.tmp" && mv -f "$MONITOR_PIDFILE.tmp" "$MONITOR_PIDFILE" || exit 1

# Increase OOM score to prevent getting killed by LMKD
if [[ -f /proc/self/oom_score_adj ]]; then
    printf -- "-900" > /proc/self/oom_score_adj
fi

log() {
    if [ "$(wc -l < "$LOGFILE")" -gt 150 ]; then
        tail -n 80 "$LOGFILE" > "$LOGFILE.tmp"
        mv -f "$LOGFILE.tmp" "$LOGFILE"
    fi

    printf "%s [monitor] %s\n" "$(date '+%m-%d %H:%M:%S')" "$1" >> "$LOGFILE"
}

is_process_alive() {
    local pid="$1"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

clean_stale_lock() {
    if [[ -f "$LOCKFILE" ]]; then
        local lock_pid=""
        read -r lock_pid < "$LOCKFILE" 2>/dev/null
        if ! is_process_alive "$lock_pid"; then
            rm -f "$LOCKFILE"
        fi
    fi
}

restart_watchdog() {
    clean_stale_lock

    local waited=0
    local lock_timeout=30
    local acquired_lock=0

    while [ "$waited" -lt "$lock_timeout" ]; do
        if (set -o noclobber; printf "%s\n" "$$" > "$LOCKFILE") 2>/dev/null; then
            acquired_lock=1
            break
        fi
        sleep 0.1
        waited=$(( waited + 1 ))
    done

    if [ "$acquired_lock" -eq 0 ]; then
        clean_stale_lock
        return 1
    fi

    # Check if watchdog was already started while waiting
    local current_pid=""
    if read -r current_pid < "$PIDFILE" 2>/dev/null && is_process_alive "$current_pid"; then
        rm -f "$LOCKFILE"
        log "Watchdog process ($current_pid) is already running"
        return 0
    fi

    log "Watchdog dead or missing PID. Restarting watchdog daemon..."
    setsid /system/bin/sh "$SCRIPTDIR/a11y_watchdog.sh" "$MODPATH" "$LOGFILE" > /dev/null 2>&1 < /dev/null &

    local attempts=0
    local restarted_pid=""
    while [ "$attempts" -lt 30 ]; do
        if read -r restarted_pid < "$PIDFILE" 2>/dev/null && is_process_alive "$restarted_pid"; then
            rm -f "$LOCKFILE"
            log "Watchdog restarted successfully (PID: $restarted_pid)"
            return 0
        fi
        sleep 0.1
        attempts=$(( attempts + 1 ))
    done

    rm -f "$LOCKFILE"
    log "Failed to verify watchdog restart after 3 seconds"
    return 1
}

# Immediate check upon startup
if ! read -r PID < "$PIDFILE" 2>/dev/null || ! is_process_alive "$PID"; then
    log "Initial check: watchdog process not detected, starting..."
    restart_watchdog
fi

# Main monitoring loop
while true; do
    sleep 25

    if ! read -r PID < "$PIDFILE" 2>/dev/null || ! is_process_alive "$PID"; then
        log "Watchdog process dead or PID missing, restarting watchdog"
        restart_watchdog
    fi
done
