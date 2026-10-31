#!/usr/bin/python3
"""Fixed-path, root-owned launchd interval configuration for Claude bodyguard."""
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import stat
import subprocess
import sys
import tempfile


MANAGED_DIR = Path("/Library/Application Support/claude-switcher")
PLIST_PATH = Path("/Library/LaunchDaemons/local.claude-bodyguard.plist")
HELPER_PATH = MANAGED_DIR / "bodyguard-settings.py"
LABEL = "local.claude-bodyguard"
SERVICE = "system/" + LABEL
LAUNCHCTL = "/bin/launchctl"


class SettingsError(Exception):
    def __init__(self, message, rollback_recovered=None):
        super().__init__(message)
        self.rollback_recovered = rollback_recovered


def parse_interval(value):
    if type(value) is int and 2 <= value <= 10:
        return value
    if type(value) is str and re.fullmatch(r"(?:[2-9]|10)", value):
        return int(value)
    raise SettingsError("巡检周期必须为 2 至 10 秒的整数")


class BodyguardSettings:
    # Injection is exclusively a Python API for isolated tests; the CLI has no overrides.
    def __init__(self, plist_path=PLIST_PATH, managed_dir=MANAGED_DIR,
                 expected_uid=0, expected_gid=0, run=subprocess.run):
        self.plist_path = Path(plist_path)
        self.managed_dir = Path(managed_dir)
        self.guard_path = self.managed_dir / "claude-bodyguard.sh"
        self.helper_path = self.managed_dir / "bodyguard-settings.py"
        self.expected_uid = expected_uid
        self.expected_gid = expected_gid
        self.run = run

    def _safe(self, path, directory=False, executable=False, check_group=True):
        try:
            info = path.lstat()
            kind = stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)
            if (not kind or info.st_uid != self.expected_uid
                    or (check_group and info.st_gid != self.expected_gid)
                    or info.st_mode & 0o022
                    or (executable and stat.S_IMODE(info.st_mode) != 0o755)):
                raise ValueError("unsafe metadata")
            return info
        except (OSError, ValueError):
            raise SettingsError("安装文件权限或结构不安全，请重新运行安装器") from None

    def _validate_installation(self):
        # Application Support itself uses root:admin on macOS; the managed child is root:wheel.
        self._safe(self.managed_dir.parent, directory=True, check_group=False)
        if self.managed_dir == MANAGED_DIR:
            self._safe(Path("/Library"), directory=True, check_group=False)
        self._safe(self.managed_dir, directory=True)
        self._safe(self.plist_path.parent, directory=True)
        self._safe(self.helper_path, executable=True)
        self._safe(self.guard_path, executable=True)

    def _read_config(self):
        self._validate_installation()
        info = self._safe(self.plist_path)
        try:
            fd = os.open(str(self.plist_path), os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, "rb") as stream:
                opened = os.fstat(stream.fileno())
                if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                    raise ValueError("changed file")
                raw = stream.read(65537)
            if len(raw) > 65536:
                raise ValueError("oversized configuration")
            config = plistlib.loads(raw)
            allowed = {"Label", "ProgramArguments", "RunAtLoad", "StartInterval", "ThrottleInterval"}
            if (type(config) is not dict or not set(config).issubset(allowed)
                    or config.get("Label") != LABEL
                    or config.get("ProgramArguments") != ["/bin/bash", str(self.guard_path)]
                    or config.get("RunAtLoad") is not True):
                raise ValueError("unexpected layout")
            interval = parse_interval(config.get("StartInterval"))
            throttle = parse_interval(config.get("ThrottleInterval", 10))
            if type(config.get("StartInterval")) is not int:
                raise ValueError("invalid plist interval type")
            if "ThrottleInterval" in config and type(config["ThrottleInterval"]) is not int:
                raise ValueError("invalid plist throttle type")
            return config, raw, stat.S_IMODE(info.st_mode), interval, throttle
        except (OSError, ValueError, TypeError, plistlib.InvalidFileException, SettingsError):
            raise SettingsError("保镖服务配置不兼容或无效，请重新运行安装器") from None

    def _launchctl(self, *arguments):
        try:
            return self.run([LAUNCHCTL] + list(arguments), capture_output=True, text=True,
                            timeout=15, check=False,
                            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"})
        except (OSError, subprocess.SubprocessError, UnicodeError):
            raise SettingsError("无法确认保镖服务状态") from None

    def _runtime(self):
        result = self._launchctl("print", SERVICE)
        if result.returncode != 0:
            return False, None
        matches = re.findall(r"^\s*run interval = ([0-9]{1,6}) seconds\s*$", result.stdout, re.MULTILINE)
        active = int(matches[0]) if len(matches) == 1 else None
        return True, active

    @staticmethod
    def _status(interval, throttle, registered, active):
        value = {"interval": interval, "throttleInterval": throttle,
                 "registered": registered, "activeInterval": active}
        if not registered:
            value["message"] = "保镖服务未注册或不可读取"
        elif active is None:
            value["message"] = "运行周期未能验证"
        elif interval != active:
            value["message"] = "配置与当前运行周期不一致"
        elif interval != throttle:
            value["message"] = "巡检周期与节流周期不一致"
        return value

    def status(self):
        _, _, _, interval, throttle = self._read_config()
        registered, active = self._runtime()
        return self._status(interval, throttle, registered, active)

    def _prepare(self, path, data, mode):
        self._safe(path.parent, directory=True)
        if path.exists() or path.is_symlink():
            self._safe(path)
        fd, name = tempfile.mkstemp(prefix=".bodyguard-settings-", dir=str(path.parent))
        temporary = Path(name)
        try:
            with os.fdopen(fd, "wb") as stream:
                if (os.fstat(stream.fileno()).st_uid, os.fstat(stream.fileno()).st_gid) != (self.expected_uid, self.expected_gid):
                    os.fchown(stream.fileno(), self.expected_uid, self.expected_gid)
                os.fchmod(stream.fileno(), mode)
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            self._safe(temporary)
            return temporary
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise

    def _replace(self, temporary, target):
        if target.exists() or target.is_symlink():
            self._safe(target)
        os.replace(str(temporary), str(target))
        directory_fd = os.open(str(target.parent), os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)

    def _restore(self, original, mode, interval):
        temporary = None
        try:
            try:
                self._launchctl("bootout", SERVICE)
            except SettingsError:
                pass
            temporary = self._prepare(self.plist_path, original, mode)
            self._replace(temporary, self.plist_path)
            temporary = None
            try:
                self._launchctl("bootstrap", "system", str(self.plist_path))
            except SettingsError:
                pass
            registered, active = self._runtime()
            return registered and active == interval
        except (SettingsError, OSError):
            return False
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)

    def apply(self, requested):
        interval = parse_interval(requested)
        if os.geteuid() != self.expected_uid:
            raise SettingsError("修改巡检周期需要管理员权限")
        self._validate_installation()
        lock_path = self.managed_dir / ".bodyguard-settings.lock"
        if lock_path.exists() or lock_path.is_symlink():
            self._safe(lock_path)
        lock_fd = os.open(str(lock_path), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(lock_fd)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != self.expected_uid
                    or info.st_gid != self.expected_gid or info.st_mode & 0o022):
                raise SettingsError("配置锁权限不安全，请重新运行安装器")
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise SettingsError("已有巡检配置操作正在进行，请稍后重试") from None
            config, original, mode, old_interval, old_throttle = self._read_config()
            registered, active = self._runtime()
            if not registered:
                raise SettingsError("保镖服务未注册，拒绝修改；请重新运行安装器")
            if old_interval == interval and old_throttle == interval and registered and active == interval:
                value = self._status(interval, interval, True, interval)
                value["changed"] = False
                return value
            temporary = None
            backup_temporary = None
            try:
                updated = dict(config, StartInterval=interval, ThrottleInterval=interval)
                temporary = self._prepare(self.plist_path, plistlib.dumps(updated), mode)
                backup = self.managed_dir / "bodyguard.plist.backup"
                backup_temporary = self._prepare(backup, original, 0o600)
                self._replace(backup_temporary, backup)
                backup_temporary = None
            except (SettingsError, OSError):
                if temporary is not None:
                    temporary.unlink(missing_ok=True)
                if backup_temporary is not None:
                    backup_temporary.unlink(missing_ok=True)
                raise SettingsError("无法准备巡检配置，服务未更改") from None
            try:
                stopped = self._launchctl("bootout", SERVICE)
                if stopped.returncode != 0:
                    raise SettingsError("无法重载保镖服务")
                self._replace(temporary, self.plist_path)
                temporary = None
                started = self._launchctl("bootstrap", "system", str(self.plist_path))
                if started.returncode != 0:
                    raise SettingsError("无法重载保镖服务")
                current_registered, current_interval = self._runtime()
                if not current_registered or current_interval != interval:
                    raise SettingsError("新巡检周期未能验证")
            except (SettingsError, OSError):
                recovered = self._restore(original, mode, old_interval)
                message = "更新失败，已恢复原配置" if recovered else "更新失败，回滚未能确认，请重新运行安装器"
                raise SettingsError(message, rollback_recovered=recovered) from None
            finally:
                if temporary is not None:
                    temporary.unlink(missing_ok=True)
            value = self._status(interval, interval, True, interval)
            value["changed"] = True
            return value
        finally:
            os.close(lock_fd)


