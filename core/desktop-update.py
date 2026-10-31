#!/usr/bin/env python3
"""User-owned macOS desktop updater. Never installs or executes root components."""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile

REPOSITORY = "chenchao19934/claude-switcher"
REQUIRED = {
    "core/claude-switch.sh", "core/stun-probe.py", "core/desktop-update.py",
}
CONFIG_KEYS = ("PROXY_MODE", "PROXY_GROUP", "COUNTRY_TARGET", "TZ_TARGET", "LOCALE_TARGET")
AUDIT_KEYS = {
    "代理内核", "TUN网卡", "出口IP", "IP一致", "时区", "地区", "IPv6", "DNS",
    "WebRTC", "保镖", "规则置顶", "客户端语言", "ASN属性", "生态可达性",
}
OPTIONAL = {"IP一致", "DNS", "WebRTC", "客户端语言", "ASN属性", "生态可达性"}
DAEMON_FILES = ("claude-bodyguard.sh", "tz-watchdog.sh", "bodyguard-settings.py")
DAEMON_CHANGED = "系统守护组件有更新，请另行运行安装器同步（需管理员授权）"
DAEMON_UNKNOWN = "系统守护组件版本无法确认，请另行运行安装器核对（需管理员授权）"
DAEMON_MISSING = "系统守护组件未安装，请重新运行安装器同步（需管理员授权）"
MAX_ARCHIVE = 80 * 1024 * 1024
MAX_EXPANDED = 240 * 1024 * 1024


class UpdateError(Exception):
    pass


class ReleaseUnavailable(UpdateError):
    pass


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def ensure_plain(path, directory=None):
    path = Path(path)
    if path.is_symlink():
        raise UpdateError("更新路径包含符号链接，已中止")
    if directory is True and not path.is_dir():
        raise UpdateError("更新目录不存在")
    if directory is False and not path.is_file():
        raise UpdateError("更新文件不存在")
    for parent in path.parents:
        if parent.is_symlink():
            raise UpdateError("更新路径包含符号链接，已中止")
    return path


def tree_digest(path, ignored=()):
    root = ensure_plain(path, True)
    value = hashlib.sha256()
    for item in sorted(root.rglob("*")):
        ensure_plain(item)
        if not (item.is_dir() or item.is_file()):
            raise UpdateError("App 包含不支持的文件类型")
        relative = item.relative_to(root).as_posix()
        if any(relative == prefix or relative.startswith(prefix + "/") for prefix in ignored):
            continue
        value.update((relative + "\0" + oct(stat.S_IMODE(item.stat().st_mode)) + "\0").encode())
        if item.is_file():
            value.update(digest(item).encode())
    return value.hexdigest()


def write_json(path, value):
    path = Path(path)
    temp = path.with_name(path.name + ".new-" + uuid.uuid4().hex)
    try:
        fd = os.open(str(temp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            temp.unlink()


def read_json(path):
    ensure_plain(path, False)
    if Path(path).stat().st_size > 128 * 1024:
        raise UpdateError("更新事务记录无效")
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
        if not isinstance(value, dict):
            raise ValueError()
        return value
    except (ValueError, OSError) as error:
        raise UpdateError("更新事务记录无效") from error


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


class UpdateLock:
    """The core updater uses the same mkdir + pid/nonce protocol."""
    def __init__(self, home):
        self.path = Path(home) / ".claude-switcher/.update.lock"
        self.nonce = uuid.uuid4().hex

    def __enter__(self):
        # Never expose a half-written owner record to termination handlers.
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGINT})
        acquired = False
        try:
            result = self.acquire()
            acquired = True
        finally:
            try:
                signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
            except BaseException:
                # A pending signal can be delivered before the with statement enters.
                if acquired:
                    self.__exit__(None, None, None)
                raise
        return result

    def acquire(self):
        parent = self.path.parent
        ensure_plain(parent, True)
        try:
            self.path.mkdir(mode=0o700)
        except FileExistsError:
            raise UpdateError("另一个更新正在进行，请稍后重试")
        created = []
        try:
            for name, value in (("pid", str(os.getpid())), ("nonce", self.nonce)):
                fd = os.open(str(self.path / name), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                created.append(self.path / name)
                with os.fdopen(fd, "w", encoding="ascii") as handle:
                    handle.write(value + "\n")
        except BaseException:
            for item in created:
                with contextlib.suppress(OSError):
                    item.unlink()
            with contextlib.suppress(OSError):
                self.path.rmdir()
            raise
        return self

    def __exit__(self, *_):
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGINT})
        try:
            self.release()
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

    def release(self):
        try:
            if ((self.path / "pid").read_text(encoding="ascii") == str(os.getpid()) + "\n"
                    and (self.path / "nonce").read_text(encoding="ascii") == self.nonce + "\n"):
                (self.path / "pid").unlink()
                (self.path / "nonce").unlink()
                self.path.rmdir()
        except (OSError, UpdateError):
            pass


