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

# Ensure MODPATH is resolved accurately in KernelSU / Magisk / terminal
MODDIR="${0%/*}"
if [[ -z "$MODDIR" || "$MODDIR" == "." || "$MODDIR" == "action.sh" ]]; then
    MODDIR="/data/adb/modules/hyperos-accessibility-fix"
fi
MODPATH="${MODPATH:-$MODDIR}"

LOGFILE="/tmp/a11y_watchdog.log"
PIDFILE="/tmp/a11y_watchdog.pid"
MODPROP="$MODPATH/module.prop"
WATCHLIST="$MODPATH/a11y_watchlist.txt"
EXCLUDE_FILE="$MODPATH/a11y_exclude.txt"
SCRIPTDIR="$MODPATH/scripts"

MODULENAME=$(grep '^name=' "$MODPROP" 2>/dev/null | cut -d'=' -f2)
VERSION=$(grep '^version=' "$MODPROP" 2>/dev/null | cut -d'=' -f2)
[[ -z "$MODULENAME" ]] && MODULENAME="HyperOS accessibility fix"
[[ -z "$VERSION" ]] && VERSION="1.0.8"

echo "========================================="
echo " $MODULENAME v$VERSION"
echo "========================================="

# Ensure PATH contains standard Android system binaries
export PATH="/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH:/system/bin:/system/xbin:/vendor/bin:/apex/com.android.runtime/bin"

# Pure shell /proc search to avoid awk / pgrep dependencies
find_pids_by_cmd() {
    local target="$1"
    local pids=""
    for p in /proc/[0-9]*; do
        if [[ -f "$p/cmdline" ]] && grep -Fq "$target" "$p/cmdline" 2>/dev/null; then
            local pid="${p#/proc/}"
            if [[ "$pid" != "$$" ]]; then
                pids="${pids}${pid} "
            fi
        fi
    done
    printf '%s' "${pids% }"
}

get_system_services() {
    local svcs=""
    svcs=$(settings get --user 0 secure enabled_accessibility_services 2>/dev/null)
    if [[ -z "$svcs" || "$svcs" == "null" ]]; then
        svcs=$(settings get secure enabled_accessibility_services 2>/dev/null)
    fi
    if [[ -z "$svcs" || "$svcs" == "null" ]]; then
        svcs=$(dumpsys accessibility 2>/dev/null | grep -E "Enabled services:\{" | sed -e 's/.*services:{//' -e 's/}.*//' -e 's/, */:/g' | tr -d ' ')
    fi
    [[ "$svcs" == "null" ]] && svcs=""
    printf '%s' "$svcs"
}

get_package_pids() {
    local pkg="$1"
    [[ -z "$pkg" ]] && return
    local pids=""

    pids=$(pidof "$pkg" 2>/dev/null)

    if [[ -z "$pids" ]]; then
        pids=$(pgrep -f "^${pkg}" 2>/dev/null | tr '\n' ' ')
    fi

    if [[ -z "$pids" ]]; then
        pids=$(ps -A 2>/dev/null | grep -F "$pkg" | awk '{print $2}' | tr '\n' ' ')
        [[ -z "$pids" ]] && pids=$(ps 2>/dev/null | grep -F "$pkg" | awk '{print $2}' | tr '\n' ' ')
    fi

    if [[ -z "$pids" ]]; then
        for p in /proc/[0-9]*; do
            if [[ -f "$p/cmdline" ]] && grep -Fq "$pkg" "$p/cmdline" 2>/dev/null; then
                local pid="${p#/proc/}"
                pids="${pids}${pid} "
            fi
        done
    fi

    printf '%s' "${pids% }"
}

is_package_running() {
    local pkg="$1"
    local pids
    pids=$(get_package_pids "$pkg")
    [[ -n "$pids" ]]
}

# 1. Check Watchdog Process Status
WATCHDOG_PID=""
if [[ -f "$PIDFILE" ]]; then
    read -r WATCHDOG_PID < "$PIDFILE" 2>/dev/null
fi

if [[ -z "$WATCHDOG_PID" ]] || ! kill -0 "$WATCHDOG_PID" 2>/dev/null; then
    WATCHDOG_PID=$(find_pids_by_cmd "a11y_watchdog.sh")
fi

STATUS_STR=""
if [[ -n "$WATCHDOG_PID" ]] && kill -0 "$WATCHDOG_PID" 2>/dev/null; then
    OOM_SCORE=$(cat "/proc/$WATCHDOG_PID/oom_score_adj" 2>/dev/null || echo "N/A")
    echo "[+] 守护进程 (Watchdog): 正在运行 (PID: $WATCHDOG_PID, oom: $OOM_SCORE)"
    STATUS_STR="[🟢守护运行中 PID: $WATCHDOG_PID]"
