"""macOS menu-bar regression tests. Only fake scripts under _trash are executed."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
SCENARIOS = (
    "startup_once", "multi_account_status", "first_use_cd_note", "legacy_status_fallback",
    "invalid_multi_account_status", "warnings_allowed", "skipped_optional_allowed", "settings_round_trip", "local_status_refresh", "fresh_audit", "failed_check",
    "incomplete_check", "duplicate_check", "duplicate_overwrite", "empty_check",
    "unknown_check_code", "empty_check_code", "nonzero_check", "timeout_check",
    "invalid_status", "nonzero_status", "switch_note_then_failure", "empty_switch",
    "nonzero_switch", "timeout_switch", "busy_guard", "fix_guard", "failed_fix",
    "checking_allows_quit", "hide_after_success", "reopen_cancels_hide",
    "window_lifecycle", "termination_guard",
    "panel_toggle_no_audit", "panel_menu_recheck", "panel_idle_deactivation", "panel_busy_deactivation",
    "panel_settings_recording_guard", "panel_child_sheet_guard", "panel_busy_close",
    "panel_url_open_only", "shortcut_preferences", "shortcut_invalid_rejected",
    "shortcut_press_gate", "panel_shortcut_protection", "panel_shortcut_busy_toggle",
    "bodyguard_status_validation", "bodyguard_invalid_interval", "bodyguard_apply_success",
    "bodyguard_cancel_preserves", "bodyguard_apply_unconfirmed", "bodyguard_operation_serialization",
    "bodyguard_vm_busy_denies", "bodyguard_apply_lifecycle",
    "bodyguard_search_operation_guard",
    "update_installed_version", "update_version_fetching_and_failure", "update_release_unavailable",
    "update_remote_version_validation",
    "update_check_readonly", "update_check_current", "update_check_errors", "update_cancel",
    "update_check_serialized", "update_success_restart", "update_prepare_failures", "update_apply_failure",
    "update_prepare_current", "update_operation_serialized", "update_busy_guard", "update_guard_application",
    "update_monitor_late_sample", "update_acknowledge", "update_missing_component",
    "monitor_healthy", "monitor_failure_recovery", "monitor_recovery_still_failed",
    "monitor_invalid_responses", "monitor_timeout", "monitor_busy_skip", "monitor_no_overlap",
    "monitor_late_sample", "monitor_hidden_timer_and_stop", "monitor_stop_discards_inflight",
    "monitor_wake", "monitor_guard_application", "monitor_guard_late_sample",
    "snapshot_status_semantics", "snapshot_privacy",
)


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("swiftc"),
                     "SwiftUI menu-bar tests require macOS and swiftc")
class MenuBarModelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        trash = PROJECT / "_trash"
        trash.mkdir(exist_ok=True)
        cls.build = tempfile.TemporaryDirectory(prefix="menu-bar-tests-", dir=trash)
        cls.addClassCleanup(cls.build.cleanup)
        cls.binary = Path(cls.build.name) / "MenuBarModelTests"
        result = subprocess.run(
            ["swiftc", "-parse-as-library", "-warnings-as-errors", "-D", "CLAUDE_SWITCHER_TESTS",
             "-target", f"{platform.machine()}-apple-macos13.0",
             "-module-cache-path", str(Path(cls.build.name) / "module-cache"),
             str(PROJECT / "app/main.swift"),
             str(PROJECT / "tests/MenuBarModelTests.swift"),
             "-o", str(cls.binary), "-framework", "SwiftUI", "-framework", "AppKit"],
            cwd=PROJECT, capture_output=True, text=True, timeout=180,
        )
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)


def scenario_test(name):
    def test(self):
        result = subprocess.run(
            [str(self.binary), name], cwd=PROJECT,
            capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"PASS {name}", result.stdout)
    return test


for scenario in SCENARIOS:
    setattr(MenuBarModelTests, f"test_{scenario}", scenario_test(scenario))
