"""Core update integration using fake GitHub/curl and an isolated HOME."""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = "1.2.3"
TAG = "v" + VERSION
REPOSITORY = "chenchao19934/claude-switcher"
KEYS = ("代理内核", "TUN网卡", "出口IP", "IP一致", "时区", "地区", "IPv6", "DNS",
        "WebRTC", "保镖", "规则置顶", "客户端语言", "ASN属性", "生态可达性")
CONFIG = ('PROXY_MODE="clash-verge"\nPROXY_GROUP="IpEqual"\nCOUNTRY_TARGET="US"\n'
          'TZ_TARGET="America/New_York"\nLOCALE_TARGET="en_US"\n')


class CoreUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="core-update-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.home = self.root / "home"
        self.bin = self.home / ".local/bin"
        self.bin.mkdir(parents=True)
        self.base = self.home / ".claude-switcher"
        self.core = self.bin / "claude-switch.sh"
        self.original = (ROOT / "core/claude-switch.sh").read_bytes()
        self.core.write_bytes(self.original)
        self.core.chmod(0o755)
        self.fakebin = self.root / "fakebin"
        self.fakebin.mkdir()
        self.calls = self.root / "calls.jsonl"
        self.env = {key: value for key, value in os.environ.items()
                    if key.lower() not in ("http_proxy", "https_proxy", "all_proxy", "no_proxy")}
        self.env.update(HOME=str(self.home), PATH=str(self.fakebin) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                        CLAUDE_SWITCHER_PYTHON=sys.executable, UPDATE_FIXTURE=str(self.root))
        self.stub("curl", '''import json, os, shutil, sys, time
from pathlib import Path
root = Path(os.environ["UPDATE_FIXTURE"])
args = sys.argv[1:]
url = args[-1]
with (root / "calls.jsonl").open("a") as handle:
    handle.write(json.dumps({"url": url, "args": args, "http_proxy": os.environ.get("http_proxy"),
                            "https_proxy": os.environ.get("https_proxy"), "HTTPS_PROXY": os.environ.get("HTTPS_PROXY")}) + "\\n")
if os.environ.get("UPDATE_DELAY"):
    time.sleep(float(os.environ["UPDATE_DELAY"]))
code = int(os.environ.get("UPDATE_CURL_RC", "0"))
if code:
    print(os.environ.get("UPDATE_ERROR_STATUS", "503"), end="")
    print("synthetic private proxy details", file=sys.stderr)
    sys.exit(code)
name = "release.json" if url.endswith("/releases/latest") else ("SHA256SUMS-release.txt" if url.endswith("/SHA256SUMS-release.txt") else "source.zip")
shutil.copyfile(root / name, args[args.index("--output") + 1])
print(os.environ.get("UPDATE_HTTP_STATUS", "200"), end="")
''')
        self.stub("scutil", '''import os
from pathlib import Path
root = Path(os.environ["UPDATE_FIXTURE"])
(root / "scutil-called").write_text("called")
print("<dictionary> {\\n  HTTPEnable : 1\\n  HTTPProxy : 127.0.0.1\\n  HTTPPort : 19191\\n}")
''')
        self.stub("uname", 'import os\nprint(os.environ.get("UPDATE_ARCH", "' + os.uname().machine + '"))\n')
        self.stub("open", 'import os\nfrom pathlib import Path\n(Path(os.environ["UPDATE_FIXTURE"]) / "claude-opened").touch()\n')
        self.package()

    def stub(self, name, script):
        path = self.fakebin / name
        path.write_text("#!" + sys.executable + " -B\n" + script)
        path.chmod(0o755)

    def package(self, audit=None, exit_code=0, manifest_changes=None, extra_zip=None, core=None, version_value=VERSION):
        if audit is None:
            audit = "\n".join(key + "=ok" for key in KEYS)
        remote_core = ("#!/bin/bash\n" + CONFIG + "if [ \"${1:-}\" = checkdetail ]; then\n"
                       + 'printf "%s\\n" checkdetail >> "$UPDATE_FIXTURE/environment-called"\n'
                       + "cat <<'AUDIT'\n" + audit + "\nAUDIT\nexit " + str(exit_code)
                       + "\nfi\nexit 2\n").encode()
        self.artifacts = {"core/claude-switch.sh": core if core is not None else remote_core,
                          "core/stun-probe.py": b"# new stun\n", "core/desktop-update.py": b"# new helper\n",
                          "daemons/claude-bodyguard.sh": b"# guard __HOME__ __PROXY_MODE__\n",
                          "daemons/tz-watchdog.sh": b"# watchdog __HOME__ __TZ_TARGET__\n",
                          "daemons/bodyguard-settings.py": b"# settings\n"}
        manifest = {name: hashlib.sha256(value).hexdigest() for name, value in self.artifacts.items()}
        if manifest_changes:
            manifest_changes(manifest)
        text = "".join(checksum + "  " + name + "\n" for name, checksum in manifest.items())
        (self.root / "SHA256SUMS").write_text(text)
        with zipfile.ZipFile(self.root / "source.zip", "w") as archive:
            for name, value in self.artifacts.items():
                archive.writestr(name, value)
            archive.writestr("SHA256SUMS", text)
            archive.writestr("VERSION", version_value + "\n")
            archive.writestr("Claude切换器.app/Contents/MacOS/ClaudeSwitcher", b"precompiled fixture")
            if extra_zip:
                extra_zip(archive)
        self.archive_name = "ClaudeSwitcher-" + VERSION + "-macos-" + self.env.get("UPDATE_ARCH", os.uname().machine) + "-update.zip"
        self.external_manifest()
        assets = [{"name": name, "browser_download_url": "https://github.com/" + REPOSITORY + "/releases/download/" + TAG + "/" + name}
                  for name in (self.archive_name, "SHA256SUMS-release.txt")]
        (self.root / "release.json").write_text(json.dumps({"tag_name": TAG, "draft": False, "prerelease": False, "assets": assets}))

    def external_manifest(self):
        checksum = hashlib.sha256((self.root / "source.zip").read_bytes()).hexdigest()
        (self.root / "SHA256SUMS-release.txt").write_text(checksum + "  " + self.archive_name + "\n")

    def snapshot(self):
        return {str(path.relative_to(self.home)): (stat.S_IMODE(path.stat().st_mode), path.stat().st_mtime_ns,
                                                   path.read_bytes() if path.is_file() else None)
                for path in self.home.rglob("*")}

    def run_update(self, *arguments):
        return subprocess.run(["/bin/bash", str(self.core), *arguments], env=self.env,
                              capture_output=True, text=True, timeout=15)

    def old_helpers(self):
        self.base.mkdir(exist_ok=True)
        for name in ("stun-probe.py", "desktop-update.py"):
            (self.base / name).write_bytes(("# old " + name + "\n").encode())

    def test_check_is_read_only_and_uses_only_exact_formal_release_assets(self):
        for arguments in (("update-check",), ("update", "--check")):
            with self.subTest(arguments=arguments):
                before = self.snapshot()
                result = self.run_update(*arguments)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(before, self.snapshot())
                self.assertFalse(self.base.exists())
                self.assertIn("发现新版", result.stdout)
                self.assertIn("不更换 App", result.stdout)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        for call in calls:
            self.assertIn("chenchao19934/claude-switcher", call["url"])
            self.assertIn("-fLsS", call["args"])
            self.assertIn("--retry", call["args"])
            if not call["url"].endswith("/releases/latest"):
                self.assertIn("/releases/download/" + TAG + "/", call["url"])
            self.assertNotIn("/main", call["url"])
            self.assertNotIn("codeload", call["url"])
            self.assertNotIn("raw.githubusercontent", call["url"])

    def test_system_proxy_fallback_is_used_without_logging_details(self):
        result = self.run_update("update-check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / "scutil-called").exists())
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertTrue(all(call["https_proxy"] == "http://127.0.0.1:19191" for call in calls))
        self.assertNotIn("127.0.0.1", result.stdout + result.stderr)

    def test_existing_environment_proxy_takes_precedence(self):
        self.env["HTTPS_PROXY"] = "http://synthetic-proxy.invalid:18080"
        result = self.run_update("update-check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "scutil-called").exists())
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertTrue(all(call["HTTPS_PROXY"] == self.env["HTTPS_PROXY"] for call in calls))
        self.assertNotIn("synthetic-proxy", result.stdout + result.stderr)

    def test_http_only_environment_proxy_is_normalized_without_overriding_https_or_all(self):
        original_env = dict(self.env)
        for http_key in ("http_proxy", "HTTP_PROXY"):
            for secure_key in (None, "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"):
                with self.subTest(http_key=http_key, secure_key=secure_key):
                    self.env = dict(original_env)
                    self.env[http_key] = "http://synthetic-http.invalid:18080"
                    if secure_key:
                        self.env[secure_key] = "http://synthetic-secure.invalid:18443"
                    self.calls.unlink(missing_ok=True)
                    before = self.snapshot()
                    result = self.run_update("update-check")
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(before, self.snapshot())
                    self.assertFalse((self.root / "scutil-called").exists())
                    calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
                    expected = (self.env[http_key] if secure_key is None else
                                self.env[secure_key] if secure_key == "https_proxy" else None)
                    self.assertTrue(all(call["https_proxy"] == expected for call in calls))
                    self.assertNotIn("synthetic-", result.stdout + result.stderr)

    def test_download_errors_are_classified_without_raw_stderr(self):
        for code, message in ((22, "HTTP 503"), (60, "TLS"), (28, "超时")):
            self.env["UPDATE_CURL_RC"] = str(code)
            before = self.snapshot()
            result = self.run_update("update-check")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stdout)
            self.assertNotIn("private proxy", result.stdout + result.stderr)
            self.assertEqual(before, self.snapshot())

    def test_invalid_release_tag_and_archive_are_rejected(self):
        metadata = json.loads((self.root / "release.json").read_text())
        metadata["tag_name"] = "main"
        (self.root / "release.json").write_text(json.dumps(metadata))
        result = self.run_update("update-check")
        self.assertIn("标签", result.stdout)
        self.assertNotEqual(result.returncode, 0)
        self.package()
        (self.root / "source.zip").write_bytes(b"not-a-zip")
        self.external_manifest()
        result = self.run_update("update-check")
        self.assertIn("解压失败", result.stdout)
        self.assertNotEqual(result.returncode, 0)

    def test_manifest_must_cover_all_required_artifacts(self):
        for missing in self.artifacts:
            with self.subTest(missing=missing):
                self.package(manifest_changes=lambda manifest: manifest.pop(missing))
                result = self.run_update("update-check")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("缺少必需工件", result.stdout)

    def test_unsafe_duplicate_and_mismatched_manifest_are_rejected(self):
        for text, message in (("/escape", "不安全路径"), ("../escape", "不安全路径"),
                              ("core/../escape", "不安全路径")):
            self.package()
            with (self.root / "SHA256SUMS-release.txt").open("a") as handle:
                handle.write("0" * 64 + "  " + text + "\n")
            result = self.run_update("update-check")
            self.assertIn(message, result.stdout)
            self.assertNotEqual(result.returncode, 0)
        self.package()
        with (self.root / "SHA256SUMS-release.txt").open("a") as handle:
            handle.write((self.root / "SHA256SUMS-release.txt").read_text().splitlines()[0] + "\n")
        self.assertIn("重复项", self.run_update("update-check").stdout)
        self.package(manifest_changes=lambda manifest: manifest.__setitem__("core/stun-probe.py", "0" * 64))
        self.assertIn("SHA256", self.run_update("update-check").stdout)

    def test_archive_rejects_traversal_and_symlinks(self):
        def symlink(archive):
            info = zipfile.ZipInfo("core/linked")
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(info, "../escape")
        for extra in (lambda archive: archive.writestr("../escape", "unsafe"), symlink):
            self.package(extra_zip=extra)
            result = self.run_update("update-check")
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((self.root / "escape").exists())

    def test_update_replaces_and_backs_up_all_three_artifacts(self):
        self.old_helpers()
        previous = {path: path.read_bytes() for path in (self.core, self.base / "stun-probe.py", self.base / "desktop-update.py")}
        result = self.run_update("update")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for path, before in previous.items():
            self.assertEqual(Path(str(path) + ".bak").read_bytes(), before)
        self.assertEqual((self.base / "stun-probe.py").read_bytes(), self.artifacts["core/stun-probe.py"])
        self.assertEqual((self.base / "desktop-update.py").read_bytes(), self.artifacts["core/desktop-update.py"])
        self.assertFalse((self.base / ".update.lock").exists())

    def test_configuration_is_preserved_as_literal_source_lines(self):
        special = r'PROXY_GROUP="a&b|c\\d/\$value\`touch ignored\`\"quote"'
        original = self.original.decode().replace('PROXY_GROUP="IpEqual"          # Clash 代理组名(安装时自动探测)', special)
        self.core.write_text(original)
        self.assertIn(special, original)
        result = self.run_update("update")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(special + "\n", self.core.read_text())
        self.assertFalse((self.home / "ignored").exists())

    def test_environment_results_do_not_gate_core_updates_or_launch_claude(self):
        cases = (("\n".join(key + "=ok" for key in KEYS[:-1]), 0),
                 ("\n".join(key + "=ok" for key in KEYS) + "\nTUN网卡=ok", 0),
                 ("\n".join(key + "=fail" for key in KEYS), 0),
                 ("\n".join(key + "=ok" for key in KEYS), 7),
                 ("", 2))
        for audit, code in cases:
            with self.subTest(code=code, audit=audit[-30:]):
                self.core.write_bytes(self.original)
                self.old_helpers()
                self.package(audit=audit, exit_code=code)
                result = self.run_update("update")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((self.base / "stun-probe.py").read_bytes(), self.artifacts["core/stun-probe.py"])
                self.assertEqual((self.base / "desktop-update.py").read_bytes(), self.artifacts["core/desktop-update.py"])
                self.assertFalse((self.root / "environment-called").exists(), "升级不得执行环境checkdetail")
                self.assertFalse((self.root / "claude-opened").exists(), "升级不得启动Claude")
                self.assertFalse((self.base / ".update.lock").exists())

    def test_existing_lock_is_not_removed_and_parallel_updates_are_refused(self):
        self.base.mkdir()
        lock = self.base / ".update.lock"
        lock.mkdir(mode=0o700)
        (lock / "nonce").write_text("unknown\n")
        result = self.run_update("update")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((lock / "nonce").read_text(), "unknown\n")
        (lock / "nonce").unlink(); lock.rmdir()
        env = dict(self.env, UPDATE_DELAY="0.3")
        first = subprocess.Popen(["/bin/bash", str(self.core), "update"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: first.poll() is None and first.kill())
        limit = time.time() + 4
        while not (lock / "nonce").exists() and time.time() < limit:
            time.sleep(0.01)
        self.assertTrue((lock / "nonce").exists())
        self.assertEqual(stat.S_IMODE((lock / "nonce").stat().st_mode), 0o600)
        second = self.run_update("update")
        self.assertNotEqual(second.returncode, 0)
        self.assertIn("更新锁", second.stdout)
        out, err = first.communicate(timeout=10)
        self.assertEqual(first.returncode, 0, out + err)
        self.assertFalse(lock.exists())

    def test_auto_logs_results_without_changing_invocation_contract(self):
        self.old_helpers()
        result = self.run_update("update", "--auto")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertIn("更新完成", (self.base / "update.log").read_text())
        self.assertFalse((self.base / "accounts").exists())
        self.assertFalse((self.base / ".update.lock").exists())

    def test_check_detects_companion_changes_even_when_core_is_identical(self):
        self.package(core=self.original)
        self.old_helpers()
        before = self.snapshot()
        result = self.run_update("update-check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("发现新版", result.stdout)
        self.assertEqual(before, self.snapshot())
        for name in ("stun-probe.py", "desktop-update.py"):
            (self.base / name).write_bytes(self.artifacts["core/" + name])
        before = self.snapshot()
        result = self.run_update("update-check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("已与正式 Release", result.stdout)
        self.assertEqual(before, self.snapshot())

    def test_interrupted_update_releases_its_own_lock(self):
        env = dict(self.env, UPDATE_DELAY="0.3")
        process = subprocess.Popen(["/bin/bash", str(self.core), "update"], env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        lock = self.base / ".update.lock"
        limit = time.time() + 4
        while not (lock / "nonce").exists() and time.time() < limit:
            time.sleep(0.01)
        self.assertTrue((lock / "nonce").exists())
        process.terminate()
        out, err = process.communicate(timeout=10)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("更新已中断", out)
        self.assertFalse(lock.exists())
        self.assertEqual(self.core.read_bytes(), self.original)

    def updater_wrapper(self, body):
        launcher = self.root / "wrapped-updater"
        launcher.write_text("#!" + sys.executable + " -B\nimport os, sys\nfrom pathlib import Path\n"
                            + body + "\nsource = sys.stdin.read()\nsys.argv = ['-'] + sys.argv[4:]\n"
                            + "exec(compile(source, '<isolated updater>', 'exec'))\n")
        launcher.chmod(0o755)
        self.env["CLAUDE_SWITCHER_PYTHON"] = str(launcher)

    def test_write_failure_restores_all_existing_artifacts(self):
        self.old_helpers()
        previous = {path: path.read_bytes() for path in (self.core, self.base / "stun-probe.py", self.base / "desktop-update.py")}
        self.updater_wrapper("""original_replace = os.replace
failed = False
def failing_replace(source, destination):
    global failed
    if Path(destination).name == 'desktop-update.py' and not failed:
        failed = True
        raise OSError('synthetic replacement failure')
    return original_replace(source, destination)
os.replace = failing_replace""")
        result = self.run_update("update")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("回滚全部工件", result.stdout)
        for path, original in previous.items():
            self.assertEqual(path.read_bytes(), original)
        self.assertFalse((self.base / ".update.lock").exists())
        self.assertFalse((self.root / "environment-called").exists())

    def test_installed_byte_or_permission_corruption_rolls_back_all_artifacts(self):
        for mutation in ("bytes", "permissions"):
            with self.subTest(mutation=mutation):
                self.core.write_bytes(self.original)
                self.old_helpers()
                previous = {path: (path.read_bytes(), stat.S_IMODE(path.stat().st_mode))
                            for path in (self.core, self.base / "stun-probe.py", self.base / "desktop-update.py")}
                operation = ("core.write_bytes(core.read_bytes() + b'# synthetic corruption\\n')" if mutation == "bytes"
                             else "core.chmod(0o644)")
                self.updater_wrapper("""original_replace = os.replace
changed = False
def corrupting_replace(source, destination):
    global changed
    result = original_replace(source, destination)
    if Path(destination).name == 'desktop-update.py' and not changed:
        changed = True
        core = Path(os.environ['HOME']) / '.local/bin/claude-switch.sh'
        """ + operation + """
    return result
os.replace = corrupting_replace""")
                result = self.run_update("update")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("回滚全部工件", result.stdout)
                for path, (original, mode) in previous.items():
                    self.assertEqual(path.read_bytes(), original)
                    self.assertEqual(stat.S_IMODE(path.stat().st_mode), mode)
                self.assertFalse((self.root / "environment-called").exists())

    def test_syntax_invalid_candidate_is_rejected_before_backups(self):
        self.package(core=("#!/bin/bash\n" + CONFIG + "if [; then\n").encode())
        result = self.run_update("update")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("语法检查失败", result.stdout)
        self.assertEqual(self.core.read_bytes(), self.original)
        self.assertFalse(Path(str(self.core) + ".bak").exists())
        self.assertFalse((self.base / ".update.lock").exists())

    def test_symlinked_state_directory_is_rejected_without_writing_target(self):
        target = self.root / "outside"
        target.mkdir()
        self.base.symlink_to(target, target_is_directory=True)
        result = self.run_update("update")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("符号链接", result.stdout)
        self.assertEqual(list(target.iterdir()), [])

    def test_only_http_200_download_responses_are_accepted(self):
        self.env["UPDATE_HTTP_STATUS"] = "206"
        result = self.run_update("update-check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HTTP 200", result.stdout)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        for call in calls:
            self.assertIn("--proto", call["args"])
            self.assertIn("--proto-redir", call["args"])
            self.assertIn("--max-filesize", call["args"])

    def test_partial_lock_initialization_failure_cleans_only_own_files(self):
        launcher = self.root / "python-fail-nonce"
        launcher.write_text("#!" + sys.executable + " -B\n" + """import os, sys
original_open = os.open
def interrupted_open(path, *args, **kwargs):
    if str(path).endswith('/.update.lock/nonce'):
        raise OSError('synthetic nonce creation failure')
    return original_open(path, *args, **kwargs)
os.open = interrupted_open
source = sys.stdin.read()
sys.argv = ['-'] + sys.argv[4:]
exec(compile(source, '<isolated updater>', 'exec'))
""")
        launcher.chmod(0o755)
        self.env["CLAUDE_SWITCHER_PYTHON"] = str(launcher)
        result = self.run_update("update")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.base / ".update.lock").exists())
        self.assertEqual(self.core.read_bytes(), self.original)

    def test_release_404_reports_unpublished_without_source_fallback(self):
        self.env.update(UPDATE_CURL_RC="22", UPDATE_ERROR_STATUS="404")
        before = self.snapshot()
        result = self.run_update("update-check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("仓库尚无正式发布版本", result.stdout)
        self.assertEqual(before, self.snapshot())
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0]["url"].endswith("/releases/latest"))

    def test_draft_prerelease_and_wrong_asset_urls_are_rejected(self):
        for change in (lambda release: release.update(draft=True),
                       lambda release: release.update(prerelease=True),
                       lambda release: release["assets"][0].update(browser_download_url="https://example.invalid/untrusted.zip"),
                       lambda release: release["assets"][0].update(browser_download_url=release["assets"][0]["browser_download_url"].replace("https:", "http:")),
                       lambda release: release["assets"].append(release["assets"][0])):
            self.package()
            release = json.loads((self.root / "release.json").read_text())
            change(release)
            (self.root / "release.json").write_text(json.dumps(release))
            before = self.snapshot()
            result = self.run_update("update-check")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(before, self.snapshot())

    def test_release_assets_match_both_supported_architectures(self):
        for arch in ("arm64", "x86_64"):
            self.env["UPDATE_ARCH"] = arch
            self.package()
            self.calls.unlink(missing_ok=True)
            result = self.run_update("update-check")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
            self.assertTrue(any(call["url"].endswith("macos-" + arch + "-update.zip") for call in calls))

    def test_missing_release_asset_and_version_mismatch_are_rejected(self):
        release = json.loads((self.root / "release.json").read_text())
        release["assets"] = release["assets"][1:]
        (self.root / "release.json").write_text(json.dumps(release))
        self.assertIn("缺少当前架构", self.run_update("update-check").stdout)
        self.package(version_value="9.9.9")
        self.assertIn("VERSION", self.run_update("update-check").stdout)

    def test_outer_zip_sha_is_required_before_extraction(self):
        (self.root / "SHA256SUMS-release.txt").write_text("0" * 64 + "  " + self.archive_name + "\n")
        result = self.run_update("update-check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("正式更新包 SHA256", result.stdout)
        (self.root / "SHA256SUMS-release.txt").write_text("0" * 64 + "  unrelated.zip\n")
        self.assertIn("缺少必需工件", self.run_update("update-check").stdout)

    def test_internal_manifest_has_exact_six_artifacts(self):
        self.package(manifest_changes=lambda manifest: manifest.__setitem__("extra.py", "0" * 64))
        result = self.run_update("update-check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("非预期项", result.stdout)

    def test_missing_helpers_roll_back_to_absence(self):
        self.updater_wrapper("""original_replace = os.replace
failed = False
def failing_replace(source, destination):
    global failed
    if Path(destination).name == 'desktop-update.py' and not failed:
        failed = True
        raise OSError('synthetic replacement failure')
    return original_replace(source, destination)
os.replace = failing_replace""")
        result = self.run_update("update")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.core.read_bytes(), self.original)
        self.assertFalse((self.base / "stun-probe.py").exists())
        self.assertFalse((self.base / "desktop-update.py").exists())


if __name__ == "__main__":
    unittest.main()
