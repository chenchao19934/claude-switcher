#!/bin/bash
# 仅模拟界面更新结果；不联网、不编译、不修改安装态或启动进程。
set -euo pipefail
exec /usr/bin/python3 -I -B - "$@" <<'PY'
import json
import sys

command = sys.argv[1] if len(sys.argv) > 1 else ""
replies = {
    "check": {"state": "available", "version": "demo-version", "message": "隔离演示：发现模拟新版，未联网检查"},
    # 演示更新停在准备阶段，不能让UI模拟成功后真的退出或重启用户进程。
    "prepare": {"state": "error", "message": "隔离演示：更新流程已模拟，未下载、编译、替换或重启任何 App"},
    "apply": {"state": "error", "message": "隔离演示不提供实际替换或重启"},
    "ack": {"state": "error", "message": "隔离演示没有真实更新事务"},
}
reply = replies.get(command, {"state": "error", "message": "隔离演示未实现此更新操作"})
print(json.dumps(reply, ensure_ascii=False))
raise SystemExit(0 if reply["state"] != "error" else 1)
PY
