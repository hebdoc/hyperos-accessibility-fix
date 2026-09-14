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

LOGFILE="/tmp/a11y_watchdog.log"
PIDFILE="/tmp/a11y_watchdog.pid"
MODPROP="$MODPATH/module.prop"
WATCHLIST="$MODPATH/a11y_watchlist.txt"
EXCLUDE_FILE="$MODPATH/a11y_exclude.txt"
SCRIPTDIR="$MODPATH/scripts"

MODULENAME=$(grep '^name=' "$MODPROP" 2>/dev/null | cut -d'=' -f2)
VERSION=$(grep '^version=' "$MODPROP" 2>/dev/null | cut -d'=' -f2)
[[ -z "$MODULENAME" ]] && MODULENAME="HyperOS accessibility fix"
[[ -z "$VERSION" ]] && VERSION="1.0.6"

echo "========================================="
echo " $MODULENAME v$VERSION"
echo "========================================="

# 1. Check Watchdog Process Status
WATCHDOG_PID=""
if [[ -f "$PIDFILE" ]]; then
    read -r WATCHDOG_PID < "$PIDFILE" 2>/dev/null
fi

if [[ -n "$WATCHDOG_PID" ]] && kill -0 "$WATCHDOG_PID" 2>/dev/null; then
    OOM_SCORE=$(cat "/proc/$WATCHDOG_PID/oom_score_adj" 2>/dev/null || echo "N/A")
    echo "[+] Watchdog Daemon: RUNNING (PID: $WATCHDOG_PID, oom_score_adj: $OOM_SCORE)"
else
    echo "[-] Watchdog Daemon: NOT RUNNING"
    echo "    Attempting to restart watchdog..."
    setsid /system/bin/sh "$SCRIPTDIR/a11y_watchdog.sh" "$MODPATH" "$LOGFILE" > /dev/null 2>&1 < /dev/null &
    sleep 0.5
    if [[ -f "$PIDFILE" ]]; then
        read -r NEW_PID < "$PIDFILE" 2>/dev/null
        if [[ -n "$NEW_PID" ]] && kill -0 "$NEW_PID" 2>/dev/null; then
            echo "[+] Watchdog successfully restarted (PID: $NEW_PID)"
        else
            echo "[-] Failed to restart watchdog. Check log for details."
        fi
    fi
fi

# 2. Check Monitor Status
MONITOR_PIDS=$(pgrep -f "a11y_watchdog_monitor.sh" 2>/dev/null || ps -ef 2>/dev/null | grep "[a]11y_watchdog_monitor.sh" | awk '{print $2}')
if [[ -n "$MONITOR_PIDS" ]]; then
    echo "[+] Monitor Daemon:  RUNNING (PID: $(echo $MONITOR_PIDS | tr '\n' ' '))"
else
    echo "[-] Monitor Daemon:  NOT RUNNING"
    echo "    Starting monitor daemon..."
    setsid /system/bin/sh "$SCRIPTDIR/a11y_watchdog_monitor.sh" "$MODPATH" > /dev/null 2>&1 < /dev/null &
fi

echo "-----------------------------------------"

# 3. Handle Command Argument Actions (sync, restore, clear)
ACTION="$1"
case "$ACTION" in
    sync)
        echo "[*] Triggering manual watchlist sync from active services..."
        ACTIVE=$(settings get secure enabled_accessibility_services 2>/dev/null)
        if [[ -n "$ACTIVE" && "$ACTIVE" != "null" ]]; then
            out_sync=""
            for s in ${ACTIVE//:/ }; do
                if [[ "$s" == */.* ]]; then
                    pkg="${s%%/*}"
                    s="$pkg/$pkg${s#*/}"
                fi
                out_sync="${out_sync}${s}\n"
            done
            printf '%b' "$out_sync" | sort > "$WATCHLIST"
            echo "[+] Watchlist updated with $(wc -l < "$WATCHLIST") service(s)."
        else
            : > "$WATCHLIST"
            echo "[*] Watchlist cleared (no active services enabled)."
        fi
        ;;
    restore)
        echo "[*] Triggering manual service restoration from watchlist..."
        if [[ -s "$WATCHLIST" ]]; then
            rep_list=""
            while IFS= read -r item || [[ -n "$item" ]]; do
                item="${item%$'\r'}"
                [[ -z "$item" ]] && continue
                rep_list="${rep_list}${item}:"
            done < "$WATCHLIST"
            rep_list="${rep_list%:}"
            if [[ -n "$rep_list" ]]; then
                settings put secure enabled_accessibility_services "$rep_list"
                settings put secure accessibility_enabled 1
                echo "[+] Successfully restored: $rep_list"
            fi
        else
            echo "[-] Watchlist is empty, nothing to restore."
        fi
        ;;
    clear)
        echo "[*] Clearing watchlist..."
        : > "$WATCHLIST"
        echo "[+] Watchlist cleared."
        ;;
esac

# 4. Show Current Services & Watchlist
echo "System Enabled Accessibility Services:"
SYSTEM_SVCS=$(settings get secure enabled_accessibility_services 2>/dev/null)
if [[ -z "$SYSTEM_SVCS" || "$SYSTEM_SVCS" == "null" ]]; then
    echo "  (None)"
else
    for s in ${SYSTEM_SVCS//:/ }; do
        echo "  - $s"
    done
fi

echo ""
echo "Watchdog Saved Services (Watchlist):"
if [[ -s "$WATCHLIST" ]]; then
    while IFS= read -r w || [[ -n "$w" ]]; do
        w="${w%$'\r'}"
        [[ -n "$w" ]] && echo "  * $w"
    done < "$WATCHLIST"
else
    echo "  (Empty)"
fi

if [[ -s "$EXCLUDE_FILE" ]]; then
    echo ""
    echo "Custom Excluded Services:"
    while IFS= read -r e || [[ -n "$e" ]]; do
        e="${e%$'\r'}"
        [[ -n "$e" ]] && echo "  x $e"
    done < "$EXCLUDE_FILE"
fi

echo "-----------------------------------------"
echo "Recent Watchdog Logs:"
if [[ -f "$LOGFILE" ]]; then
    tail -n 25 "$LOGFILE"
else
    echo "  (No log file found at $LOGFILE)"
fi
echo "========================================="

exit 0
