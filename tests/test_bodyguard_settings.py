"""Root-helper transactions using temporary files and a fake launchctl only."""
import contextlib
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "daemons/bodyguard-settings.py"
SPEC = importlib.util.spec_from_file_location("bodyguard_settings", SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FakeLaunchd:
    def __init__(self, plist):
        self.plist = plist
        self.registered = True
        self.interval = 10
        self.calls = []
        self.failures = {}
        self.print_values = []

    def __call__(self, arguments, **options):
        assert arguments[0] == "/bin/launchctl"
        assert options["timeout"] == 15 and options["env"]["LC_ALL"] == "C"
        self.calls.append(arguments)
        command = arguments[1]
        outcomes = self.failures.get(command, [])
        outcome = outcomes.pop(0) if outcomes else 0
        if isinstance(outcome, BaseException):
            raise outcome
        if outcome:
            return subprocess.CompletedProcess(arguments, outcome, "", "synthetic-private-detail")
        if command == "print":
            if not self.registered:
                return subprocess.CompletedProcess(arguments, 113, "", "not registered")
            interval = self.print_values.pop(0) if self.print_values else self.interval
            text = "state = waiting\n" if interval is None else "run interval = %s seconds\n" % interval
            return subprocess.CompletedProcess(arguments, 0, text, "")
        if command == "bootout":
            assert arguments == ["/bin/launchctl", "bootout", MODULE.SERVICE]
            self.registered = False
        elif command == "bootstrap":
            assert arguments == ["/bin/launchctl", "bootstrap", "system", str(self.plist)]
            self.interval = plistlib.loads(self.plist.read_bytes())["StartInterval"]
            self.registered = True
        else:
            raise AssertionError("unexpected launchctl command")
        return subprocess.CompletedProcess(arguments, 0, "", "")


class BodyguardSettingsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="bodyguard-settings-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.managed = self.root / "managed"
        self.daemons = self.root / "launchdaemons"
        self.managed.mkdir(mode=0o755)
        self.daemons.mkdir(mode=0o755)
        self.guard = self.managed / "claude-bodyguard.sh"
        self.helper = self.managed / "bodyguard-settings.py"
        for file in [self.guard, self.helper]:
            file.write_text("fixture only\n")
            file.chmod(0o755)
        self.plist = self.daemons / "local.claude-bodyguard.plist"
        self.config = {"Label": MODULE.LABEL, "ProgramArguments": ["/bin/bash", str(self.guard)],
                       "RunAtLoad": True, "StartInterval": 10}
        self.original = plistlib.dumps(self.config).replace(b"<dict>", b"<!-- original fixture -->\n<dict>", 1)
        self.plist.write_bytes(self.original)
        self.plist.chmod(0o644)
        self.launchd = FakeLaunchd(self.plist)
        self.settings = MODULE.BodyguardSettings(
            plist_path=self.plist, managed_dir=self.managed,
            expected_uid=os.geteuid(), expected_gid=os.getegid(), run=self.launchd)

    def test_status_legacy_throttle_default_and_runtime(self):
        self.assertEqual(self.settings.status(), {"interval": 10, "throttleInterval": 10,
                                                 "registered": True, "activeInterval": 10})
        self.assertEqual(self.plist.read_bytes(), self.original)
        self.assertEqual([call[1] for call in self.launchd.calls], ["print"])

    def test_status_unknown_runtime_never_uses_disk_as_active(self):
        self.launchd.print_values = [None]
        status = self.settings.status()
        self.assertTrue(status["registered"])
        self.assertIsNone(status["activeInterval"])
        self.assertIn("未能验证", status["message"])
        self.launchd.registered = False
        self.assertFalse(self.settings.status()["registered"])

    def test_status_reports_throttle_mismatch(self):
        self.plist.write_bytes(plistlib.dumps(dict(self.config, ThrottleInterval=8)))
        status = self.settings.status()
        self.assertEqual(status["interval"], 10)
        self.assertEqual(status["activeInterval"], 10)
        self.assertEqual(status["throttleInterval"], 8)
        self.assertIn("节流周期不一致", status["message"])

    def test_concurrent_operation_is_rejected_without_waiting_or_launchctl(self):
        lock = self.managed / ".bodyguard-settings.lock"
        lock.touch(mode=0o600)
        with lock.open("r+b") as stream:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            try:
                with self.assertRaises(MODULE.SettingsError) as caught:
                    self.settings.apply(3)
                self.assertEqual(str(caught.exception), "已有巡检配置操作正在进行，请稍后重试")
                self.assertFalse(self.launchd.calls)
                self.assertEqual(self.plist.read_bytes(), self.original)
            finally:
                fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
        self.assertFalse(self.settings.apply(10)["changed"])

    def test_apply_updates_only_intervals_and_preserves_complete_backup(self):
        result = self.settings.apply(2)
        self.assertTrue(result["changed"])
        changed = plistlib.loads(self.plist.read_bytes())
        self.assertEqual(changed, dict(self.config, StartInterval=2, ThrottleInterval=2))
        self.assertEqual((self.managed / "bodyguard.plist.backup").read_bytes(), self.original)
        self.assertEqual(stat.S_IMODE((self.managed / "bodyguard.plist.backup").stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.plist.stat().st_mode), 0o644)
        self.assertEqual(self.guard.read_text(), "fixture only\n")
        self.assertEqual([call[1] for call in self.launchd.calls], ["print", "bootout", "bootstrap", "print"])

    def test_same_config_and_verified_runtime_is_noop(self):
        self.assertFalse(self.settings.apply(10)["changed"])
        self.assertEqual(self.plist.read_bytes(), self.original)
        self.assertFalse((self.managed / "bodyguard.plist.backup").exists())
        self.assertEqual([call[1] for call in self.launchd.calls], ["print"])

    def test_same_config_with_stale_runtime_is_reloaded(self):
        self.launchd.print_values = [8]
        self.assertTrue(self.settings.apply(10)["changed"])
        self.assertEqual(self.settings.status()["activeInterval"], 10)

    def test_apply_requires_registered_service_and_privilege(self):
        self.launchd.registered = False
        with self.assertRaises(MODULE.SettingsError):
            self.settings.apply(3)
        self.assertEqual([call[1] for call in self.launchd.calls], ["print"])
        self.assertEqual(self.plist.read_bytes(), self.original)
        with mock.patch.object(MODULE.os, "geteuid", return_value=os.geteuid() + 1):
            with self.assertRaises(MODULE.SettingsError):
                self.settings.apply(3)

    def test_rejects_invalid_interval_types_and_injection(self):
        for value in [0, 1, 11, -1, True, False, 2.0, None, "0", "1", "11", "2.5", "02", "+2", " 2", "2\n", "2;id", "$(id)"]:
            with self.subTest(value=value), self.assertRaises(MODULE.SettingsError):
                self.settings.apply(value)
        self.assertFalse(self.launchd.calls)
        for value in [2, 3, 10, "2", "10"]:
            self.assertEqual(MODULE.parse_interval(value), int(value))

    def test_rejects_symlink_files_and_directories(self):
        for path in [self.guard, self.helper, self.plist, self.managed, self.daemons]:
            with self.subTest(path=path.name):
                saved = path.with_name(path.name + ".real")
                path.rename(saved)
                path.symlink_to(saved, target_is_directory=saved.is_dir())
                try:
                    with self.assertRaises(MODULE.SettingsError):
                        self.settings.status()
                finally:
                    path.unlink()
                    saved.rename(path)
        self.assertFalse(self.launchd.calls)

    def test_rejects_writable_or_nonexecutable_installation(self):
        for path in [self.guard, self.helper, self.plist, self.managed, self.daemons]:
            with self.subTest(path=path.name):
                original_mode = stat.S_IMODE(path.stat().st_mode)
                path.chmod(original_mode | 0o020)
                try:
                    with self.assertRaises(MODULE.SettingsError):
                        self.settings.status()
                finally:
                    path.chmod(original_mode)
        self.guard.chmod(0o644)
        with self.assertRaises(MODULE.SettingsError):
            self.settings.status()
        self.assertFalse(self.launchd.calls)

    def test_rejects_wrong_owner_or_group(self):
        for key, value in [("expected_uid", os.geteuid() + 1), ("expected_gid", os.getegid() + 1)]:
            with self.subTest(key=key), mock.patch.object(self.settings, key, value):
                with self.assertRaises(MODULE.SettingsError):
                    self.settings.status()
        self.assertFalse(self.launchd.calls)

    def test_rejects_nonregular_plist_and_unsafe_layout(self):
        changes = [{"Label": "arbitrary"}, {"ProgramArguments": ["/bin/bash", "/tmp/unsafe"]},
                   {"Program": "/bin/sh"}, {"KeepAlive": True}, {"RunAtLoad": False},
                   {"StartInterval": "10"}, {"StartInterval": True}, {"ThrottleInterval": 2.5}]
        for change in changes:
            self.plist.write_bytes(plistlib.dumps(dict(self.config, **change)))
            with self.subTest(change=change), self.assertRaises(MODULE.SettingsError):
                self.settings.status()
        self.plist.unlink()
        self.plist.mkdir()
        with self.assertRaises(MODULE.SettingsError):
            self.settings.status()
        self.assertFalse(self.launchd.calls)

    def test_rejects_malformed_and_oversized_plist(self):
        for raw in [b"not a plist", b"x" * 65537]:
            self.plist.write_bytes(raw)
            with self.subTest(size=len(raw)), self.assertRaises(MODULE.SettingsError):
                self.settings.status()
        self.assertFalse(self.launchd.calls)

    def test_preparation_failure_never_stops_service(self):
        with mock.patch.object(self.settings, "_prepare", side_effect=OSError("synthetic-private-detail")):
            with self.assertRaises(MODULE.SettingsError) as caught:
                self.settings.apply(3)
        self.assertNotIn("private", str(caught.exception))
        self.assertEqual(self.plist.read_bytes(), self.original)
        self.assertTrue(self.launchd.registered)
        self.assertEqual([call[1] for call in self.launchd.calls], ["print"])

    def test_bootstrap_failure_restores_exact_old_plist_and_runtime(self):
        self.launchd.failures["bootstrap"] = [5, 0]
        with self.assertRaises(MODULE.SettingsError) as caught:
            self.settings.apply(3)
        self.assertTrue(caught.exception.rollback_recovered)
        self.assertEqual(self.plist.read_bytes(), self.original)
        self.assertTrue(self.launchd.registered)
        self.assertEqual(self.launchd.interval, 10)
        self.assertFalse(list(self.daemons.glob(".bodyguard-settings-*")))

    def test_verification_failure_and_interruption_roll_back(self):
        for interrupted in [False, True]:
            with self.subTest(interrupted=interrupted):
                self.launchd.print_values = [10, 7, 10] if not interrupted else []
                self.launchd.failures["bootstrap"] = [MODULE.SettingsError("操作已中断"), 0] if interrupted else []
                with self.assertRaises(MODULE.SettingsError) as caught:
                    self.settings.apply(4)
                self.assertTrue(caught.exception.rollback_recovered)
                self.assertEqual(self.plist.read_bytes(), self.original)
                self.assertEqual(self.launchd.interval, 10)

    def test_unrecoverable_failure_reports_unconfirmed_rollback(self):
        self.launchd.failures["bootstrap"] = [5, 5]
        with self.assertRaises(MODULE.SettingsError) as caught:
            self.settings.apply(3)
        self.assertFalse(caught.exception.rollback_recovered)
        self.assertIn("回滚未能确认", str(caught.exception))
        self.assertEqual(self.plist.read_bytes(), self.original)
        self.assertFalse(self.launchd.registered)
        with (self.managed / ".bodyguard-settings.lock").open("r+b") as stream:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(stream.fileno(), fcntl.LOCK_UN)

    def test_bootout_failure_recovers_old_service(self):
        self.launchd.failures["bootout"] = [5, 0]
        with self.assertRaises(MODULE.SettingsError) as caught:
            self.settings.apply(3)
        self.assertTrue(caught.exception.rollback_recovered)
        self.assertEqual(self.plist.read_bytes(), self.original)
        self.assertEqual(self.launchd.interval, 10)

    def test_cli_rejects_paths_environment_overrides_and_noninstalled_copy(self):
        for arguments in [[], ["status", "/tmp/other"], ["--plist", "/tmp/other"],
                          ["apply", "2;id"], ["apply", "2", "--root", "/tmp"], ["status"]]:
            output = io.StringIO()
            with self.subTest(arguments=arguments), contextlib.redirect_stdout(output), mock.patch.dict(os.environ, {"CLAUDE_SWITCHER_TEST_ROOT": str(self.root), "BODYGUARD_SETTINGS_PLIST": str(self.plist)}), mock.patch.object(MODULE, "BodyguardSettings") as constructor:
                result = MODULE.main(arguments)
            self.assertNotEqual(result, 0)
            self.assertIn("error", json.loads(output.getvalue()))
            constructor.assert_not_called()
        self.assertEqual(MODULE.PLIST_PATH, Path("/Library/LaunchDaemons/local.claude-bodyguard.plist"))
        self.assertEqual(MODULE.HELPER_PATH, Path("/Library/Application Support/claude-switcher/bodyguard-settings.py"))


if __name__ == "__main__":
    unittest.main()