def safe_extract(archive, destination):
    if Path(archive).stat().st_size > MAX_ARCHIVE:
        raise UpdateError("下载包超过大小限制")
    try:
        with zipfile.ZipFile(archive) as handle:
            members = handle.infolist()
            if len(members) > 15000 or sum(item.file_size for item in members) > MAX_EXPANDED:
                raise UpdateError("下载包展开后超过大小限制")
            seen = set()
            for item in members:
                path = PurePosixPath(item.filename)
                mode = item.external_attr >> 16
                if (not item.filename or path.is_absolute() or ".." in path.parts
                        or "\\" in item.filename or "\x00" in item.filename
                        or item.filename.rstrip("/") != path.as_posix()
                        or path.as_posix() in seen or stat.S_ISLNK(mode)
                        or (stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR))):
                    raise UpdateError("下载包包含不安全路径或符号链接")
                seen.add(path.as_posix())
            handle.extractall(destination)
            for item in members:
                target = Path(destination) / item.filename
                archived_mode = item.external_attr >> 16
                target.chmod(0o755 if item.is_dir() or archived_mode & 0o111 else 0o644)
            return Path(destination)
    except (zipfile.BadZipFile, OSError) as error:
        raise UpdateError("下载包无法解压") from error


def verify_manifest(root, manifest):
    entries = {}
    try:
        lines = Path(manifest).read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise UpdateError("无法读取 SHA256 校验清单") from error
    for line in lines:
        match = re.fullmatch(r"([0-9a-fA-F]{64})  ([^\r\n]+)", line)
        if not match:
            raise UpdateError("SHA256 校验清单格式无效")
        checksum, relative = match.groups()
        parts = PurePosixPath(relative)
        if (relative in entries or parts.is_absolute() or ".." in parts.parts
                or "\\" in relative or relative != parts.as_posix()):
            raise UpdateError("SHA256 校验清单包含不安全路径")
        target = ensure_plain(Path(root) / relative, False)
        if digest(target) != checksum.lower():
            raise UpdateError("SHA256 工件校验失败，已中止")
        entries[relative] = checksum.lower()
    allowed = REQUIRED | {"daemons/" + name for name in DAEMON_FILES}
    if not REQUIRED.issubset(entries):
        raise UpdateError("SHA256 校验清单缺少必要更新工件")
    if not set(entries).issubset(allowed):
        raise UpdateError("更新包内部校验清单包含未知工件")
    return entries


def release_version(value):
    if not isinstance(value, str) or len(value) > 64 or not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", value):
        raise UpdateError("正式发布版本号无效")
    return value


def version_key(value):
    # Older source installers used 1.0; development packages used 0.0.0-dev.
    if not isinstance(value, str) or len(value) > 80:
        raise UpdateError("无法识别本机 App 版本，请使用正式安装包更新")
    match = re.fullmatch(r"([0-9]+)(?:\.([0-9]+))?(?:\.([0-9]+))?(-[0-9A-Za-z.-]+)?", value)
    if not match:
        raise UpdateError("无法识别本机 App 版本，请使用正式安装包更新")
    return tuple(int(value or 0) for value in match.groups()[:3]) + (0 if match[4] else 1,)


def release_assets(metadata, arch):
    if not isinstance(metadata, dict) or metadata.get("draft") is not False or metadata.get("prerelease") is not False:
        raise UpdateError("尚无可用的正式发布版本")
    tag = metadata.get("tag_name")
    if not isinstance(tag, str) or not tag.startswith("v"):
        raise UpdateError("正式发布标签无效")
    version = release_version(tag[1:])
    if arch not in {"arm64", "x86_64"}:
        raise UpdateError("当前处理器架构暂无正式更新包")
    filename = "ClaudeSwitcher-" + version + "-macos-" + arch + "-update.zip"
    expected = {filename, "SHA256SUMS-release.txt"}
    assets = metadata.get("assets")
    if not isinstance(assets, list) or len(assets) > 100:
        raise UpdateError("正式发布缺少更新安装包")
    found = {}
    for asset in assets:
        if not isinstance(asset, dict):
            raise UpdateError("正式发布资产信息无效")
        name = asset.get("name")
        if not isinstance(name, str):
            raise UpdateError("正式发布资产名称无效")
        if name not in expected:
            continue
        url = "https://github.com/" + REPOSITORY + "/releases/download/" + tag + "/" + name
        if name in found or asset.get("browser_download_url") != url:
            raise UpdateError("正式发布资产地址不可信或重复")
        size = asset.get("size")
        limit = MAX_ARCHIVE if name == filename else 256 * 1024
        if type(size) is not int or not 0 < size <= limit:
            raise UpdateError("正式发布资产大小无效")
        found[name] = url
    if set(found) != expected:
        raise UpdateError("正式发布缺少当前架构更新包或校验清单")
    return version, filename, found


def verify_release_checksum(manifest, filename, archive):
    checksums = {}
    try:
        lines = Path(manifest).read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise UpdateError("无法读取正式发布校验清单") from error
    for line in lines:
        match = re.fullmatch(r"([0-9a-fA-F]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*)", line)
        if not match or match[2] in checksums or match[2] in {".", ".."}:
            raise UpdateError("正式发布校验清单格式无效或包含重复项")
        checksums[match[2]] = match[1].lower()
    if filename not in checksums or digest(archive) != checksums[filename]:
        raise UpdateError("正式更新安装包 SHA256 校验失败，已中止")


