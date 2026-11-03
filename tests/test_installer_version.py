"""Installer version metadata uses temporary packages and never installs an App."""
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = (ROOT / "installer/安装.command").read_text(encoding="utf-8")
PACKAGE = (ROOT / "scripts/package-macos.sh").read_text(encoding="utf-8")


class InstallerVersionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="installer-version-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source checkout"
        self.source.mkdir()
        self.app = self.root / "temporary.app"
        (self.app / "Contents").mkdir(parents=True)
        self.env = dict(os.environ, APP=str(self.app), APP_VERSION="1.2.0",
                        APP_SOURCE_SHA="fixture-source", APP_ICON_SHA="fixture-icon")

    def version_function(self):
        match = re.search(r"(?ms)^installer_version\(\) \{\n.*?^\}", INSTALLER)
        self.assertIsNotNone(match, "installer must parse its own package version")
        return match.group(0)

    def read_version(self):
        return subprocess.run(
            ["/bin/bash", "-c", self.version_function() + '\ninstaller_version "$REPO"'],
            env=dict(self.env, REPO=str(self.source), HOME=str(self.root / "isolated home")),
            capture_output=True, text=True, timeout=5)

    def write_plist(self):
        start = INSTALLER.index('cat > "$APP/Contents/Info.plist" <<EOF\n')
        end = INSTALLER.index("\nEOF", start) + len("\nEOF")
        result = subprocess.run(["/bin/bash", "-c", INSTALLER[start:end]],
                                env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return plistlib.loads((self.app / "Contents/Info.plist").read_bytes())

    def make_kit(self, version="1.2.0"):
        # Only the installer-kit fragment runs, with a small fake source tree.
        # No compiler, signing, network, system configuration or installer runs.
        files = (
            "README.md", "README.en.md", "AGENTS.md", "SECURITY.md", "LICENSE", "SHA256SUMS",
            "core/claude-switch.sh", "core/stun-probe.py", "core/desktop-update.py",
            "daemons/claude-bodyguard.sh", "daemons/tz-watchdog.sh", "daemons/bodyguard-settings.py",
            "installer/安装.command", "installer/卸载.command", "app/main.swift",
            "scripts/build-macos-widget.sh", "scripts/package-macos.sh", "scripts/verify-macos-update.py",
            "assets/icon-2048.png", "docs/MACOS-WIDGET.md", "docs/MACOS-UPDATES.md",
            "docs/screenshot.png", "docs/images/macos-background-polling.png",
        )
        for relative in files:
            path = self.source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fixture\n")
        fakebin = self.root / "bin"
        fakebin.mkdir()
        ditto = fakebin / "ditto"
        ditto.write_text(
            "#!" + sys.executable + "\n"
            "from pathlib import Path\nimport shutil, sys, zipfile\n"
            "source, target = map(Path, sys.argv[-2:])\n"
            "if '-c' in sys.argv:\n"
            "    with zipfile.ZipFile(target, 'w') as archive:\n"
            "        for path in source.rglob('*'):\n"
            "            archive.write(path, path.relative_to(source.parent).as_posix())\n"
            "else:\n"
            "    shutil.copytree(source, target)\n", encoding="utf-8")
        ditto.chmod(0o755)
        archive = self.root / "installer-kit.zip"
        work = self.root / "work"
        work.mkdir()
        env = dict(self.env, ROOT=str(self.source), WORK=str(work), VERSION=version,
                   KIT_NAME="ClaudeSwitcher-" + version, KIT_ZIP=str(archive),
                   PATH=str(fakebin) + os.pathsep + os.defpath)
        start = PACKAGE.index('echo "==> 生成 installer kit"')
        end = PACKAGE.index('\necho ""', start)
        result = subprocess.run(["/bin/bash", "-c", "set -euo pipefail\n" + PACKAGE[start:end]],
                                env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return archive

    def test_installer_app_version_fields_match_package_version(self):
        info = self.write_plist()
        self.assertEqual(info["CFBundleShortVersionString"], "1.2.0")
        self.assertEqual(info["CFBundleVersion"], "1.2.0")

    def test_installer_kit_contains_version_at_its_root(self):
        archive = self.make_kit()
        with zipfile.ZipFile(archive) as package:
            self.assertEqual(package.read("ClaudeSwitcher-1.2.0/VERSION"), b"1.2.0\n")

    def test_kit_version_reaches_both_installer_app_fields(self):
        archive = self.make_kit()
        with zipfile.ZipFile(archive) as package:
            package.extract("ClaudeSwitcher-1.2.0/VERSION", self.root / "unpacked")
        self.source = self.root / "unpacked/ClaudeSwitcher-1.2.0"
        result = self.read_version()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.env["APP_VERSION"] = result.stdout.strip()
        info = self.write_plist()
        self.assertEqual(info["CFBundleShortVersionString"], "1.2.0")
        self.assertEqual(info["CFBundleVersion"], "1.2.0")

    def test_checkout_without_version_is_explicitly_development(self):
        result = self.read_version()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "0.0.0-dev")
        self.env["APP_VERSION"] = result.stdout.strip()
        info = self.write_plist()
        self.assertEqual(info["CFBundleShortVersionString"], "0.0.0-dev")
        self.assertEqual(info["CFBundleVersion"], "0.0.0-dev")

    def test_valid_package_versions_are_preserved(self):
        for value in ("0.0.0", "1.2.0", "12.34.56", "0.0.0-dev", "1.2.0-beta.1"):
            with self.subTest(value=value):
                (self.source / "VERSION").write_text(value + "\n", encoding="ascii")
                result = self.read_version()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), value)

    def test_invalid_or_oversized_version_is_rejected_without_execution(self):
        marker = self.root / "must-not-exist"
        for value in ("", "v1.2.0", "1.2", "01.2.0", "1.02.0", "1.2.00", "1.2.0\n9.9.9",
                      "1.2.0\x00", "1.2.0<bad>", "1.2.0-" + "x" * 81,
                      "1.2.0$(touch '" + str(marker) + "')"):
            with self.subTest(value=value):
                (self.source / "VERSION").write_text(value, encoding="utf-8")
                result = self.read_version()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertFalse(marker.exists())

    def test_non_regular_version_files_are_rejected(self):
        path = self.source / "VERSION"
        target = self.root / "target-version"
        target.write_text("1.2.0\n", encoding="ascii")
        for kind in ("symlink", "dangling-symlink", "directory", "fifo"):
            with self.subTest(kind=kind):
                if kind == "symlink":
                    path.symlink_to(target)
                elif kind == "dangling-symlink":
                    path.symlink_to(self.root / "absent")
                elif kind == "directory":
                    path.mkdir()
                else:
                    os.mkfifo(path)
                try:
                    result = self.read_version()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, "")
                finally:
                    path.rmdir() if kind == "directory" else path.unlink()

    def test_invalid_version_stops_before_installation_writes(self):
        (self.source / "VERSION").write_text("invalid\n", encoding="ascii")
        match = re.search(r'(?ms)^if ! APP_VERSION=\$\(installer_version "\$REPO"\); then\n.*?^fi', INSTALLER)
        self.assertIsNotNone(match)
        self.assertLess(INSTALLER.index(match.group(0)), INSTALLER.index("# ---- 3. 安装文件"))
        result = subprocess.run(
            ["/bin/bash", "-c", self.version_function() + "\n" + match.group(0)
             + '\nprintf unexpected > "$FIXTURE/must-not-write"'],
            env=dict(self.env, REPO=str(self.source), FIXTURE=str(self.root)),
            capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("已停止安装", result.stdout)
        self.assertFalse((self.root / "must-not-write").exists())


if __name__ == "__main__":
    unittest.main()
