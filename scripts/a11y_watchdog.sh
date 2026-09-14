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
LOGFILE="$2"
WATCHLIST="$MODPATH/a11y_watchlist.txt"
EXCLUDE_FILE="$MODPATH/a11y_exclude.txt"
PIDFILE="/tmp/a11y_watchdog.pid"

# This service is managed automatically by HyperOS on some devices
DEFAULT_EXCLUDE_SVC="com.miui.screenshot/com.miui.screenshot.accessibility.ScreenshotAccessibilityService"

# Write PID to file for monitoring
printf "%d\n" "$$" > "$PIDFILE.tmp" && mv -f "$PIDFILE.tmp" "$PIDFILE" || exit 1

# Increase OOM score to prevent getting killed by LMKD
if [[ -f /proc/self/oom_score_adj ]]; then
    printf -- "-800" > /proc/self/oom_score_adj
fi

log() {
    if (( $(wc -l < "$LOGFILE") > 150 )); then
        tail -n 80 "$LOGFILE" > "$LOGFILE.tmp"
        mv -f "$LOGFILE.tmp" "$LOGFILE"
    fi

    printf "%s [watchdog] %s\n" "$(date '+%m-%d %H:%M:%S')" "$1" >> "$LOGFILE"
}

normalize_component() {
    local svc="$1"
    if [[ "$svc" == */.* ]]; then
        local pkg="${svc%%/*}"
        svc="$pkg/$pkg${svc#*/}"
    fi
    printf '%s\n' "$svc"
}

is_excluded() {
    local svc="$1"
    [[ "$svc" == "$DEFAULT_EXCLUDE_SVC" ]] && return 0
    if [[ -f "$EXCLUDE_FILE" ]]; then
        grep -Fqx "$svc" "$EXCLUDE_FILE" 2>/dev/null && return 0
    fi
    return 1
}

is_package_installed() {
    local pkg="$1"
    pm path "$pkg" >/dev/null 2>&1
}