def macho_architectures(path):
    target = ensure_plain(path, False)
    size = target.stat().st_size
    thin = {b"\xcf\xfa\xed\xfe": ("<", 32), b"\xfe\xed\xfa\xcf": (">", 32),
            b"\xce\xfa\xed\xfe": ("<", 28), b"\xfe\xed\xfa\xce": (">", 28)}
    fat = {b"\xca\xfe\xba\xbe": (">", 20), b"\xbe\xba\xfe\xca": ("<", 20),
           b"\xca\xfe\xba\xbf": (">", 32), b"\xbf\xba\xfe\xca": ("<", 32)}
    names = {0x0100000c: "arm64", 0x01000007: "x86_64"}
    def thin_cpu(handle, offset, length):
        handle.seek(offset)
        header = handle.read(min(length, 32))
        if len(header) < 4 or header[:4] not in thin:
            raise UpdateError("更新 App 可执行文件不是有效的 Mach-O")
        endian, minimum = thin[header[:4]]
        if length < minimum or len(header) < minimum:
            raise UpdateError("更新 App Mach-O 头不完整")
        cpu = struct.unpack(endian + "I", header[4:8])[0]
        if cpu in names and minimum != 32:
            raise UpdateError("更新 App Mach-O 架构声明无效")
        return cpu
    with target.open("rb") as handle:
        magic = handle.read(4)
        if magic in thin:
            return {names.get(thin_cpu(handle, 0, size), "unsupported")}
        if magic not in fat or size < 8:
            raise UpdateError("更新 App 可执行文件不是有效的 Mach-O")
        endian, stride = fat[magic]
        count = struct.unpack(endian + "I", handle.read(4))[0]
        if not 1 <= count <= 32 or 8 + count * stride > size:
            raise UpdateError("更新 App 通用二进制头无效")
        table_end = 8 + count * stride
        slices = []
        cpus = set()
        for index in range(count):
            handle.seek(8 + index * stride)
            raw = handle.read(stride)
            fields = struct.unpack(endian + ("IIIII" if stride == 20 else "IIQQII"), raw)
            cpu, _, offset, length, alignment = fields[:5]
            if (offset < table_end or length < 28 or offset + length > size or alignment > 31
                    or offset % (1 << alignment) or (stride == 32 and fields[5] != 0)
                    or cpu in cpus):
                raise UpdateError("更新 App 通用二进制分段无效")
            if any(offset < old_offset + old_length and old_offset < offset + length for old_offset, old_length in slices):
                raise UpdateError("更新 App 通用二进制分段重叠")
            if thin_cpu(handle, offset, length) != cpu:
                raise UpdateError("更新 App 通用二进制架构不一致")
            slices.append((offset, length))
            cpus.add(cpu)
        return {names.get(cpu, "unsupported") for cpu in cpus}


def config_values(source):
    values = {}
    for key in CONFIG_KEYS:
        matches = re.findall(r"^" + key + r'="((?:[^"\n\\]|\\.)*)"[^\n]*$', source, re.M)
        if len(matches) != 1:
            raise UpdateError("现有核心配置不完整或重复，已中止")
        raw = matches[0]
        value = ""
        index = 0
        while index < len(raw):
            char = raw[index]
            if char == "\\":
                index += 1
                char = raw[index]
                value += char if char in '$`"\\' else "\\" + char
            elif char in "$`":
                raise UpdateError("核心配置必须为字面值，已中止")
            else:
                value += char
            index += 1
        values[key] = value
    return values


def inject_config(new_source, old_source):
    values = config_values(old_source)
    # Reject missing/duplicate defaults in the downloaded core too.
    config_values(new_source)
    for key, value in values.items():
        escaped = "".join("\\" + char if char in '$`"\\' else char for char in value)
        new_source = re.sub(r"^" + key + r'="(?:[^"\n\\]|\\.)*"[^\n]*$',
                            lambda _: key + '="' + escaped + '"', new_source, flags=re.M)
    return new_source


def strip_config(source):
    return re.sub(r"^(?:" + "|".join(CONFIG_KEYS) + r')="[^\n]*\n?', "", source, flags=re.M)


def audit_passed(output, returncode):
    if returncode:
        return False
    found = {}
    for line in output.splitlines():
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        status = value.partition(":")[0]
        if not sep or key not in AUDIT_KEYS or key in found or status not in {"ok", "warn", "skip"}:
            return False
        if status != "ok" and key not in OPTIONAL:
            return False
        found[key] = status
    return set(found) == AUDIT_KEYS


