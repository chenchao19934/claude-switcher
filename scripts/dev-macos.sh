#!/bin/bash
# 仓库内的 macOS 开发入口；不安装核心脚本或系统服务。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build/dev"
BINARY="$BUILD/MenuBarFixture"
FAKE_CORE="$ROOT/tests/fixtures/macos-dev-core.sh"

usage() {
    cat <<'EOF'
用法：bash scripts/dev-macos.sh <命令>
  doctor             检查 macOS 开发工具（不联网）
  build              编译隔离 UI 演示到 build/dev/MenuBarFixture
  run [--dark]       重新编译并启动隔离 UI 演示（假数据）
  test               运行仓库现有隔离回归
  package [版本号]   构建正式 App、ZIP、DMG 和安装包到 build/
EOF
}

require_tools() {
    if [ "$(uname -s)" != Darwin ]; then
        echo "此开发入口只支持 macOS。" >&2
        exit 1
    fi
    for tool in "$@"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            if [ "$tool" = node ]; then
                echo "完整回归需要 Node.js；请安装 Node.js 后重试。UI 构建不需要 Node.js。" >&2
            else
                echo "缺少工具：$tool；请先安装 Xcode Command Line Tools（xcode-select --install）。" >&2
            fi
            exit 1
        fi
    done
}

build_demo() {
    require_tools swiftc python3
    mkdir -p "$BUILD/module-cache"
    swiftc -g -Onone -parse-as-library -warnings-as-errors \
        -D CLAUDE_SWITCHER_TESTS \
        -target "$(uname -m)-apple-macos13.0" \
        -module-cache-path "$BUILD/module-cache" \
        "$ROOT/app/main.swift" "$ROOT/tests/MenuBarFixture.swift" \
        -o "$BINARY" -framework SwiftUI -framework AppKit
    echo "隔离演示已构建：$BINARY"
}

COMMAND="${1:-doctor}"
if [ "$#" -gt 0 ]; then shift; fi
case "$COMMAND" in
    doctor)
        [ "$#" -eq 0 ] || { usage >&2; exit 2; }
        require_tools swiftc python3 git curl sips iconutil plutil codesign ditto hdiutil
        printf 'macOS %s (%s)\n' "$(sw_vers -productVersion)" "$(uname -m)"
        xcode-select -p
        swiftc --version
        python3 --version
        if command -v node >/dev/null 2>&1; then
            printf '规则回归工具 Node（仅 UI 开发可省略）：'
            node --version
        else
            echo "Node 未安装；可构建 UI，运行完整 test 前需安装 Node.js。"
        fi
        echo "开发工具齐备；隔离演示无需 Claude、代理或管理员权限。"
        ;;
    build)
        [ "$#" -eq 0 ] || { usage >&2; exit 2; }
        build_demo
        ;;
    run)
        if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != --dark ]; }; then
            usage >&2
            exit 2
        fi
        build_demo
        echo "正在启动隔离演示，所有检查均为假数据；从盾牌菜单退出后可重新构建。"
        exec "$BINARY" "$FAKE_CORE" "$@"
        ;;
    test)
        [ "$#" -eq 0 ] || { usage >&2; exit 2; }
        require_tools python3 swiftc node
        cd "$ROOT"
        exec python3 -B -m unittest discover -s tests -v
        ;;
    package)
        [ "$#" -le 1 ] || { usage >&2; exit 2; }
        require_tools swiftc sips iconutil plutil codesign ditto hdiutil
        exec /bin/bash "$ROOT/scripts/package-macos.sh" "${1:-0.0.0-dev}"
        ;;
    help|--help|-h) usage ;;
    *) usage >&2; exit 2 ;;
esac