def main(arguments=None):
    arguments = sys.argv[1:] if arguments is None else arguments
    try:
        if arguments == ["status"]:
            action, interval = "status", None
        elif len(arguments) == 2 and arguments[0] == "apply":
            action, interval = "apply", parse_interval(arguments[1])
        else:
            raise SettingsError("用法：bodyguard-settings.py status | apply <2..10>")
        if Path(__file__).absolute() != HELPER_PATH:
            raise SettingsError("请通过已安装的固定系统助手操作")
        settings = BodyguardSettings()
        previous_handlers = {}
        def interrupted(_number, _frame):
            raise SettingsError("操作已中断")
        try:
            if action == "apply":
                for number in (signal.SIGINT, signal.SIGTERM):
                    previous_handlers[number] = signal.signal(number, interrupted)
            result = settings.status() if action == "status" else settings.apply(interval)
        finally:
            for number, handler in previous_handlers.items():
                signal.signal(number, handler)
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
        return 0
    except (SettingsError, OSError, ValueError) as error:
        message = str(error) if isinstance(error, SettingsError) else "无法完成保镖配置，请重新运行安装器"
        result = {"error": message}
        recovered = getattr(error, "rollback_recovered", None)
        if recovered is not None:
            result["rollbackRecovered"] = recovered
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
        return 1


if __name__ == "__main__":
    sys.exit(main())