class Backend:
    def __init__(self):
        self.deadline = None

    def begin(self, seconds):
        self.deadline = time.monotonic() + seconds

    def remaining(self, requested):
        remaining = requested if self.deadline is None else min(requested, self.deadline - time.monotonic())
        if remaining <= 0:
            raise UpdateError("更新准备超过时间限制，原版本未改变")
        return remaining

    def proxy_environment(self):
        env = dict(os.environ)
        if any(env.get(key) for key in ("https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY")):
            return env
        http_proxy = env.get("http_proxy") or env.get("HTTP_PROXY")
        if http_proxy:
            # curl does not use HTTP_PROXY for HTTPS URLs.
            env["https_proxy"] = http_proxy
            return env
        try:
            result = subprocess.run(["/usr/sbin/scutil", "--proxy"], capture_output=True, text=True, timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            return env
        fields = dict(re.findall(r"^\s*(\w+)\s*:\s*(.*?)\s*$", result.stdout, re.M))
        for scheme in ("HTTPS", "HTTP"):
            host, port = fields.get(scheme + "Proxy", ""), fields.get(scheme + "Port", "")
            if fields.get(scheme + "Enable") == "1" and host and port.isdigit() and 0 < int(port) < 65536:
                if re.fullmatch(r"[A-Za-z0-9._:-]+", host):
                    host = "[" + host + "]" if ":" in host and not host.startswith("[") else host
                    env["https_proxy"] = "http://" + host + ":" + port
                    break
        return env

    def download(self, url, target, limit):
        try:
            result = subprocess.run([
                "/usr/bin/curl", "--fail", "--silent", "--show-error", "--location",
                "--proto", "=https", "--proto-redir", "=https", "--retry", "2",
                "--retry-delay", "1", "--retry-max-time", "45", "--connect-timeout", "10", "--max-time", "25",
                "--max-filesize", str(limit), "--write-out", "%{http_code}", "--output", str(target), url,
            ], env=self.proxy_environment(), capture_output=True, timeout=self.remaining(75))
        except (OSError, subprocess.TimeoutExpired) as error:
            raise UpdateError("下载超时或网络不可用，请确认代理后重试") from error
        if result.returncode:
            code = result.returncode
            if code == 22:
                status = result.stdout.decode("ascii", errors="ignore").strip()
                category = "下载服务器返回 HTTP " + (status if re.fullmatch(r"[1-5][0-9]{2}", status) else "错误")
            elif code in {35, 51, 58, 60, 77, 80, 82, 83, 90, 91}:
                category = "下载 TLS 连接或证书校验失败"
            elif code in {5, 6}:
                category = "下载域名或代理地址解析失败"
            elif code == 28:
                category = "下载连接超时"
            elif code == 63:
                category = "下载内容超过大小限制"
            else:
                category = "下载连接失败"
            raise UpdateError(category + "，请确认系统代理后重试")
        if not target.is_file() or target.stat().st_size > limit or target.stat().st_size == 0:
            raise UpdateError("下载内容为空或超过大小限制")

    def release_info(self, work):
        metadata = work / "release.json"
        try:
            self.download("https://api.github.com/repos/" + REPOSITORY + "/releases/latest", metadata, 2 * 1024 * 1024)
        except UpdateError as error:
            if "HTTP 404" in str(error):
                raise ReleaseUnavailable("仓库尚无正式发布版本") from error
            raise
        try:
            release = json.loads(metadata.read_text(encoding="utf-8"))
        except (ValueError, TypeError, OSError) as error:
            raise UpdateError("无法识别正式发布版本信息") from error
        return release_assets(release, os.uname().machine)

    def fetch(self, work):
        version, filename, assets = self.release_info(work)
        archive, manifest = work / filename, work / "SHA256SUMS-release.txt"
        self.download(assets["SHA256SUMS-release.txt"], manifest, 256 * 1024)
        self.download(assets[filename], archive, MAX_ARCHIVE)
        verify_release_checksum(manifest, filename, archive)
        root = safe_extract(archive, work / "package")
        allowed_roots = {"Claude切换器.app", "core", "daemons", "SHA256SUMS", "VERSION"}
        if not {"Claude切换器.app", "core", "SHA256SUMS", "VERSION"}.issubset({p.name for p in root.iterdir()}) or any(p.name not in allowed_roots for p in root.iterdir()):
            raise UpdateError("正式更新包结构异常")
        if ensure_plain(root / "VERSION", False).read_text(encoding="utf-8").strip() != version:
            raise UpdateError("正式更新包版本与发布版本不一致")
        entries = verify_manifest(root, root / "SHA256SUMS")
        self.verify_bundle(root / "Claude切换器.app", version, entries)
        return version, root, entries

    def command(self, args, timeout=20):
        try:
            result = subprocess.run(args, capture_output=True, timeout=self.remaining(timeout))
        except (OSError, subprocess.TimeoutExpired) as error:
            raise UpdateError("安装包校验失败或超时，未替换已安装版本") from error
        if result.returncode:
            raise UpdateError("安装包签名或可执行文件校验失败，未替换已安装版本")
        return result

    def verify_bundle(self, app, version, entries):
        tree_digest(app)
        info = read_plist(app / "Contents/Info.plist")
        if (info.get("CFBundleIdentifier") != "local.claude-switcher"
                or info.get("CFBundleExecutable") != "ClaudeSwitcher"
                or info.get("CFBundleShortVersionString") != version):
            raise UpdateError("正式安装包 App 标识或版本不匹配")
        executable = ensure_plain(app / "Contents/MacOS/ClaudeSwitcher", False)
        if not executable.stat().st_mode & 0o111 or os.uname().machine not in macho_architectures(executable):
            raise UpdateError("正式安装包与当前处理器架构不匹配")
        helper = ensure_plain(app / "Contents/Resources/desktop-update.py", False)
        if digest(helper) != entries["core/desktop-update.py"]:
            raise UpdateError("App 内置更新组件与安装包不一致")
        if (app / "Contents/PlugIns").exists() or info.get("ClaudeSwitcherAppGroup"):
            raise UpdateError("正式小组件安装包需要使用相同签名的专用更新渠道")
        self.command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])

    def build(self, source, output, old_app, version, entries):
        # This copies a CI-built, checksum-verified bundle; no developer tools run locally.
        shutil.copytree(source / "Claude切换器.app", output)
        self.verify_bundle(output, version, entries)

    def audit(self, core):
        # The caller's installed settings/defaults must be used; no Claude launch occurs.
        try:
            result = subprocess.run(["/bin/bash", str(core), "checkdetail"], capture_output=True,
                                    text=True, encoding="utf-8", errors="replace", timeout=self.remaining(120))
        except (OSError, subprocess.TimeoutExpired) as error:
            raise UpdateError("新版完整安全检查超时，未替换安装版本") from error
        if not audit_passed(result.stdout, result.returncode):
            raise UpdateError("新版完整安全检查未通过，未替换安装版本")

    def launch(self, app, token=None):
        args = [str(app / "Contents/MacOS/ClaudeSwitcher")]
        if token:
            args += ["--update-token", token]
        try:
            return subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError as error:
            raise UpdateError("App 启动失败") from error

    def spawn_worker(self, helper, app, core, token, pid):
        subprocess.Popen(["/usr/bin/python3", "-I", "-B", str(helper), "_worker", "--app", str(app),
                          "--core", str(core), "--token", token, "--pid", str(pid)],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)


