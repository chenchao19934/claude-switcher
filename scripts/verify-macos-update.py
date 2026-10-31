#!/usr/bin/env python3
"""Verify a CI-built update ZIP through the real client, without network/install."""
import importlib.util
import json
from pathlib import Path
import re
import shutil
import sys
import tempfile


def main():
    if len(sys.argv) != 2:
        raise SystemExit("用法: verify-macos-update.py <update.zip>")
    archive = Path(sys.argv[1]).resolve(strict=True)
    match = re.fullmatch(r"ClaudeSwitcher-([0-9]+\.[0-9]+\.[0-9]+)-macos-(arm64|x86_64)-update\.zip", archive.name)
    if not match:
        raise SystemExit("更新包文件名无效")
    version, arch = match.groups()
    root = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location("desktop_update", root / "core/desktop-update.py")
    updater = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(updater)
    manifest = (updater.digest(archive) + "  " + archive.name + "\n").encode()
    base = "https://github.com/" + updater.REPOSITORY + "/releases/download/v" + version + "/"
    metadata = {"tag_name": "v" + version, "draft": False, "prerelease": False, "assets": [
        {"name": archive.name, "size": archive.stat().st_size, "browser_download_url": base + archive.name},
        {"name": "SHA256SUMS-release.txt", "size": len(manifest),
         "browser_download_url": base + "SHA256SUMS-release.txt"},
    ]}

    class LocalPackageBackend(updater.Backend):
        def download(self, url, target, limit):
            if url.endswith("/releases/latest"):
                target.write_text(json.dumps(metadata), encoding="utf-8")
            elif url == base + "SHA256SUMS-release.txt":
                target.write_bytes(manifest)
            elif url == base + archive.name:
                shutil.copyfile(archive, target)
            else:
                raise RuntimeError("产物验收禁止真实联网")

    with tempfile.TemporaryDirectory(prefix="claude-release-verify-") as temporary:
        checked, package, entries = LocalPackageBackend().fetch(Path(temporary).resolve())
        if checked != version or set(entries) != updater.REQUIRED | {"daemons/" + name for name in updater.DAEMON_FILES}:
            raise SystemExit("版本或完整更新工件不匹配")
        binary = package / "Claude切换器.app/Contents/MacOS/ClaudeSwitcher"
        if updater.macho_architectures(binary) != {arch}:
            raise SystemExit("更新包架构与文件名不匹配")
        if (package / "core/desktop-update.py").read_bytes() != (root / "core/desktop-update.py").read_bytes():
            raise SystemExit("产物更新组件与当前源码不匹配")
    print("更新包客户端验收通过：版本、UTF-8 路径、SHA256、架构、执行权限与签名")


if __name__ == "__main__":
    main()