else
    echo "[-] 守护进程 (Watchdog): 未在运行"
    echo "    正在尝试重启守护进程..."
    setsid /system/bin/sh "$SCRIPTDIR/a11y_watchdog.sh" "$MODPATH" "$LOGFILE" > /dev/null 2>&1 < /dev/null &
    sleep 0.5
    if [[ -f "$PIDFILE" ]]; then
        read -r NEW_PID < "$PIDFILE" 2>/dev/null
        if [[ -n "$NEW_PID" ]] && kill -0 "$NEW_PID" 2>/dev/null; then
            echo "[+] 守护进程已成功恢复运行 (PID: $NEW_PID)"
            WATCHDOG_PID="$NEW_PID"
            STATUS_STR="[🟢守护已恢复 PID: $NEW_PID]"
        else
            echo "[-] 重启失败，请检查运行环境或日志。"
            STATUS_STR="[🔴未运行 重启失败]"
        fi
    else
        STATUS_STR="[🔴未运行]"
    fi
fi

# 2. Check Monitor Daemon Status
MONITOR_PIDS=$(find_pids_by_cmd "a11y_watchdog_monitor.sh")
if [[ -n "$MONITOR_PIDS" ]]; then
    echo "[+] 监控进程 (Monitor):  正在运行 (PID: $MONITOR_PIDS)"
else
    echo "[-] 监控进程 (Monitor):  未在运行"
    echo "    正在拉起监控进程..."
    setsid /system/bin/sh "$SCRIPTDIR/a11y_watchdog_monitor.sh" "$MODPATH" > /dev/null 2>&1 < /dev/null &
fi

echo "-----------------------------------------"

# 3. Handle Command Argument Actions (sync, restore, clear, heal)
ACTION="$1"
case "$ACTION" in
    sync)
        echo "[*] 触发手动同步：正在将当前系统启用的服务写入白名单..."
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
            echo "[+] 白名单已同步，共 $(wc -l < "$WATCHLIST") 个服务。"
        else
            : > "$WATCHLIST"
            echo "[*] 白名单已清空（当前系统无开启的无障碍服务）。"
        fi
        ;;
    restore)
        echo "[*] 触发手动恢复：正在从白名单恢复无障碍服务..."
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
                echo "[+] 恢复成功: $rep_list"
            fi
        else
            echo "[-] 白名单为空，无需恢复。"
        fi
        ;;
    heal)
        echo "[*] 触发无障碍服务重连与复活..."
        CURR_SVCS=$(settings get secure enabled_accessibility_services 2>/dev/null)
        if [[ -n "$CURR_SVCS" && "$CURR_SVCS" != "null" ]]; then
            settings put secure enabled_accessibility_services ""
            settings put secure accessibility_enabled 0
            sleep 0.3
            settings put secure enabled_accessibility_services "$CURR_SVCS"
            settings put secure accessibility_enabled 1
            echo "[+] 已触发系统底层重新连接！"
        else
            echo "[-] 当前系统无开启的无障碍服务。"
        fi
        ;;
    clear)
        echo "[*] 正在清空白名单..."
        : > "$WATCHLIST"
        echo "[+] 白名单已清空。"
        ;;
esac

# 4. Check Process Status for Enabled & Guarded Services
echo "🛡️ 无障碍服务守护与实时运行状态:"

SYSTEM_SVCS=$(get_system_services)

# Build a unified list of unique services from both system settings and watchlist
ALL_TRACKED=""
SEEN_SVCS=""