class Updater:
    def __init__(self, app, core, home=None, backend=None, managed_directory=None):
        self.home = Path(home if home is not None else Path.home()).absolute()
        self.app = Path(app).absolute()
        self.core = Path(core).absolute()
        self.stun = self.home / ".claude-switcher/stun-probe.py"
        self.backend = backend or Backend()
        self.managed_directory = Path(managed_directory) if managed_directory is not None else Path("/Library/Application Support/claude-switcher")

    def daemon_notice(self, source, entries):
        # Read only. Never execute or install downloaded privileged components.
        relatives = ["daemons/" + name for name in DAEMON_FILES]
        if not set(relatives).issubset(entries):
            return DAEMON_UNKNOWN
        try:
            values = config_values(self.core.read_text(encoding="utf-8"))
            replacements = {"__HOME__": str(self.home), "__PROXY_MODE__": values["PROXY_MODE"],
                            "__TZ_TARGET__": values["TZ_TARGET"]}
            for name, relative in zip(DAEMON_FILES, relatives):
                template = ensure_plain(Path(source) / relative, False)
                if digest(template) != entries[relative]:
                    return DAEMON_UNKNOWN
                installed = self.managed_directory / name
                if not installed.exists() and not installed.is_symlink():
                    return DAEMON_MISSING
                ensure_plain(installed, False)
                expected = template.read_bytes()
                if name != "bodyguard-settings.py":
                    text = expected.decode("utf-8")
                    for placeholder, value in replacements.items():
                        text = text.replace(placeholder, value)
                    expected = text.encode("utf-8")
                if expected != installed.read_bytes():
                    return DAEMON_CHANGED
            return ""
        except (OSError, UnicodeError, UpdateError):
            return DAEMON_UNKNOWN

    @staticmethod
    def message_with_notice(message, notice):
        return message + ("；" + notice if notice else "")

    def validate_targets(self):
        ensure_plain(self.home, True)
        ensure_plain(self.app, True)
        ensure_plain(self.core, False)
        ensure_plain(self.stun.parent, True)
        if self.stun.exists() or self.stun.is_symlink():
            ensure_plain(self.stun, False)
        if self.core != self.home / ".local/bin/claude-switch.sh":
            raise UpdateError("核心脚本路径必须为当前用户的安装路径")
        if self.app.suffix != ".app":
            raise UpdateError("更新目标必须为已安装的 App")
        for target in (self.app, self.app.parent, self.core, self.core.parent, self.stun.parent):
            if target.stat().st_uid != os.getuid() or not os.access(target, os.W_OK):
                raise UpdateError("安装位置不属于当前用户或不可写，请使用安装器更新")
        info = read_plist(self.app / "Contents/Info.plist")
        if info.get("CFBundleIdentifier") != "local.claude-switcher":
            raise UpdateError("App 标识不匹配，已中止")
        if (self.app / "Contents/PlugIns").exists() or info.get("ClaudeSwitcherAppGroup"):
            raise UpdateError("此 App 包含正式小组件，请通过相同签名的发布包更新")
        # Reject developer-signed apps too; rebuilding with ad-hoc would change identity.
        try:
            signing = subprocess.run(["/usr/bin/codesign", "-dv", str(self.app)], capture_output=True, text=True, timeout=10)
            if re.search(r"^TeamIdentifier=(?!not set\b).+", signing.stderr, re.M):
                raise UpdateError("此 App 使用正式签名，请通过相同签名的发布包更新")
        except (OSError, subprocess.TimeoutExpired):
            pass
        if len({self.app.parent.stat().st_dev, self.core.parent.stat().st_dev, self.stun.parent.stat().st_dev}) != 1:
            raise UpdateError("App 与核心脚本必须位于同一磁盘，请使用安装器调整安装位置")
        tree_digest(self.app)
        config_values(self.core.read_text(encoding="utf-8"))

    def current(self, entries, version):
        self.component_repair = False
        info = read_plist(self.app / "Contents/Info.plist")
        local_key = version_key(info.get("CFBundleShortVersionString"))
        remote_key = version_key(release_version(version))
        if local_key > remote_key:
            raise UpdateError("本机版本高于当前正式发布版本，已拒绝降级")
        if local_key < remote_key:
            return False
        candidate = self.source_core.parent.parent / "Claude切换器.app"
        identical = (tree_digest(self.app) == tree_digest(candidate)
                     and strip_config(self.core.read_text(encoding="utf-8")) == strip_config(self.source_core.read_text(encoding="utf-8"))
                     and self.stun.is_file() and digest(self.stun) == entries["core/stun-probe.py"])
        if not identical:
            ignored = ("Contents/Resources/desktop-update.py", "Contents/_CodeSignature")
            if tree_digest(self.app, ignored) != tree_digest(candidate, ignored):
                raise UpdateError("同版本 App 主体与正式安装包不一致，请使用安装器修复")
            self.component_repair = True
            return False
        return True

    def check(self):
        # Version checks need neither write access nor installed core/daemon probes.
        ensure_plain(self.app, True)
        info = read_plist(self.app / "Contents/Info.plist")
        if info.get("CFBundleIdentifier") != "local.claude-switcher":
            raise UpdateError("App 标识不匹配，已中止")
        local_key = version_key(info.get("CFBundleShortVersionString"))
        if hasattr(self.backend, "begin"):
            self.backend.begin(90)
        with tempfile.TemporaryDirectory(prefix="claude-switcher-check-") as directory:
            try:
                version, _, _ = self.backend.release_info(Path(directory).resolve())
            except ReleaseUnavailable:
                return {"state": "unavailable", "message": "仓库尚无正式发布版本"}
        remote_key = version_key(release_version(version))
        if local_key > remote_key:
            raise UpdateError("本机版本高于当前正式发布版本，已拒绝降级")
        current = local_key == remote_key
        return {"state": "current" if current else "available", "version": version,
                "message": "当前版本已是 GitHub 最新正式版本" if current else "发现正式新版本，可更新界面和核心脚本"}

    def stage_path(self, token):
        try:
            if str(uuid.UUID(token)) != token:
                raise ValueError()
        except (ValueError, AttributeError):
            raise UpdateError("更新事务标识无效")
        return self.app.parent / (".claude-switcher-update-" + token)

    def receipt(self, token):
        stage = ensure_plain(self.stage_path(token), True)
        if stage.stat().st_uid != os.getuid() or stat.S_IMODE(stage.stat().st_mode) != 0o700:
            raise UpdateError("更新暂存目录权限无效")
        receipt_path = ensure_plain(stage / "receipt.json", False)
        if receipt_path.stat().st_uid != os.getuid() or stat.S_IMODE(receipt_path.stat().st_mode) != 0o600:
            raise UpdateError("更新事务记录权限无效")
        record = read_json(receipt_path)
        if (record.get("schema") != 1 or record.get("token") != token
                or record.get("app") != str(self.app) or record.get("core") != str(self.core)
                or record.get("stun") != str(self.stun)
                or not isinstance(record.get("created"), (int, float))
                or not -60 <= time.time() - record["created"] <= 1800):
            raise UpdateError("更新事务无效或已过期，请重新检查")
        return stage, record

    def originals(self):
        return {"app": tree_digest(self.app), "core": digest(ensure_plain(self.core, False)),
                "stun": digest(ensure_plain(self.stun, False)) if self.stun.exists() or self.stun.is_symlink() else None}

    def assert_originals(self, record):
        if self.originals() != record["original"]:
            raise UpdateError("准备后安装文件发生变化，请重新准备更新")

    def prepare(self):
        self.validate_targets()
        if hasattr(self.backend, "begin"):
            self.backend.begin(540)
        with UpdateLock(self.home):
            token = str(uuid.uuid4())
            stage = self.stage_path(token)
            stage.mkdir(mode=0o700)
            try:
                original = self.originals()
                revision, source, entries = self.backend.fetch(stage)
                self.source_core = source / "core/claude-switch.sh"
                notice = self.daemon_notice(source, entries)
                if self.current(entries, revision):
                    shutil.rmtree(stage)
                    return {"state": "current", "version": revision,
                            "message": self.message_with_notice("界面和核心已是最新正式版本", notice)}
                new_core = stage / "new-core.sh"
                new_core.write_text(inject_config(self.source_core.read_text(encoding="utf-8"),
                                                 self.core.read_text(encoding="utf-8")), encoding="utf-8")
                new_core.chmod(0o700)
                self.backend.command(["/bin/bash", "-n", str(new_core)])
                shutil.copyfile(source / "core/stun-probe.py", stage / "new-stun.py")
                (stage / "new-stun.py").chmod(0o600)
                self.backend.build(source, stage / "new-app.app", self.app, revision, entries)
                self.backend.audit(new_core)
                record = {"schema": 1, "token": token, "created": time.time(), "phase": "prepared",
                          "version": revision, "notice": notice, "app": str(self.app), "core": str(self.core), "stun": str(self.stun),
                          "original": original, "new": {"app": tree_digest(stage / "new-app.app"),
                          "core": digest(new_core), "stun": digest(stage / "new-stun.py")}}
                self.assert_originals(record)
                shutil.copyfile(Path(__file__), stage / "worker.py")
                (stage / "worker.py").chmod(0o600)
                record["worker"] = digest(stage / "worker.py")
                write_json(stage / "receipt.json", record)
                return {"state": "prepared", "version": revision, "token": token,
                        "message": self.message_with_notice("正式安装包下载、校验和完整检查已通过，可以重启完成更新", notice)}
            except BaseException:
                shutil.rmtree(stage)
                raise

    def assert_prepared(self, stage, record, phase="prepared"):
        if record.get("phase") != phase:
            raise UpdateError("更新事务已使用，请重新准备")
        self.assert_originals(record)
        actual = {"app": tree_digest(stage / "new-app.app"), "core": digest(ensure_plain(stage / "new-core.sh", False)),
                  "stun": digest(ensure_plain(stage / "new-stun.py", False))}
        if actual != record["new"] or digest(ensure_plain(stage / "worker.py", False)) != record["worker"]:
            raise UpdateError("更新暂存工件发生变化，已中止")

    def apply(self, token, pid, ready_timeout=10):
        self.validate_targets()
        if pid < 2 or pid == os.getpid() or not alive(pid):
            raise UpdateError("旧 App 进程标识无效")
        with UpdateLock(self.home):
            stage, record = self.receipt(token)
            self.assert_prepared(stage, record)
            # Mark once before detaching, so a duplicate apply cannot start another worker.
            record["phase"] = "starting"
            write_json(stage / "receipt.json", record)
            try:
                self.backend.spawn_worker(stage / "worker.py", self.app, self.core, token, pid)
            except (OSError, UpdateError):
                record["phase"] = "prepared"
                write_json(stage / "receipt.json", record)
                raise UpdateError("无法启动更新进程，原版本未改变")
        deadline = time.monotonic() + ready_timeout
        while time.monotonic() < deadline:
            ready_path = stage / "worker-ready.json"
            if ready_path.exists():
                ready = read_json(ready_path)
                if ready == {"token": token, "version": record["version"]}:
                    return {"state": "restarting", "version": record["version"], "message": "更新已准备，正在重启切换器"}
                break
            if (stage / "result.json").exists():
                break
            time.sleep(0.05)
        write_json(stage / "cancel.json", {"token": token})
        raise UpdateError("更新进程未能接管，原 App 将保持运行，请重试")

    def ack(self, token):
        stage, record = self.receipt(token)
        if record.get("phase") == "rolled_back":
            raise UpdateError("更新失败，已恢复旧版本")
        if record.get("phase") == "rollback_failed":
            raise UpdateError("更新失败，自动恢复未完成；备份已保留，请手动恢复")
        if record.get("phase") != "awaiting_ack" or time.time() > record.get("ackDeadline", 0):
            raise UpdateError("更新启动确认已过期或无效")
        if self.originals() != record["new"]:
            raise UpdateError("更新启动确认与安装文件不匹配")
        ack_path = stage / "ack.json"
        if ack_path.exists() or ack_path.is_symlink():
            raise UpdateError("更新启动确认已使用")
        notice = record.get("notice", "")
        if notice not in {"", DAEMON_CHANGED, DAEMON_UNKNOWN, DAEMON_MISSING}:
            raise UpdateError("更新事务提示信息无效")
        write_json(ack_path, {"token": token, "version": record["version"]})
        return {"state": "updated", "version": record["version"],
                "message": self.message_with_notice("界面和核心已完成更新", notice)}

    def worker(self, token, pid, exit_timeout=120, ack_timeout=45, interval=0.2):
        stage = self.stage_path(token)
        if pid < 2:
            raise UpdateError("旧 App 进程标识无效")
        # apply releases its short-lived lock before the detached process acquires it.
        deadline = time.monotonic() + 5
        while True:
            try:
                lock = UpdateLock(self.home)
                lock.__enter__()
                break
            except UpdateError:
                if time.monotonic() >= deadline:
                    return
                time.sleep(interval)
        installed = []
        app_process = None
        record = None
        initial_phase = None
        authorized = False
        try:
            stage, record = self.receipt(token)
            initial_phase = record.get("phase")
            self.validate_targets()
            self.assert_prepared(stage, record, "starting")
            authorized = True
            record["phase"] = "waiting_for_exit"
            write_json(stage / "receipt.json", record)
            write_json(stage / "worker-ready.json", {"token": token, "version": record["version"]})
            stop_at = time.monotonic() + exit_timeout
            while alive(pid):
                if (stage / "cancel.json").exists():
                    raise UpdateError("更新已取消，原 App 保持运行")
                if time.monotonic() >= stop_at:
                    raise UpdateError("旧 App 未退出，更新已取消")
                time.sleep(interval)
            # Revalidate after waiting: no overwrite of intervening installs.
            self.validate_targets()
            self.assert_prepared(stage, record, "waiting_for_exit")
            if (stage / "cancel.json").exists():
                raise UpdateError("更新已取消")
            record["phase"] = "installing"
            write_json(stage / "receipt.json", record)
            items = [("core", self.core, stage / "new-core.sh", stage / "previous-core.sh"),
                     ("stun", self.stun, stage / "new-stun.py", stage / "previous-stun.py"),
                     ("app", self.app, stage / "new-app.app", stage / "previous-app.app")]
            for name, target, fresh, backup in items:
                if backup.exists() or backup.is_symlink():
                    raise UpdateError("更新备份路径已存在，已中止")
                existed = target.exists()
                if existed:
                    os.replace(target, backup)
                installed.append((name, target, backup, existed))
                os.replace(fresh, target)
            if self.originals() != record["new"]:
                raise UpdateError("替换后工件校验失败")
            # Validate the installed new probe together with the new core before launching the GUI.
            self.backend.audit(self.core)
            record["phase"] = "awaiting_ack"
            record["ackDeadline"] = time.time() + ack_timeout
            write_json(stage / "receipt.json", record)
            app_process = self.backend.launch(self.app, token)
            stop_at = time.monotonic() + ack_timeout
            while time.monotonic() < stop_at:
                if app_process.poll() is not None:
                    raise UpdateError("新版 App 启动后退出")
                if (stage / "ack.json").exists():
                    acknowledgement = read_json(stage / "ack.json")
                    if acknowledgement != {"token": token, "version": record["version"]}:
                        raise UpdateError("新版 App 启动确认无效")
                    if self.originals() != record["new"]:
                        raise UpdateError("新版 App 确认后工件发生变化")
                    record["phase"] = "updated"
                    write_json(stage / "receipt.json", record)
                    write_json(stage / "result.json", {"state": "updated", "version": record["version"],
                                                       "message": "界面和核心已更新，旧版本备份已保留"})
                    return
                time.sleep(interval)
            raise UpdateError("新版 App 未确认启动，已回滚")
        except BaseException:
            if app_process is not None and app_process.poll() is None:
                with contextlib.suppress(OSError):
                    app_process.terminate()
                with contextlib.suppress(Exception):
                    app_process.wait(timeout=5)
                if app_process.poll() is None:
                    with contextlib.suppress(OSError):
                        app_process.kill()
                    with contextlib.suppress(Exception):
                        app_process.wait(timeout=5)
            rollback_ok = True
            for _, target, backup, existed in reversed(installed):
                try:
                    if target.exists():
                        if target.is_dir():
                            shutil.rmtree(target)
                        else:
                            target.unlink()
                    if existed:
                        os.replace(backup, target)
                except OSError:
                    rollback_ok = False
            if record is not None and (authorized or initial_phase == "starting"):
                record["phase"] = "rolled_back" if rollback_ok else "rollback_failed"
                with contextlib.suppress(Exception):
                    write_json(stage / "receipt.json", record)
                    write_json(stage / "result.json", {"state": "error", "version": record["version"],
                        "message": "更新失败，已恢复旧版本" if rollback_ok else "更新失败，备份已保留，请手动恢复"})
            if rollback_ok and not alive(pid) and (authorized or initial_phase == "starting"):
                with contextlib.suppress(Exception):
                    # A failed pre-swap validation must also restore the visible old UI after it quit.
                    if tree_digest(self.app) == record["original"]["app"]:
                        self.backend.launch(self.app, token)
        finally:
            lock.__exit__(None, None, None)


