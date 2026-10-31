"""Read-only menu-bar monitoring against isolated HOME and fake system probes."""
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "core/claude-switch.sh"


class MonitorStatusTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "_trash").mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="monitor-status-", dir=ROOT / "_trash")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.core = self.root / "claude-switch.sh"
        self.calls = self.root / "calls"
        self.source = SOURCE.read_text(encoding="utf-8")
        self.mode("clash-verge")
        self.env = dict(os.environ, HOME=str(self.home),
                        PATH=str(self.bin) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                        MONITOR_CALLS=str(self.calls), MONITOR_TUN="1",
                        MONITOR_PGREP_MATCHES="-f verge-mihomo", MONITOR_VPN="connected")
        self.stub("pgrep", '''case "|${MONITOR_PGREP_MATCHES:-}|" in
  *"|$*|"*) exit 0 ;;
  *) exit 1 ;;
esac''')
        self.stub("ifconfig", '''if [ "$MONITOR_TUN" = 1 ]; then
  printf 'utun1: flags=8051\n    inet 198.18.0.1 netmask 0xffffff00\n'
else
  printf 'en0: flags=8863\n    inet 192.0.2.1 netmask 0xffffff00\n'
fi''')
        self.stub("scutil", '''case "$MONITOR_VPN" in
  connected) echo '* (Connected) Example com.liguangming.Shadowrocket' ;;
  disconnected) echo '* (Disconnected) Example com.liguangming.Shadowrocket' ;;
  missing) : ;;
esac''')
        # Any call beyond the two local probes is observable and fails closed.
        for name in ("curl", "dig", "python3", "networksetup", "systemsetup", "defaults",
                     "launchctl", "open", "pkill", "killall", "mkdir", "chmod", "chown",
                     "cp", "mv", "rm", "date", "osascript"):
            self.stub(name, "exit 99")

    def mode(self, mode):
        text = self.source.replace('PROXY_MODE="clash-verge"', f'PROXY_MODE="{mode}"', 1)
        self.core.write_text(text, encoding="utf-8")
        self.core.chmod(0o755)

    def stub(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\nprintf "%s\\n" "${0##*/} $*" >> "$MONITOR_CALLS"\n'
                        + body + "\n", encoding="utf-8")
        path.chmod(0o755)

    def home_snapshot(self):
        return {str(path.relative_to(self.home)):
                (stat.S_IMODE(path.stat().st_mode), path.stat().st_mtime_ns,
                 path.read_bytes() if path.is_file() else None)
                for path in self.home.rglob("*")}

    def run_monitor(self, *extra):
        before = self.home_snapshot()
        result = subprocess.run(["/bin/bash", str(self.core), "monitor-status", *extra],
                                env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(self.home_snapshot(), before, "监测不得创建或修改账号/日志/设置")
        calls = self.calls.read_text(encoding="utf-8").splitlines() if self.calls.exists() else []
        self.assertTrue(all(call.split()[0] in {"pgrep", "ifconfig", "scutil"} for call in calls), calls)
        return result

    def expect_status(self, kernel, tun):
        result = self.run_monitor()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout,
                         f"monitor-version=1\n代理内核={kernel}\nTUN网卡={tun}\n")
        self.assertEqual(result.stderr, "")

    def test_kernel_and_tun_health_are_independent(self):
        for kernel in (True, False):
            for tun in (True, False):
                with self.subTest(kernel=kernel, tun=tun):
                    self.env["MONITOR_PGREP_MATCHES"] = "-f verge-mihomo" if kernel else ""
                    self.env["MONITOR_TUN"] = "1" if tun else "0"
                    self.expect_status("ok" if kernel else "fail", "ok" if tun else "fail")

    def test_missing_account_state_stays_missing(self):
        self.expect_status("ok", "ok")
        self.assertFalse((self.home / ".claude-switcher").exists())
        self.assertFalse((self.home / "Library").exists())

    def test_malformed_optional_settings_do_not_disable_monitoring(self):
        base = self.home / ".claude-switcher"
        base.mkdir(mode=0o700)
        (base / "checks.json").write_text('{"disabled": ["TUN网卡"', encoding="utf-8")
        (base / "last-check.txt").write_text("TUN网卡=ok\n", encoding="utf-8")
        self.env["MONITOR_TUN"] = "0"
        self.expect_status("ok", "fail")

    def test_existing_logs_and_account_state_remain_untouched(self):
        base = self.home / ".claude-switcher"
        (base / "accounts" / "A").mkdir(parents=True)
        (base / "accounts" / "A" / "fixture").write_text("isolated fixture", encoding="utf-8")
        (base / "current").write_text("A\n", encoding="utf-8")
        logs = self.home / "Library" / "Logs" / "claude-switcher"
        logs.mkdir(parents=True)
        (logs / "client.log").write_text("existing log\n", encoding="utf-8")
        self.env["MONITOR_PGREP_MATCHES"] = ""
        self.expect_status("fail", "ok")

    def test_reuses_selected_client_kernel_detection(self):
        for mode, process in (("clash-verge", "-f verge-mihomo"),
                              ("flclash", "-f FlClashCore"), ("flclash", "-x FlClash"),
                              ("sing-box", "-f sing-box"), ("clashx", "-x ClashX"),
                              ("surge", "-f Surge"), ("auto", "-f verge-mihomo")):
            with self.subTest(mode=mode, process=process):
                self.mode(mode)
                self.env["MONITOR_PGREP_MATCHES"] = process
                self.expect_status("ok", "ok")

    def test_shadowrocket_connection_and_tun_fallback(self):
        self.mode("shadowrocket")
        for connection, tun, kernel in (("connected", "1", "ok"),
                                        ("disconnected", "1", "fail"),
                                        ("missing", "1", "ok"), ("missing", "0", "fail")):
            with self.subTest(connection=connection, tun=tun):
                self.env["MONITOR_VPN"] = connection
                self.env["MONITOR_TUN"] = tun
                self.expect_status(kernel, "ok" if tun == "1" else "fail")

    def test_extra_arguments_are_rejected_without_probing_or_writing(self):
        result = self.run_monitor("unexpected")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    unittest.main()