# Add from system settings
if [[ -n "$SYSTEM_SVCS" ]]; then
    for s in ${SYSTEM_SVCS//:/ }; do
        norm_s="$s"
        if [[ "$norm_s" == */.* ]]; then
            pkg="${norm_s%%/*}"
            norm_s="$pkg/$pkg${norm_s#*/}"
        fi
        if [[ "$SEEN_SVCS" != *":$norm_s:"* ]]; then
            ALL_TRACKED="${ALL_TRACKED}${norm_s} "
            SEEN_SVCS="${SEEN_SVCS}:$norm_s:"
        fi
    done
fi

# Add from watchlist file
if [[ -s "$WATCHLIST" ]]; then
    while IFS= read -r w || [[ -n "$w" ]]; do
        w="${w%$'\r'}"
        [[ -z "$w" ]] && continue
        norm_w="$w"
        if [[ "$norm_w" == */.* ]]; then
            pkg="${norm_w%%/*}"
            norm_w="$pkg/$pkg${norm_w#*/}"
        fi
        if [[ "$SEEN_SVCS" != *":$norm_w:"* ]]; then
            ALL_TRACKED="${ALL_TRACKED}${norm_w} "
            SEEN_SVCS="${SEEN_SVCS}:$norm_w:"
        fi
    done < "$WATCHLIST"
fi

has_dead=0
has_unlinked=0

if [[ -z "$ALL_TRACKED" ]]; then
    echo "  (暂未检测到任何开启或受守护的无障碍服务)"
    echo "  [提示] 请先在手机【设置 -> 无障碍】中开启需要的服务（如李跳跳）。"
    echo "         开启后，本模块会自动将其锁定加入白名单并开启实时守护！"
else
    idx=1
    for svc in $ALL_TRACKED; do
        pkg="${svc%%/*}"
        pids=$(get_package_pids "$pkg")

        echo "  [$idx] 应用: $pkg"
        echo "      组件: $svc"

        # Check in system settings
        if [[ ":$SYSTEM_SVCS:" == *":$svc:"* || ":$SYSTEM_SVCS:" == *":${svc##*/}:"* || ( -n "$SYSTEM_SVCS" && "$SYSTEM_SVCS" == *"$pkg"* ) ]]; then
            echo "      系统开关: [🟢已在系统开启]"
        else
            echo "      系统开关: [🔴系统设置未开启或被强关 - 正在触发恢复]"
            has_unlinked=1
        fi

        # Check in watchlist
        if [[ -s "$WATCHLIST" ]] && grep -Fq "$pkg" "$WATCHLIST" 2>/dev/null; then
            echo "      守护名单: [🛡️白名单受守护]"
        else
            echo "      守护名单: [⚠️未在白名单 (可在设置中重新开关以同步)]"
        fi

        # Check process liveness
        if [[ -n "$pids" ]]; then
            echo "      后台进程: [🟢活跃运行中 (PID: $pids)]"
        else
            echo "      后台进程: [🔴进程已死亡 - 正在执行唤醒重连]"
            has_dead=1
        fi
        echo ""
        (( idx++ ))
    done

    # If any service is dead or unlinked from settings, trigger healing kick
    if (( has_dead == 1 || has_unlinked == 1 )); then
        echo "[*] 检测到有服务掉线或进程死亡，正在下发系统唤醒与重连指令..."
        if [[ -s "$WATCHLIST" ]]; then
            rep_list=""
            while IFS= read -r item || [[ -n "$item" ]]; do
                item="${item%$'\r'}"
                [[ -z "$item" ]] && continue
                rep_list="${rep_list}${item}:"
            done < "$WATCHLIST"
            rep_list="${rep_list%:}"
            if [[ -n "$rep_list" ]]; then
                settings put secure enabled_accessibility_services ""
                settings put secure accessibility_enabled 0
                sleep 0.3
                settings put secure enabled_accessibility_services "$rep_list"
                settings put secure accessibility_enabled 1
                echo "[+] 已从白名单成功恢复并唤醒全部无障碍服务！"
            fi
        fi
    fi
fi

# 5. Update module.prop description dynamically so status is visible in Manager list
if [[ -f "$MODPROP" ]]; then
    BASE_DESC="防HyperOS强关与后台被杀 | 点击操作查看状态与日志"
    sed -i "s|^description=.*|description=$STATUS_STR $BASE_DESC|" "$MODPROP" 2>/dev/null
fi

echo ""
echo "白名单持久化保存的服务 (Watchlist):"
if [[ -s "$WATCHLIST" ]]; then
    while IFS= read -r w || [[ -n "$w" ]]; do
        w="${w%$'\r'}"
        [[ -n "$w" ]] && echo "  * $w"
    done < "$WATCHLIST"
else
    echo "  (空)"
fi

if [[ -s "$EXCLUDE_FILE" ]]; then
    echo ""
    echo "自定义排除的服务 (Exclude List):"
    while IFS= read -r e || [[ -n "$e" ]]; do
        e="${e%$'\r'}"
        [[ -n "$e" ]] && echo "  x $e"
    done < "$EXCLUDE_FILE"
fi

echo "-----------------------------------------"
echo "最近运行日志 (最新 20 条):"
if [[ -f "$LOGFILE" ]]; then
    tail -n 20 "$LOGFILE"
else
    echo "  (未找到日志文件 $LOGFILE)"
fi
echo "========================================="

# 6. Countdown pause so KernelSU dialog remains visible for reading
if [[ -z "$ACTION" ]]; then
    echo ""
    echo "[提示] 窗口将在 10 秒后自动关闭，以便查看报告..."
    count=10
    while (( count > 0 )); do
        printf "\r[*] 剩余停留时间: %2d 秒 (可直接点按外部区域关闭)" "$count"
        sleep 1
        (( count-- ))
    done
    echo ""
fi

exit 0
