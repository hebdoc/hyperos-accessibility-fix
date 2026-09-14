#!/usr/bin/env python3
"""
Comprehensive test suite for hyperos-accessibility-fix logic and components.
Tests normalization, exclusion, settings focus detection, regex patterns,
watchlist sync, uninstalled package filtering, log rotation, and Fake-ON detection.
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
        r"ActivityManager: Background started FGS|"
        r"android\.intent\.action\.USER_PRESENT"
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

    def parse_bound_and_binding_services(self, dumpsys_a11y_output: str) -> set:
        """Emulate shell parsing:
        dumpsys accessibility 2>/dev/null | tr '\n' ' '
        extracting components inside Bound services:{...} and Binding services:{...}
        """
        bound = set()
        for pattern in (r"Bound services:\{([^}]*)\}", r"Binding services:\{([^}]*)\}"):
            match = re.search(pattern, dumpsys_a11y_output)
            if match:
                content = match.group(1).replace("\n", " ").replace(",", " ")
                for item in content.split():
                    item = item.strip()
                    if item:
                        bound.add(self.normalize_component(item))
        return bound

    def detect_fake_active_services(self, current_enabled_str: str, bound_set: set) -> tuple:
        """Detect services that are enabled in settings but not bound or binding."""
        healthy = []
        fake_dead = []
        for raw in current_enabled_str.split(":"):
            svc = self.normalize_component(raw)
            if not svc or self.is_excluded(svc):
                continue
            if svc in bound_set:
                healthy.append(svc)
            else:
                fake_dead.append(svc)
        return ":".join(healthy), ":".join(fake_dead)

    def test_component_normalization(self):
        """Test normalization of short vs long Android component names."""
        self.assertEqual(
            self.normalize_component("com.example.app/.MyService"),
            "com.example.app/com.example.app.MyService"
        )
        self.assertEqual(
            self.normalize_component("com.example.app/.sub.MyService"),
            "com.example.app/com.example.app.sub.MyService"
        )
        self.assertEqual(
            self.normalize_component("com.example.app/com.example.app.MyService"),
            "com.example.app/com.example.app.MyService"
        )
        self.assertEqual(
            self.normalize_component("com.example.app/org.other.MyService"),
            "com.example.app/org.other.MyService"
        )
        self.assertEqual(self.normalize_component(""), "")

    def test_exclusion_logic(self):
        """Verify that default and custom excluded services are properly identified, even in shorthand."""
        self.assertTrue(self.is_excluded("com.miui.screenshot/com.miui.screenshot.accessibility.ScreenshotAccessibilityService"))
        self.assertTrue(self.is_excluded("com.miui.screenshot/.accessibility.ScreenshotAccessibilityService"))
        self.assertFalse(self.is_excluded("com.github.user.app/.MyAccessibilityService"))

        custom = {"com.custom.app/com.custom.app.CustomService"}
        self.assertTrue(self.is_excluded("com.custom.app/.CustomService", custom))
        self.assertFalse(self.is_excluded("com.other.app/.OtherService", custom))

    def test_settings_focus_detection(self):
        """Test foreground Settings detection across Android versions and UI variations."""
        spa_dump = "  mCurrentFocus=Window{8b7d903 u0 com.android.settings/com.android.settings.spa.SpaActivity}"
        self.assertTrue(self.is_settings_focused(spa_dump))

        subsettings_dump = "  mCurrentFocus=Window{3f2a1b0 u0 com.android.settings/com.android.settings.SubSettings}"
        self.assertTrue(self.is_settings_focused(subsettings_dump))

        main_dump = "  mCurrentFocus=Window{633aa7f u0 com.android.settings/com.android.settings.MainSettings}"
        self.assertTrue(self.is_settings_focused(main_dump))

        a11y_dump = "  mCurrentFocus=Window{1234567 u0 com.android.settings/com.android.settings.Settings$AccessibilitySettingsActivity}"
        self.assertTrue(self.is_settings_focused(a11y_dump))

        sec_dump = "  mCurrentFocus=Window{9998887 u0 com.miui.securitycenter/com.miui.securityscan.MainActivity}"
        self.assertTrue(self.is_settings_focused(sec_dump))

        launcher_dump = "  mCurrentFocus=Window{4455667 u0 com.miui.home/com.miui.home.launcher.Launcher}"
        self.assertFalse(self.is_settings_focused(launcher_dump))

        focused_app_dump = (
            "  mCurrentFocus=null\n"
            "  mFocusedApp=AppWindowToken{abc1234 token=Token{...} com.android.settings/.SubSettings}"
        )
        self.assertTrue(self.is_settings_focused(focused_app_dump))

    def test_logcat_event_regex(self):
        """Test logcat regex matches all critical triggers including USER_PRESENT."""
        pattern = re.compile(self.LOGCAT_EVENT_REGEX)

        self.assertTrue(pattern.search("I ActivityManager: Force stopping com.urbandroid.lux appid=10415 user=0: LockScreenClean"))
        self.assertTrue(pattern.search("D AccessibilityContentObserver.onChange: enabled_accessibility_services changed"))
        self.assertTrue(pattern.search("V AccessibilityManagerService: accessibility event occurred in window"))
        self.assertTrue(pattern.search("I AccessibilityManagerService: Accessibility volume enabled"))
        self.assertTrue(pattern.search("I ActivityManager: Background started FGS: ..."))
        self.assertTrue(pattern.search("I ActivityManager: Sending non-protected broadcast android.intent.action.USER_PRESENT"))

        self.assertFalse(pattern.search("D ActivityManager: proc 1234 died"))
        self.assertFalse(pattern.search("I WindowManager: Relayout Window"))
        self.assertFalse(pattern.search("V SensorService: active connections"))

    def test_parse_bound_services(self):
        """Test parsing bound and binding services from dumpsys accessibility (single and multi-line)."""
        dump = (
            "User state[1]:\n"
            "  Bound services:{\n"
            "    com.example.app/.MyService,\n"
            "    org.autojs.autojs6/org.autojs.autojs6.service.AccessibilityService\n"
            "  }\n"
            "  Binding services:{com.pending.app/.InitService}\n"
            "  Crashed services:{com.crashed.app/.DeadService}\n"
        )
        bound = self.parse_bound_and_binding_services(dump)
        self.assertIn("com.example.app/com.example.app.MyService", bound)
        self.assertIn("org.autojs.autojs6/org.autojs.autojs6.service.AccessibilityService", bound)
        self.assertIn("com.pending.app/com.pending.app.InitService", bound)
        self.assertNotIn("com.crashed.app/com.crashed.app.DeadService", bound)

        # Single-line format (standard AOSP)
        single_line_dump = "  Bound services:{com.single.app/.Service1, com.single.app/.Service2}"
        bound_single = self.parse_bound_and_binding_services(single_line_dump)
        self.assertIn("com.single.app/com.single.app.Service1", bound_single)
        self.assertIn("com.single.app/com.single.app.Service2", bound_single)

    def test_detect_fake_active_services(self):
        """Test detection of zombie services that are enabled in settings but disconnected in Binder."""
        current_enabled = "com.alive.app/.AliveService:com.zombie.app/.ZombieService"
        bound_set = {"com.alive.app/com.alive.app.AliveService"}

        healthy, fake_dead = self.detect_fake_active_services(current_enabled, bound_set)

        self.assertEqual(healthy, "com.alive.app/com.alive.app.AliveService")
        self.assertEqual(fake_dead, "com.zombie.app/com.zombie.app.ZombieService")

    def test_watchlist_sync_disabling_all_services(self):
        """Verify that when a user disables all services in Settings, watchlist is properly cleared."""
        with tempfile.TemporaryDirectory() as tmpdir:
            watchlist_file = Path(tmpdir) / "a11y_watchlist.txt"
            watchlist_file.write_text("com.app.one/com.app.one.Service\ncom.app.two/com.app.two.Service\n")

            sync_cur = ""
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

            self.assertEqual(watchlist_file.read_text(), "")

    def test_repair_database_with_uninstalled_packages(self):
        """Verify that uninstalled packages are pruned and not restored."""
        with tempfile.TemporaryDirectory() as tmpdir:
            watchlist_file = Path(tmpdir) / "a11y_watchlist.txt"
            watchlist_file.write_text(
                "com.installed.app/com.installed.app.Service\n"
                "com.uninstalled.app/com.uninstalled.app.Service\n"
            )

            installed_packages = {"com.installed.app"}

            rep_cur = ""
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

            self.assertEqual(rep_new, "com.installed.app/com.installed.app.Service")
            self.assertEqual(watchlist_file.read_text().strip(), "com.installed.app/com.installed.app.Service")

    def test_log_rotation(self):
        """Verify log rotation logic properly truncates logs when exceeding limit."""
        with tempfile.TemporaryDirectory() as tmpdir:
            log_file = Path(tmpdir) / "test.log"
            lines = [f"Line {i}" for i in range(1, 201)]
            log_file.write_text("\n".join(lines) + "\n")

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
