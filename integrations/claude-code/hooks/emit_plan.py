#!/usr/bin/env python3
"""Claude Code PreToolUse hook on ExitPlanMode: send the plan's first three numbered steps to the phone
with `rapp emit info`. Writes no file and prints nothing; always exits 0 so Claude Code carries on."""
import json, os, re, subprocess, sys


def main():
    term = os.environ.get("RAPP_TERM", "")
    if not term:
        return
    try:
        plan = (json.load(sys.stdin).get("tool_input") or {}).get("plan", "")
    except Exception:  # noqa: BLE001
        return
    if not isinstance(plan, str):
        return
    steps = [re.sub(r"[*`]", "", m.group(1)).strip()
             for m in re.finditer(r"(?m)^\s*\d+[.)]\s+(.+)$", plan)]
    steps = [s for s in steps if s][:3]
    if not steps:
        return
    try:
        subprocess.run(["rapp", "emit", "info", "\n".join(steps), "--key", "plan-rule:" + term],
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=3)
    except Exception:  # noqa: BLE001
        pass


try:
    main()
except Exception:  # noqa: BLE001
    pass
sys.exit(0)