def read_plist(path):
    try:
        ensure_plain(path, False)
        value = plistlib.loads(Path(path).read_bytes())
        if not isinstance(value, dict):
            raise ValueError()
        return value
    except (ValueError, OSError) as error:
        raise UpdateError("App 配置信息无效") from error


def interrupted(_signum, _frame):
    raise UpdateError("更新已取消，原版本或回滚备份已保留")


def main():
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("check", "prepare", "apply", "ack", "_worker"))
    parser.add_argument("--app", required=True)
    parser.add_argument("--core", required=True)
    parser.add_argument("--token")
    parser.add_argument("--pid", type=int)
    args = parser.parse_args()
    try:
        if os.geteuid() == 0:
            raise UpdateError("桌面更新只允许普通用户执行，不接受管理员权限")
        updater = Updater(args.app, args.core)
        if args.command == "check":
            result = updater.check()
        elif args.command == "prepare":
            result = updater.prepare()
        elif args.command == "ack":
            result = updater.ack(args.token)
        elif args.command == "apply":
            result = updater.apply(args.token, args.pid or 0)
        else:
            updater.worker(args.token, args.pid or 0)
            return 0
    except (UpdateError, OSError, ValueError, KeyError, TypeError) as error:
        message = str(error) if isinstance(error, UpdateError) else "更新操作失败，已保留原版本和可用备份"
        result = {"state": "error", "message": message}
        print(json.dumps(result, ensure_ascii=False))
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
