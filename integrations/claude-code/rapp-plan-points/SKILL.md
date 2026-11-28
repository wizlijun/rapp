---
name: rapp-plan-points
description: 出计划、调用 ExitPlanMode 之前，把计划最要紧的三点用 rapp emit 发到手机上。只在 rapp 的终端里用。
---

# 计划要点发到手机

出计划、调 ExitPlanMode 之前，先跑一次：

```
rapp emit info "<三行，每行一句>" --key "plan:$RAPP_TERM"
```

规则：

- 只在环境变量 `RAPP_TERM` 有值时跑。没有值就跳过。
- 三行，每行一句，写计划里最要紧的三点。
- 命令跑失败了也不要紧，照常出计划。
- 不写密码和 token。
- 不写命令和链接。

## 安装（可选，rapp 不会替你装）

1. 把 `rapp-plan-points` 这个文件夹复制到 `~/.claude/skills/`。
2. 重开 Claude Code，计划前它会自己发这三点。

想让 hook 自动发，不靠 skill：把 `hooks/settings.example.json` 的内容合并进 `~/.claude/settings.json`，并把里面的路径改成 `emit_plan.py` 的绝对路径。
