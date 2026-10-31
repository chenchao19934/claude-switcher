#!/bin/bash
# 编译 WidgetKit 扩展；正式嵌入只允许仓库 build/ 下的 App。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build/widget"
EXTENSION="$BUILD/ClaudeSwitcherStatus.appex"
MODE=compile
HOST=""
IDENTITY=""
APP_GROUP=""

usage() {
    cat <<'EOF'
用法：bash scripts/build-macos-widget.sh --compile-only
      bash scripts/build-macos-widget.sh --embed <build/应用.app> \
        --identity '<签名身份>' --app-group '<TeamID>.claude-switcher'

--compile-only  只生成 ad-hoc 扩展到 build/widget/，不注册小组件（默认）
--embed         编译并嵌入仓库 build/ 内已构建的 App，以真实团队身份签名
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --compile-only) MODE=compile; shift ;;
        --embed) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; MODE=embed; HOST="$2"; shift 2 ;;
        --identity) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; IDENTITY="$2"; shift 2 ;;
        --app-group) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; APP_GROUP="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

[ "$(uname -s)" = Darwin ] || { echo "仅支持 macOS。" >&2; exit 1; }
for TOOL in swiftc python3 codesign plutil ditto; do
    command -v "$TOOL" >/dev/null 2>&1 || { echo "缺少工具：$TOOL" >&2; exit 1; }
done
if [ "$MODE" = compile ] && { [ -n "$HOST" ] || [ -n "$IDENTITY" ] || [ -n "$APP_GROUP" ]; }; then
    echo "--compile-only 不接受签名或宿主参数。" >&2
    exit 2
fi

if [ "$MODE" = embed ]; then
    [ -n "$HOST" ] && [ -n "$IDENTITY" ] && [ "$IDENTITY" != - ] && [ -n "$APP_GROUP" ] || {
        echo "嵌入需要真实签名身份与 TeamID 前缀的 App Group。" >&2; exit 2;
    }
fi

# 先验证固定输出与宿主路径，避免跟随符号链接写入已安装版本。
python3 - "$ROOT" "$MODE" "$HOST" "$APP_GROUP" <<'PY'
from pathlib import Path
import re
import sys
root = Path(sys.argv[1])
build = root / "build"
if build.resolve() != build or (build / "widget").resolve() != build / "widget":
    raise SystemExit("拒绝符号链接形式的 build/widget 输出路径")
extension = build / "widget/ClaudeSwitcherStatus.appex"
for child in [extension, extension / "Contents", extension / "Contents/MacOS",
              extension / "Contents/MacOS/ClaudeSwitcherStatus", extension / "Contents/Info.plist"]:
    if child.resolve() != child:
        raise SystemExit("扩展输出包含符号链接，拒绝写入")
if sys.argv[2] == "embed":
    host = Path(sys.argv[3]).absolute()
    if host.resolve() != host or build not in host.parents or host.suffix != ".app":
        raise SystemExit("宿主必须是仓库 build/ 内的真实 .app 目录，不能是符号链接")
    if not (host / "Contents/Info.plist").is_file() or not (host / "Contents/MacOS").is_dir():
        raise SystemExit("宿主缺少 Contents/Info.plist 或 MacOS 目录")
    if any(child.is_symlink() for child in host.rglob("*")):
        raise SystemExit("宿主包含符号链接，拒绝修改")
    if not re.fullmatch(r"[A-Z0-9]{10}\.[A-Za-z0-9][A-Za-z0-9.-]+", sys.argv[4]):
        raise SystemExit("App Group 必须使用 <10位TeamID>.<组名> 格式")
PY

mkdir -p "$BUILD/module-cache" "$EXTENSION/Contents/MacOS"
echo "==> 编译 macOS WidgetKit 扩展"
swiftc -O -parse-as-library -warnings-as-errors -application-extension \
    -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$BUILD/module-cache" \
    "$ROOT/app/StatusWidget.swift" -o "$EXTENSION/Contents/MacOS/ClaudeSwitcherStatus" \
    -framework WidgetKit -framework SwiftUI

python3 - "$EXTENSION" "$HOST" "$APP_GROUP" <<'PY'
from pathlib import Path
import plistlib
import sys
extension, host, group = sys.argv[1:]
version = "0.0.0-dev"
identifier = "local.claude-switcher"
if host:
    info = plistlib.loads((Path(host) / "Contents/Info.plist").read_bytes())
    identifier = info["CFBundleIdentifier"]
    version = info.get("CFBundleVersion", version)
