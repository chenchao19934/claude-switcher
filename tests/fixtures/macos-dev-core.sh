#!/bin/bash
# 仅供 MenuBarFixture 使用。状态只写仓库 build/dev，不调用生产核心或系统命令。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec python3 -B - "$ROOT/build/dev/demo-state.json" "$@" <<'PY'
import json
from pathlib import Path
import sys

state_file = Path(sys.argv[1])
args = sys.argv[2:]
optional = {"IP一致", "DNS", "WebRTC", "客户端语言", "ASN属性", "生态可达性"}
clients = {"clash-verge", "flclash", "shadowrocket", "sing-box", "clashx", "surge"}
state = {
    "current": "A", "accounts": ["A", "B", "C"], "client": "clash-verge",
    "config": {"disabled": [], "allowOptionalFailures": False, "logging": True},
}
if state_file.exists():
    state = json.loads(state_file.read_text(encoding="utf-8"))

def fail(message):
    print("FAIL:隔离演示：" + message)
    sys.exit(2)

def save():
    state_file.parent.mkdir(parents=True, exist_ok=True)
    temporary = state_file.with_suffix(".tmp")
    temporary.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
    temporary.replace(state_file)

command = args[0] if args else ""
if command == "monitor-status" and len(args) == 1:
    print("monitor-version=1\n代理内核=ok\nTUN网卡=ok")
elif command == "checkdetail" and len(args) == 1:
    for key in ("代理内核", "TUN网卡", "出口IP", "IP一致", "时区", "地区", "IPv6",
                "DNS", "WebRTC", "保镖", "规则置顶", "客户端语言", "ASN属性", "生态可达性"):
        status = "skip" if key in state["config"]["disabled"] else "ok"
        if key == "ASN属性" and status != "skip":
            status = "warn"
        print(f"{key}={status}:隔离演示假数据")
elif command == "status" and len(args) == 1:
    fields = ["current=" + state["current"], "accounts=" + ",".join(state["accounts"])]
    for slot in "ABCD":
        fields.append(f"has{slot}={int(slot in state['accounts'])}")
        if slot in state["accounts"]:
            fields.append(f"acc{slot}=10M@demo")
    print(" ".join(fields))
elif command == "switch" and len(args) == 2 and args[1] in "ABCD" and len(args[1]) == 1:
    state["current"] = args[1]
    state["accounts"] = sorted(set(state["accounts"]) | {args[1]})
    save()
    print("OK:隔离演示切换至 " + args[1] + "（未启动 Claude）")
elif command == "get-client" and len(args) == 1:
    print("client=" + state["client"])
elif command == "get-bodyguard-interval" and len(args) == 1:
    value = state.get("bodyguardInterval", 10)
    print(json.dumps({"interval": value, "throttleInterval": value, "registered": True, "activeInterval": value}))
elif command == "set-bodyguard-interval" and len(args) == 2:
    if not args[1].isdigit() or not 2 <= int(args[1]) <= 10:
        fail("保镖模拟周期必须为 2–10 秒")
    value = int(args[1])
    state["bodyguardInterval"] = value
    save()
    print(json.dumps({"interval": value, "throttleInterval": value, "registered": True, "activeInterval": value}))
elif command == "set-client" and len(args) == 2 and args[1] in clients:
    state["client"] = args[1]
    save()
    print("OK:仅保存演示客户端")
elif command == "get-check-config" and len(args) == 1:
    print(json.dumps(state["config"], ensure_ascii=False))
elif command == "set-check-config" and len(args) == 2:
    try:
        config = json.loads(args[1])
    except ValueError:
        fail("设置必须是 JSON")
    if not isinstance(config, dict) or set(config) != {"disabled", "allowOptionalFailures", "logging"}:
        fail("设置字段无效")
    disabled = config["disabled"]
    if not isinstance(disabled, list) or not all(isinstance(key, str) and key in optional for key in disabled):
        fail("仅可跳过六项非关键检查")
    if type(config["allowOptionalFailures"]) is not bool or type(config["logging"]) is not bool:
        fail("设置开关必须为布尔值")
    state["config"] = config
    save()
    print("OK:仅保存演示设置")
elif command == "fix" and len(args) == 1:
    print("FIX:隔离演示，未修改系统")
elif command == "fingerprint" and len(args) == 1:
    print("GPU=ok:隔离演示假数据\n字体=ok:隔离演示假数据")
elif command == "update-check" and len(args) == 1:
    print("隔离演示：未联网检查更新")
else:
    fail("此命令未模拟；不会调用真实核心脚本")
PY
