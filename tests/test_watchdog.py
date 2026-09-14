#!/usr/bin/env python3
"""
Comprehensive test suite for hyperos-accessibility-fix logic and components.
Tests normalization, exclusion, settings focus detection, regex patterns,
watchlist sync, uninstalled package filtering, and log rotation.
"""

import os
import re
import tempfile
import unittest
from pathlib import Path


class TestWatchdogLogic(unittest.TestCase):
    """Test suite covering core shell functions and logic modeled for hyperos-accessibility-fix."""

    DEFAULT_EXCLUDE_SVC = "com.miui.screenshot/com.miui.screenshot.accessibility.ScreenshotAccessibilityService"
    SETTINGS_FOCUS_REGEX = r"com\.android\.settings|com\.miui\.securitycenter"
    LOGCAT_EVENT_REGEX = (
        r"accessibility event occurred|"
        r"Accessibility volume enabled|"
        r"AccessibilityContentObserver|"
        r"ActivityManager: Force stopping|"
        r"ActivityManager: Background started FGS"
    )

    def normalize_component(self, svc_str: str) -> str:
        """Emulate normalize_component in bash:
        if [[ "$svc_str" == */.* ]]; then
            package="${svc_str%%/*}"
            svc_str="$package/$package${svc_str#*/}"
        fi
        """
        svc_str = svc_str.strip()
        if not svc_str:
            return ""
        if "/" in svc_str:
            pkg, cls = svc_str.split("/", 1)
            if cls.startswith("."):
                return f"{pkg}/{pkg}{cls}"
        return svc_str

    def is_excluded(self, svc_str: str, custom_excludes=None) -> bool:
        """Check if normalized svc is excluded."""
        normalized = self.normalize_component(svc_str)
        if normalized == self.DEFAULT_EXCLUDE_SVC:
            return True
        if custom_excludes and normalized in custom_excludes:
            return True
        return False

    def is_settings_focused(self, dumpsys_output: str) -> bool:
        """Check if focused window or app matches settings or securitycenter."""
        for line in dumpsys_output.splitlines():
            if re.search(r"mCurrentFocus|mFocusedApp", line):
                if re.search(self.SETTINGS_FOCUS_REGEX, line):
                    return True
        return False

    def test_component_normalization(self):
        """Test normalization of short vs long Android component names."""
        # Standard shorthand
        self.assertEqual(
            self.normalize_component("com.example.app/.MyService"),
            "com.example.app/com.example.app.MyService"
        )
        # Deep package shorthand
        self.assertEqual(
            self.normalize_component("com.example.app/.sub.MyService"),
            "com.example.app/com.example.app.sub.MyService"
        )
        # Already fully qualified
        self.assertEqual(
            self.normalize_component("com.example.app/com.example.app.MyService"),
            "com.example.app/com.example.app.MyService"
        )
        # Fully qualified with different subpackage
        self.assertEqual(
            self.normalize_component("com.example.app/org.other.MyService"),
            "com.example.app/org.other.MyService"
        )
        # Empty string
        self.assertEqual(self.normalize_component(""), "")

    def test_exclusion_logic(self):
        """Verify that default and custom excluded services are properly identified, even in shorthand."""
        # Default screenshot service in full form
        self.assertTrue(self.is_excluded("com.miui.screenshot/com.miui.screenshot.accessibility.ScreenshotAccessibilityService"))
        
        # Default screenshot service in shorthand form (the bug in previous versions!)
        self.assertTrue(self.is_excluded("com.miui.screenshot/.accessibility.ScreenshotAccessibilityService"))

        # Non-excluded service
        self.assertFalse(self.is_excluded("com.github.user.app/.MyAccessibilityService"))

        # Custom excluded service
        custom = {"com.custom.app/com.custom.app.CustomService"}
        self.assertTrue(self.is_excluded("com.custom.app/.CustomService", custom))
        self.assertFalse(self.is_excluded("com.other.app/.OtherService", custom))

    def test_settings_focus_detection(self):
        """Test foreground Settings detection across Android versions and UI variations."""
        # Android 14 Settings SPA
        spa_dump = "  mCurrentFocus=Window{8b7d903 u0 com.android.settings/com.android.settings.spa.SpaActivity}"
        self.assertTrue(self.is_settings_focused(spa_dump))

        # HyperOS SubSettings
        subsettings_dump = "  mCurrentFocus=Window{3f2a1b0 u0 com.android.settings/com.android.settings.SubSettings}"
        self.assertTrue(self.is_settings_focused(subsettings_dump))

        # HyperOS MainSettings
        main_dump = "  mCurrentFocus=Window{633aa7f u0 com.android.settings/com.android.settings.MainSettings}"
        self.assertTrue(self.is_settings_focused(main_dump))

        # HyperOS AccessibilitySettingsActivity
        a11y_dump = "  mCurrentFocus=Window{1234567 u0 com.android.settings/com.android.settings.Settings$AccessibilitySettingsActivity}"
        self.assertTrue(self.is_settings_focused(a11y_dump))

        # MIUI Security Center
        sec_dump = "  mCurrentFocus=Window{9998887 u0 com.miui.securitycenter/com.miui.securityscan.MainActivity}"
        self.assertTrue(self.is_settings_focused(sec_dump))

        # Non-settings app (e.g. Chrome or Home Launcher)
        launcher_dump = "  mCurrentFocus=Window{4455667 u0 com.miui.home/com.miui.home.launcher.Launcher}"
        self.assertFalse(self.is_settings_focused(launcher_dump))

        # Test mFocusedApp fallback
        focused_app_dump = (
            "  mCurrentFocus=null\n"
            "  mFocusedApp=AppWindowToken{abc1234 token=Token{...} com.android.settings/.SubSettings}"
        )
        self.assertTrue(self.is_settings_focused(focused_app_dump))

    def test_logcat_event_regex(self):
        """Test logcat regex matches all critical triggers without false positives."""
        pattern = re.compile(self.LOGCAT_EVENT_REGEX)

        # Triggers
        self.assertTrue(pattern.search("I ActivityManager: Force stopping com.urbandroid.lux appid=10415 user=0: LockScreenClean"))
        self.assertTrue(pattern.search("D AccessibilityContentObserver.onChange: enabled_accessibility_services changed"))
        self.assertTrue(pattern.search("V AccessibilityManagerService: accessibility event occurred in window"))
        self.assertTrue(pattern.search("I AccessibilityManagerService: Accessibility volume enabled"))
        self.assertTrue(pattern.search("I ActivityManager: Background started FGS: ..."))

        # Non-triggers
        self.assertFalse(pattern.search("D ActivityManager: proc 1234 died"))
        self.assertFalse(pattern.search("I WindowManager: Relayout Window"))
        self.assertFalse(pattern.search("V SensorService: active connections"))

    def test_watchlist_sync_disabling_all_services(self):
        """Verify that when a user disables all services in Settings, watchlist is properly cleared."""
        # Simulate watchlist file
        with tempfile.TemporaryDirectory() as tmpdir:
            watchlist_file = Path(tmpdir) / "a11y_watchlist.txt"
            watchlist_file.write_text("com.app.one/com.app.one.Service\ncom.app.two/com.app.two.Service\n")

            # Emulate sync_live_to_watchlist with empty live services (user turned off all services in Settings)
            sync_cur = ""  # get_services returned empty
            sync_active = ""
            if sync_cur:
                for item in sync_cur.split(":"):
                    if "/" in item:
                        sync_active += item + "\n"

            current_watchlist = watchlist_file.read_text() if watchlist_file.exists() else ""
            new_watchlist = "\n".join(sorted(sync_active.strip().split("\n"))) if sync_active else ""

            if current_watchlist != new_watchlist:
                if new_watchlist:
                    watchlist_file.write_text(new_watchlist + "\n")
                else:
                    watchlist_file.write_text("")

            # Watchlist should now be empty!
            self.assertEqual(watchlist_file.read_text(), "")

    def test_repair_database_with_uninstalled_packages(self):
        """Verify that uninstalled packages are pruned and not restored."""
        with tempfile.TemporaryDirectory() as tmpdir:
            watchlist_file = Path(tmpdir) / "a11y_watchlist.txt"
            watchlist_file.write_text(
                "com.installed.app/com.installed.app.Service\n"
                "com.uninstalled.app/com.uninstalled.app.Service\n"
            )

            # Mock pm path: installed returns True, uninstalled returns False
            installed_packages = {"com.installed.app"}

            rep_cur = ""  # Currently 0 services enabled due to HyperOS wipe
            rep_seen = set()
            rep_new_list = []
            cleaned_watchlist = []
            watchlist_modified = False

            for line in watchlist_file.read_text().splitlines():
                svc = self.normalize_component(line)
                if not svc or self.is_excluded(svc):
                    continue
                pkg = svc.split("/", 1)[0]
                if pkg not in installed_packages:
                    watchlist_modified = True
                    continue
                cleaned_watchlist.append(svc)
                if svc not in rep_seen:
                    rep_new_list.append(svc)
                    rep_seen.add(svc)

            if watchlist_modified:
                watchlist_file.write_text("\n".join(sorted(cleaned_watchlist)) + "\n")

            rep_new = ":".join(rep_new_list)

            # rep_new should only contain the installed app
            self.assertEqual(rep_new, "com.installed.app/com.installed.app.Service")
            # watchlist should be updated to purge the uninstalled app
            self.assertEqual(watchlist_file.read_text().strip(), "com.installed.app/com.installed.app.Service")

    def test_log_rotation(self):
        """Verify log rotation logic properly truncates logs when exceeding limit."""
        with tempfile.TemporaryDirectory() as tmpdir:
            log_file = Path(tmpdir) / "test.log"
            # Write 200 lines
            lines = [f"Line {i}" for i in range(1, 201)]
            log_file.write_text("\n".join(lines) + "\n")

            # Emulate rotation: if > 150 lines, keep last 80
            file_lines = log_file.read_text().splitlines()
            if len(file_lines) > 150:
                retained = file_lines[-80:]
                log_file.write_text("\n".join(retained) + "\n")

            remaining_lines = log_file.read_text().splitlines()
            self.assertEqual(len(remaining_lines), 80)
            self.assertEqual(remaining_lines[0], "Line 121")
            self.assertEqual(remaining_lines[-1], "Line 200")


if __name__ == "__main__":
    unittest.main()
