// Spec §6 default rule packs, verbatim (controller ruling R1). Extended by later tasks.

let genericChatJSON = #"""
{
  "format": "1.0", "id": "generic-chat", "name": "聊天类通用", "rev": 1, "updated": "2026-11-25",
  "ids": [],
  "regions": {
    "sidebar": {"edge": {"from": "left", "min": 160, "max": 420}},
    "main":    {"box": {"rightOf": "sidebar", "top": 0, "right": 0, "bottom": 0}},
    "bottom":  {"box": {"in": "main", "bottom": 0, "height": 160}},
    "button":  {"blob": {"in": "bottom", "round": true, "size": [24, 48], "pick": "rightmost"}},
    "markers": {"blob": {"in": {"strip": {"of": "sidebar", "side": "right", "width": 40}}, "size": [6, 20], "pick": "all"}},
    "tail":    {"box": {"in": "main", "above": "bottom", "height": 240}}
  },
  "signals": {
    "stop":    {"in": "button",  "detect": {"shape": "square"}, "status": "untested"},
    "rowBusy": {"in": "markers", "detect": {"motion": {"window": 0.4}}, "count": true, "status": "untested"}
  },
  "states": [
    {"state": "working", "when": {"any": ["stop", "rowBusy"]}, "hold": 0.6, "release": 2.0},
    {"state": "idle"}
  ],
  "require": ["bottom"]
}
"""#

let chatgptDesktopJSON = #"""
{
  "format": "1.0", "id": "chatgpt-desktop", "name": "ChatGPT", "rev": 1, "updated": "2026-11-25",
  "extends": "generic-chat",
  "ids": ["com.openai.codex"],
  "signals": {
    "rowDot":    {"in": "markers", "detect": {"shape": "dot", "color": "green"}, "count": true, "status": "seen"},
    "workedFor": {"in": "tail", "detect": {"text": ["Worked for*"]}, "needs": ["text"], "status": "seen"},
    "ask":       {"in": "tail", "detect": {"text": ["Allow", "Deny", "允许", "拒绝"]}, "needs": ["text"], "status": "untested"}
  },
  "states": [
    {"state": "blocked", "kind": "permission", "when": {"any": ["ask"]}},
    {"state": "working", "when": {"any": ["stop", "rowBusy"]}, "hold": 0.6, "release": 2.0},
    {"state": "done", "when": {"any": ["rowDot", "workedFor"]}},
    {"state": "idle"}
  ]
}
"""#

let claudeDesktopJSON = #"""
{
  "format": "1.0", "id": "claude-desktop", "name": "Claude", "rev": 1, "updated": "2026-11-25",
  "extends": "generic-chat",
  "ids": ["com.anthropic.claudefordesktop"],
  "signals": {
    "stop":    {"status": "seen"},
    "rowDot":  {"in": "markers", "detect": {"shape": "dot", "color": "green"}, "count": true, "status": "reported"},
    "rowGray": {"in": "markers", "detect": {"shape": "dot", "color": "gray"}, "count": true, "status": "reported"},
    "ask":     {"in": "tail", "detect": {"text": ["Allow", "Deny", "允许", "拒绝"]}, "needs": ["text"], "status": "untested"}
  },
  "states": [
    {"state": "blocked", "kind": "permission", "when": {"any": ["ask"]}},
    {"state": "working", "when": {"any": ["stop", "rowBusy", "rowGray"]}, "hold": 0.6, "release": 2.0},
    {"state": "done", "when": {"any": ["rowDot"]}},
    {"state": "idle"}
  ]
}
"""#

let antigravityAppJSON = #"""
{
  "format": "1.0", "id": "antigravity-app", "name": "Antigravity", "rev": 1, "updated": "2026-11-25",
  "extends": "generic-chat",
  "ids": ["com.google.antigravity"]
}
"""#