info = {
    "CFBundleExecutable": "ClaudeSwitcherStatus",
    "CFBundleIdentifier": identifier + ".status-widget",
    "CFBundleName": "Claude 状态",
    "CFBundleDisplayName": "Claude 状态",
    "CFBundlePackageType": "XPC!",
    "CFBundleVersion": version,
    "CFBundleShortVersionString": version,
    "LSMinimumSystemVersion": "13.0",
    "NSExtension": {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"},
}
if group:
    info["ClaudeSwitcherAppGroup"] = group
(Path(extension) / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
PY
plutil -lint "$EXTENSION/Contents/Info.plist" >/dev/null

if [ "$MODE" = compile ]; then
    codesign --force -s - "$EXTENSION"
    codesign --verify --strict "$EXTENSION"
    echo "✓ 扩展编译与 ad-hoc 签名验证完成：$EXTENSION"
    echo "仅验证编译，不代表通知中心已注册或 App Group 可用。"
    exit 0
fi

WORK="$(mktemp -d "$BUILD/signing.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
python3 - "$WORK" "$APP_GROUP" "$HOST" <<'PY'
from pathlib import Path
import plistlib
import subprocess
import sys
work, group, host = sys.argv[1:]
extension = {"com.apple.security.app-sandbox": True, "com.apple.security.application-groups": [group]}
(Path(work) / "widget.entitlements").write_bytes(plistlib.dumps(extension))
result = subprocess.run(["codesign", "--display", "--entitlements", ":-", host], capture_output=True)
if result.returncode:
    raise SystemExit("无法读取宿主原有签名，拒绝替换其权限")
host_entitlements = plistlib.loads(result.stdout) if result.stdout.strip() else {}
groups = host_entitlements.setdefault("com.apple.security.application-groups", [])
if not isinstance(groups, list):
    raise SystemExit("宿主已有 App Groups 权限格式无效")
if group not in groups:
    groups.append(group)
(Path(work) / "host.entitlements").write_bytes(plistlib.dumps(host_entitlements))
PY
codesign --force --options runtime --entitlements "$WORK/widget.entitlements" -s "$IDENTITY" "$EXTENSION"
codesign --verify --strict "$EXTENSION"
python3 - "$EXTENSION" "$APP_GROUP" <<'PY'
import subprocess
import sys
result = subprocess.run(["codesign", "-dv", sys.argv[1]], capture_output=True, text=True, check=True)
team = next((line.split("=", 1)[1] for line in result.stderr.splitlines() if line.startswith("TeamIdentifier=")), "")
if team != sys.argv[2].split(".", 1)[0]:
    raise SystemExit("签名证书的 TeamIdentifier 与 App Group 不一致，未修改宿主")
PY

# 所有更改先在工作副本中完成并校验，最后只替换仓库内的构建 App。
mkdir -p "$WORK/staged" "$WORK/backup"
STAGED_HOST="$WORK/staged/$(basename "$HOST")"
ditto "$HOST" "$STAGED_HOST"
mkdir -p "$STAGED_HOST/Contents/PlugIns"
rm -rf "$STAGED_HOST/Contents/PlugIns/ClaudeSwitcherStatus.appex"
ditto "$EXTENSION" "$STAGED_HOST/Contents/PlugIns/ClaudeSwitcherStatus.appex"
python3 - "$STAGED_HOST" "$APP_GROUP" <<'PY'
from pathlib import Path
import plistlib
import sys
path = Path(sys.argv[1]) / "Contents/Info.plist"
info = plistlib.loads(path.read_bytes())
info["ClaudeSwitcherAppGroup"] = sys.argv[2]
types = info.setdefault("CFBundleURLTypes", [])
if not any("claude-switcher" in item.get("CFBundleURLSchemes", []) for item in types):
    types.append({"CFBundleURLName": info["CFBundleIdentifier"], "CFBundleURLSchemes": ["claude-switcher"]})
path.write_bytes(plistlib.dumps(info))
PY
codesign --force --options runtime --entitlements "$WORK/host.entitlements" -s "$IDENTITY" "$STAGED_HOST"
codesign --verify --deep --strict "$STAGED_HOST"
BACKUP="$WORK/backup/$(basename "$HOST")"
mv "$HOST" "$BACKUP"
if ! mv "$STAGED_HOST" "$HOST"; then
    mv "$BACKUP" "$HOST"
    echo "替换构建 App 失败，已恢复原产物。" >&2
    exit 1
fi
echo "✓ 已嵌入并签名：$HOST"
echo "尚未安装、启动或注册本机小组件；按 docs/MACOS-WIDGET.md 完成验收。"