get_services() {
    local out_str=""
    local get_svc_out
    get_svc_out=$(settings get secure enabled_accessibility_services 2>/dev/null)

    if [[ -z "$get_svc_out" || "$get_svc_out" == "null" ]]; then
        return
    fi

    for raw_svc in ${get_svc_out//:/ }; do
        [[ -z "$raw_svc" ]] && continue
        local svc_str
        svc_str=$(normalize_component "$raw_svc")
        [[ -z "$svc_str" ]] && continue

        if is_excluded "$svc_str"; then
            continue
        fi

        out_str="${out_str}${svc_str}:"
    done

    printf '%s\n' "${out_str%:}"
}

get_bound_services() {
    # Extract bound and binding services from dumpsys accessibility
    dumpsys accessibility 2>/dev/null | \
    grep -E "Bound services:{|Binding services:{" | \
    sed -e 's/.*services:{//' -e 's/}.*//' -e 's/, */ /g'
}

is_settings_focused() {
    # Check currently focused window or app via dumpsys window displays (lightweight and universal)
    if dumpsys window displays 2>/dev/null | grep -E "mCurrentFocus|mFocusedApp" | grep -qE "com\.android\.settings|com\.miui\.securitycenter"; then
        return 0
    fi
    # Fallback to dumpsys activity resumed check
    if dumpsys activity activities 2>/dev/null | grep -E "mResumedActivity|topResumedActivity" | grep -qE "com\.android\.settings|com\.miui\.securitycenter"; then
        return 0
    fi
    return 1
}

sync_live_to_watchlist() {
    local sync_cur sync_active item
    sync_cur=$(get_services)
    sync_active=""

    if [[ -n "$sync_cur" ]]; then
        for item in ${sync_cur//:/ }; do
            if [[ "$item" == *"/"* ]]; then
                sync_active="${sync_active}${item}\n"
            fi
        done
    fi

    local current_watchlist=""
    [[ -f "$WATCHLIST" ]] && current_watchlist=$(cat "$WATCHLIST" 2>/dev/null)

    local new_watchlist=""
    [[ -n "$sync_active" ]] && new_watchlist=$(printf '%b' "$sync_active" | sort)

    if [[ "$current_watchlist" != "$new_watchlist" ]]; then
        if [[ -n "$new_watchlist" ]]; then
            printf '%s\n' "$new_watchlist" > "$WATCHLIST"
            log "Watchlist synced with manual user changes: '$sync_cur'"
        else
            : > "$WATCHLIST"
            log "Watchlist cleared (all accessibility services disabled by user in settings)"
        fi
    fi
}

repair_database() {
    local rep_cur rep_seen rep_new cleaned_watchlist watchlist_modified
    rep_cur=$(get_services)
    rep_seen=""
    rep_new=""
    cleaned_watchlist=""
    watchlist_modified=0

    if [[ -f "$WATCHLIST" ]]; then
        while IFS= read -r raw_item || [[ -n "$raw_item" ]]; do
            local svc_item="${raw_item%$'\r'}"
            svc_item=$(normalize_component "$svc_item")
            [[ -z "$svc_item" ]] && continue
            if is_excluded "$svc_item"; then
                continue
            fi

            # Check if package is still installed
            local pkg="${svc_item%%/*}"
            if [[ -n "$pkg" ]] && ! is_package_installed "$pkg"; then
                log "Package '$pkg' is uninstalled. Removing from watchlist."
                watchlist_modified=1
                continue
            fi

            cleaned_watchlist="${cleaned_watchlist}${svc_item}\n"

            if [[ "$rep_seen" != *":$svc_item:"* ]]; then
                rep_new="${rep_new}${svc_item}:"
                rep_seen="$rep_seen:$svc_item:"
            fi
        done < "$WATCHLIST"
    fi

    # Prune uninstalled packages from watchlist file if any found
    if (( watchlist_modified == 1 )); then
        if [[ -n "$cleaned_watchlist" ]]; then
            printf '%b' "$cleaned_watchlist" | sort > "$WATCHLIST"
        else
            : > "$WATCHLIST"
        fi
    fi

    # Merge any currently enabled services
    for svc_item in ${rep_cur//:/ }; do
        svc_item=$(normalize_component "$svc_item")
        if [[ -z "$svc_item" || "$rep_seen" == *":$svc_item:"* ]] || is_excluded "$svc_item"; then
            continue
        fi

        rep_new="${rep_new}${svc_item}:"
        rep_seen="$rep_seen:$svc_item:"
    done

    rep_new="${rep_new%:}"

    if [[ "$rep_new" != "$rep_cur" && -n "$rep_new" ]]; then
        log "Wipe detected! Restored accessibility services: '$rep_new'"
        settings put secure enabled_accessibility_services "$rep_new"
        settings put secure accessibility_enabled 1
    fi
}

check_and_heal_fake_active() {
    # If user is in settings, do not interfere
    if is_settings_focused; then
        return 0
    fi

    local current_enabled
    current_enabled=$(get_services)
    [[ -z "$current_enabled" ]] && return 0

    local bound_raw
    bound_raw=$(get_bound_services)
    local bound_normalized=" "
    for b in $bound_raw; do
        local nb
        nb=$(normalize_component "$b")
        [[ -n "$nb" ]] && bound_normalized="${bound_normalized}${nb} "
    done

    local healthy_services=""
    local fake_dead=""

    for raw_svc in ${current_enabled//:/ }; do
        local svc
        svc=$(normalize_component "$raw_svc")
        [[ -z "$svc" ]] && continue
        if [[ "$bound_normalized" == *" $svc "* ]]; then
            healthy_services="${healthy_services}${svc}:"
        else
            fake_dead="${fake_dead}${svc}:"
        fi
    done

    healthy_services="${healthy_services%:}"
    fake_dead="${fake_dead%:}"

    if [[ -n "$fake_dead" ]]; then
        log "Fake-ON (zombie) service detected: '$fake_dead' is enabled in settings but not bound!"
        log "Triggering auto-rebind kick to revive zombie accessibility service(s)..."

        # Briefly toggle to force SettingsProvider change event
        if [[ -n "$healthy_services" ]]; then
            settings put secure enabled_accessibility_services "$healthy_services"
        else
            settings put secure enabled_accessibility_services ""
            settings put secure accessibility_enabled 0
        fi

        sleep 0.25

        # Restore full enabled services and re-enable accessibility master switch
        settings put secure enabled_accessibility_services "$current_enabled"
        settings put secure accessibility_enabled 1

        log "Auto-rebind executed successfully for '$current_enabled'"
    fi
}

# Startup initialization
if [[ ! -s "$WATCHLIST" ]]; then
    sync_live_to_watchlist
    log "Initialized watchlist with active services"
else
    repair_database
    log "Verified saved watchlist on startup"
fi

# Startup health check for fake-on services
check_and_heal_fake_active

log "Initialized watchdog daemon (PID: $$)"

# Note: Toybox grep does not support (and doesn't need) --line-buffered
logcat -b events -b main -b system -T 1 | \
grep -E "accessibility event occurred|Accessibility volume enabled|AccessibilityContentObserver|ActivityManager: Force stopping|ActivityManager: Background started FGS|android\.intent\.action\.USER_PRESENT" | \
while read -r _; do
    if is_settings_focused; then
        sync_live_to_watchlist
    else
        repair_database
        check_and_heal_fake_active
    fi
done
