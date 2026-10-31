"""Installer readiness and acceptance run only with temporary HOME and fake commands."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "installer/安装.command").read_text(encoding="utf-8")
KEYS = ("代理内核", "TUN网卡", "出口IP", "IP一致", "时区", "地区", "IPv6", "DNS",
        "WebRTC", "保镖", "规则置顶", "客户端语言", "ASN属性", "生态可达性")


def function_source(name):
    match = re.search(r"(?ms)^" + re.escape(name) + r"\(\) \{\n.*?^\}", SOURCE)
    if match is None:
        raise AssertionError("missing installer function: " + name)
    return match.group(0)


class InstallerReadinessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="installer-readiness-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.fakebin = self.root / "bin"
        self.home = self.root / "fake home"
        self.fakebin.mkdir()
        (self.home / ".local/bin").mkdir(parents=True)
        self.env = dict(os.environ, HOME=str(self.home), H=str(self.home), FIXTURE=str(self.root),
                        PATH=str(self.fakebin) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                        MODE="clash-verge", DRYRUN="", READY_AFTER="1", TUN_AFTER="1", CORE_RC="0")
        self.stub("pgrep", '''
[ "$*" = '-f verge-mihomo' ] || exit 90
count=$(cat "$FIXTURE/attempt" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s' "$count" > "$FIXTURE/attempt"
[ "$count" -ge "$READY_AFTER" ]
''')
        self.stub("ifconfig", '''
count=$(cat "$FIXTURE/attempt")
if [ "$count" -ge "$TUN_AFTER" ]; then echo '    inet 198.18.0.1 netmask 0xffffff00'; else echo '    inet 192.0.2.1'; fi
''')
        self.stub("sleep", 'printf "%s\\n" "$*" >> "$FIXTURE/sleeps"\n')
        self.stub("osascript", 'echo quit >> "$FIXTURE/app-calls"\n')
        self.stub("open", 'echo open >> "$FIXTURE/app-calls"\n')
        core = self.home / ".local/bin/claude-switch.sh"
        core.write_text('''#!/bin/bash
[ "$*" = checkdetail ] || exit 90
echo checkdetail >> "$FIXTURE/core-calls"
cat "$FIXTURE/check-output"
exit "$CORE_RC"
''', encoding="utf-8")
        core.chmod(0o755)

    def stub(self, name, body):
        path = self.fakebin / name
        path.write_text("#!/bin/bash\n" + body, encoding="utf-8")
        path.chmod(0o755)

    def output(self, changes=None):
        changes = changes or {}
        return "# fixture start\n" + "\n".join(key + "=" + changes.get(key, "ok") for key in KEYS) + "\n# fixture end\n"

    def shell(self, code, input=""):
        return subprocess.run(["/bin/bash", "-c", code], env=self.env, input=input,
                              capture_output=True, text=True, encoding="utf-8", timeout=10)

    def acceptance(self, output, code="0"):
        self.env["CORE_RC"] = code
        return self.shell(function_source("installation_checks_pass") + '\ninstallation_checks_pass "$CORE_RC"', input=output)

    def finish(self, output):
        (self.root / "check-output").write_text(output, encoding="utf-8")
        tail = SOURCE[SOURCE.index("# ---- 7. 重启 Clash"):]
        return self.shell(function_source("wait_for_clash_ready") + "\n" + function_source("installation_checks_pass") + "\n" + tail)

    def test_wait_requires_both_core_and_tun(self):
        self.env.update(READY_AFTER="2", TUN_AFTER="4")
        result = self.shell(function_source("wait_for_clash_ready") + "\nwait_for_clash_ready 5")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "attempt").read_text(), "4")
        self.assertEqual((self.root / "sleeps").read_text().splitlines(), ["1"] * 3)
        self.assertFalse((self.root / "core-calls").exists())

    def test_wait_timeout_is_bounded_and_never_calls_core(self):
        self.env.update(READY_AFTER="100", TUN_AFTER="100")
        result = self.shell(function_source("wait_for_clash_ready") + "\nwait_for_clash_ready 3")
        self.assertEqual(result.returncode, 1)
        self.assertEqual((self.root / "attempt").read_text(), "4")
        self.assertEqual((self.root / "sleeps").read_text().splitlines(), ["1"] * 3)
        self.assertFalse((self.root / "core-calls").exists())

    def test_accepts_complete_checks_and_optional_warning_or_skip(self):
        for output in [self.output(), self.output({"ASN属性": "warn:fixture", "DNS": "skip:用户已禁用"})]:
            with self.subTest(output=output):
                result = self.acceptance(output)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_fail_even_when_core_exits_zero(self):
        self.assertNotEqual(self.acceptance(self.output({"WebRTC": "fail:fixture"})).returncode, 0)

    def test_rejects_nonzero_exit_even_with_complete_ok_output(self):
        self.assertNotEqual(self.acceptance(self.output(), code="7").returncode, 0)

    def test_rejects_incomplete_duplicate_unknown_and_invalid_states(self):
        for output in ["", "\n".join(self.output().splitlines()[:-2]), self.output() + "DNS=ok\n",
                       self.output() + "unexpected=ok\n", self.output({"DNS": ""}),
                       self.output({"DNS": "unknown"}), self.output() + "Traceback: fixture\n"]:
            with self.subTest(output=output):
                self.assertNotEqual(self.acceptance(output).returncode, 0)

    def test_hard_checks_cannot_skip_or_warn(self):
        for key in ("代理内核", "TUN网卡", "出口IP", "时区", "地区", "IPv6", "保镖", "规则置顶"):
            for state in ("skip:fixture", "warn:fixture"):
                with self.subTest(key=key, state=state):
                    self.assertNotEqual(self.acceptance(self.output({key: state})).returncode, 0)

    def test_finish_timeout_skips_checkdetail_and_never_reports_success(self):
        self.env.update(READY_AFTER="100", TUN_AFTER="100")
        result = self.finish(self.output())
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("已跳过网络自检", result.stdout)
        self.assertIn("安装文件已就位，但环境尚未通过验收", result.stdout)
        self.assertNotIn("✅ 安装完成", result.stdout)
        self.assertFalse((self.root / "core-calls").exists())
        self.assertEqual((self.root / "sleeps").read_text().splitlines(), ["2"] + ["1"] * 30)

    def test_finish_check_failure_does_not_report_success(self):
        for code, output in [("0", self.output({"WebRTC": "fail:fixture"})), ("7", self.output()),
                             ("0", self.output().replace("DNS=ok\n", ""))]:
            with self.subTest(code=code, output=output):
                self.env["CORE_RC"] = code
                result = self.finish(output)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("安装文件已就位，但环境尚未通过验收", result.stdout)
                self.assertNotIn("✅ 安装完成", result.stdout)

    def test_finish_success_requires_ready_and_complete_accepted_output(self):
        self.env.update(READY_AFTER="2", TUN_AFTER="3")
        result = self.finish(self.output({"ASN属性": "warn:fixture", "DNS": "skip:用户已禁用"}))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("✅ 安装完成", result.stdout)
        self.assertIn("DNS=skip:用户已禁用", result.stdout)
        self.assertEqual((self.root / "core-calls").read_text().splitlines(), ["checkdetail"])


if __name__ == "__main__":
    unittest.main()
