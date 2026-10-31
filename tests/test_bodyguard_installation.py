"""Installer fragments run only with temporary paths and fake privileged commands."""
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "installer/安装.command"
MANAGED = "/Library/Application Support/claude-switcher"
DAEMONS = "/Library/LaunchDaemons"
HELPERS = ("claude-bodyguard.sh", "tz-watchdog.sh", "bodyguard-settings.py")
PLISTS = ("local.claude-bodyguard.plist", "local.tz-watchdog.plist")


class BodyguardInstallationTests(unittest.TestCase):
    def setUp(self):
        # Explicit /tmp avoids an unquoted replacement of LaunchDaemons acquiring
        # spaces. Managed, HOME and staging paths deliberately contain spaces.
        self.temporary = tempfile.TemporaryDirectory(prefix="bodyguard-install-", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / "fake home"
        self.stage = self.root / "fake stage"
        self.managed = self.root / "Application Support/claude-switcher"
        self.daemons = self.root / "LaunchDaemons"
        self.stage.mkdir()
        self.daemons.mkdir()
        (self.home / ".local/bin").mkdir(parents=True)
        for name in HELPERS:
            shutil.copyfile(ROOT / "daemons" / name, self.stage / name)
        for name in PLISTS:
            shutil.copyfile(ROOT / "daemons" / name, self.home / ".local/bin" / name)
        self.source = INSTALLER.read_text(encoding="utf-8")

    def initial_commands(self):
        # Stop before curt/readlink and the real timezone/IPv6 additions. Only
        # evaluate a string assignment here; none of its command text is run.
        matches = re.findall(r'(?ms)^    (SYSCMDS="if .*?)\n    curt=', self.source)
        self.assertEqual(len(matches), 1, "expected one initial system-command assignment")
        assignment = matches[0]
        self.assertTrue(assignment.endswith('"'))
        self.assertNotIn("$(", assignment)
        self.assertNotIn("`", assignment)
        result = subprocess.run(
            ["/bin/bash", "-c", "set -u\n" + assignment + '\nprintf "%s" "$SYSCMDS"'],
            env={"PATH": os.defpath, "H": str(self.home), "STAGE": str(self.stage),
                 "guard_file": "SHOULD_NOT_EXPAND_WHILE_ASSIGNING", "LC_ALL": "C"},
            capture_output=True, text=True, encoding="utf-8", timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def run_commands(self):
        commands = self.initial_commands()
        self.assertIn(MANAGED, commands)
        self.assertIn(DAEMONS, commands)
        commands = commands.replace(MANAGED, str(self.managed)).replace(DAEMONS, str(self.daemons))
        self.assertNotIn("/Library/", commands, "refuse to execute any unredirected system path")
        for forbidden in ("sudo", "systemsetup", "networksetup", "dscacheutil", "killall", "readlink"):
            self.assertNotIn(forbidden, commands)
        # cp/chmod/mkdir/rm operate on redirected temporary paths only. Never
        # execute chown or launchctl, even when the tests happen to run as root.
        mocks = 'chown() { return 0; }; launchctl() { return 0; };\n'
        return subprocess.run(
            ["/bin/bash", "-c", mocks + commands],
            env={"PATH": os.defpath, "HOME": str(self.home), "LC_ALL": "C"},
            capture_output=True, text=True, encoding="utf-8", timeout=5,
        )

    def test_rejects_symlink_managed_directory_without_writing_outside(self):
        outside = self.root / "outside"
        outside.mkdir()
        marker = outside / "unchanged"
        marker.write_bytes(b"original")
        self.managed.parent.mkdir()
        self.managed.symlink_to(outside, target_is_directory=True)
        result = self.run_commands()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("拒绝符号链接系统目录", result.stdout)
        self.assertEqual(list(outside.iterdir()), [marker])
        self.assertEqual(marker.read_bytes(), b"original")
        self.assertEqual(list(self.daemons.iterdir()), [])

    def test_rejects_symlink_helper_without_overwriting_outside(self):
        self.managed.mkdir(parents=True)
        outside = self.root / "outside-helper"
        outside.write_bytes(b"must survive")
        (self.managed / "bodyguard-settings.py").symlink_to(outside)
        result = self.run_commands()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("拒绝符号链接守护文件", result.stdout)
        self.assertEqual(outside.read_bytes(), b"must survive")
        self.assertFalse((self.managed / "claude-bodyguard.sh").exists())
        self.assertEqual(list(self.daemons.iterdir()), [])

    def test_copies_helpers_with_executable_mode_and_unchanged_contents(self):
        original_guard = (ROOT / "daemons/claude-bodyguard.sh").read_bytes()
        result = self.run_commands()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(stat.S_IMODE(self.managed.stat().st_mode), 0o755)
        for name in HELPERS:
            with self.subTest(helper=name):
                destination = self.managed / name
                self.assertFalse(destination.is_symlink())
                self.assertEqual(destination.read_bytes(), (self.stage / name).read_bytes())
                self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o755)
        for name in PLISTS:
            with self.subTest(plist=name):
                destination = self.daemons / name
                self.assertEqual(destination.read_bytes(), (self.home / ".local/bin" / name).read_bytes())
                self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o644)
        self.assertEqual((ROOT / "daemons/claude-bodyguard.sh").read_bytes(), original_guard)

    def test_helper_loop_variable_is_preserved_and_quoted_for_spaces(self):
        commands = self.initial_commands()
        self.assertIn('"' + MANAGED + '/$guard_file"', commands)
        self.assertNotIn("SHOULD_NOT_EXPAND_WHILE_ASSIGNING", commands)
        self.assertIn("for guard_file in claude-bodyguard.sh tz-watchdog.sh bodyguard-settings.py", commands)


class BodyguardReinstallationIntervalTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="bodyguard-reinstall-", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "previous.plist"
        self.target = self.root / "new.plist"
        self.template = (ROOT / "daemons/local.claude-bodyguard.plist").read_bytes()
        installer = INSTALLER.read_text(encoding="utf-8")
        matches = re.findall(
            r"(?s)# 重装时保留[^\n]*\n/usr/bin/python3[^\n]* <<'PY'\n(.*?)\nPY\n", installer)
        self.assertEqual(len(matches), 1)
        original_source = "source = Path('/Library/LaunchDaemons/local.claude-bodyguard.plist')"
        self.assertEqual(matches[0].count(original_source), 1)
        self.code = matches[0].replace(original_source, "source = Path(" + repr(str(self.source)) + ")")
        self.assertNotIn("Path('/Library/", self.code)
        self.previous = plistlib.loads(self.template)
        self.previous.update(StartInterval=5, ThrottleInterval=5)

    def run_preservation(self, config=None, trusted=True):
        self.target.write_bytes(self.template)
        if not self.source.is_symlink():
            self.source.write_bytes(plistlib.dumps(self.previous if config is None else config))
            self.source.chmod(0o644)
        actual_lstat = Path.lstat

        def root_metadata(path, *args, **kwargs):
            metadata = actual_lstat(path, *args, **kwargs)
            if path == self.source:
                return SimpleNamespace(st_mode=metadata.st_mode, st_uid=0 if trusted else 501, st_gid=0)
            return metadata

        # The one source path and argv target are temporary. Mock only ownership
        # metadata; O_NOFOLLOW still opens the actual fixture and rejects links.
        with mock.patch.object(Path, "lstat", root_metadata), mock.patch.object(sys, "argv", ["-", str(self.target)]):
            exec(compile(self.code, "installer-interval-fixture", "exec"), {"__name__": "__main__"})
        return plistlib.loads(self.target.read_bytes())

    def test_preserves_trusted_five_second_interval(self):
        current = self.run_preservation()
        self.assertEqual(current["StartInterval"], 5)
        self.assertEqual(current["ThrottleInterval"], 5)
        expected = plistlib.loads(self.template)
        expected.update(StartInterval=5, ThrottleInterval=5)
        self.assertEqual(current, expected)

    def test_invalid_intervals_keep_ten_second_template(self):
        for interval in (None, True, False, 0, 1, 11, "5", 5.0):
            with self.subTest(interval=interval):
                config = dict(self.previous, StartInterval=interval)
                if interval is None:
                    del config["StartInterval"]
                self.run_preservation(config)
                self.assertEqual(self.target.read_bytes(), self.template)

    def test_wrong_label_or_program_arguments_keep_template(self):
        for change in ({"Label": "another.service"},
                       {"ProgramArguments": ["/bin/bash", "/tmp/untrusted.sh"]},
                       {"ProgramArguments": ["/bin/bash", MANAGED + "/claude-bodyguard.sh", "extra"]}):
            with self.subTest(change=change):
                self.run_preservation(dict(self.previous, **change))
                self.assertEqual(self.target.read_bytes(), self.template)

    def test_symlink_previous_configuration_keeps_template(self):
        outside = self.root / "outside.plist"
        original = plistlib.dumps(self.previous)
        outside.write_bytes(original)
        self.source.symlink_to(outside)
        self.run_preservation()
        self.assertEqual(self.target.read_bytes(), self.template)
        self.assertEqual(outside.read_bytes(), original)

    def test_untrusted_owner_keeps_template(self):
        self.run_preservation(trusted=False)
        self.assertEqual(self.target.read_bytes(), self.template)


if __name__ == "__main__":
    unittest.main()
