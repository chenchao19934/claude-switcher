"""Widget shared-summary validation; no App Group, signing or network access."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SCENARIOS = (
    "valid_round_trip", "schema_and_fields", "malformed_and_size", "account_privacy",
    "unknown_account", "phase_allowlist", "count_total", "count_range_and_types",
    "timestamp_boundaries", "stale_boundary", "unchecked_and_pending",
    "skipped_is_not_passed", "failure_is_not_passed", "phase_is_historical",
    "unavailable_is_not_passed",
    "timeline_schedules_expiration", "timeline_expiration_boundary", "timeline_waiting_has_no_past_date",
)


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("swiftc"),
                     "WidgetKit model tests require macOS and swiftc")
class WidgetModelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        trash = PROJECT / "_trash"
        trash.mkdir(exist_ok=True)
        cls.build = tempfile.TemporaryDirectory(prefix="widget-model-tests-", dir=trash)
        cls.addClassCleanup(cls.build.cleanup)
        cls.binary = Path(cls.build.name) / "WidgetModelTests"
        result = subprocess.run(
            ["swiftc", "-parse-as-library", "-warnings-as-errors", "-D", "STATUS_WIDGET_TESTS",
             "-target", f"{platform.machine()}-apple-macos13.0",
             "-module-cache-path", str(Path(cls.build.name) / "module-cache"),
             str(PROJECT / "app/StatusWidget.swift"),
             str(PROJECT / "tests/WidgetModelTests.swift"),
             "-o", str(cls.binary), "-framework", "SwiftUI", "-framework", "WidgetKit"],
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
    setattr(WidgetModelTests, f"test_{scenario}", scenario_test(scenario))
