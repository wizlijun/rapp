#!/usr/bin/env python3
"""Tests for emit_plan.py. Run: /usr/bin/python3 -I integrations/claude-code/hooks/emit_plan_test.py

A fake `rapp` goes first on PATH and records its argv, NUL after each argument."""
import json, os, stat, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HOOK = os.path.join(HERE, "emit_plan.py")

PLAN = """# Plan

1. **Read** the `config` module
2) Add a `parser` for the input
3. Write tests for the *parser*
4. Update the docs
5. Tidy up
"""


class Run:
    def __init__(self, stdin, term="t1", rapp_exit=0, with_rapp=True):
        self.tmp = tempfile.mkdtemp()
        self.argv_file = os.path.join(self.tmp, "argv.txt")
        if with_rapp:
            fake = os.path.join(self.tmp, "rapp")
            with open(fake, "w") as f:
                f.write('#!/bin/sh\nfor a in "$@"; do printf "%%s\\0" "$a" >> "%s"; done\nexit %d\n'
                        % (self.argv_file, rapp_exit))
            os.chmod(fake, os.stat(fake).st_mode | stat.S_IXUSR)
            subprocess.run([fake], capture_output=True)  # warm up: a fresh script's first run can be slow
        env = {"PATH": self.tmp + ":/usr/bin:/bin"}
        if term is not None:
            env["RAPP_TERM"] = term
        p = subprocess.run(["/usr/bin/python3", "-I", HOOK], input=stdin, capture_output=True,
                           text=True, env=env, timeout=20)
        self.code, self.out, self.err = p.returncode, p.stdout, p.stderr
        self.argv = open(self.argv_file).read().split("\0")[:-1] if os.path.exists(self.argv_file) else None


def payload(plan):
    return json.dumps({"tool_name": "ExitPlanMode", "tool_input": {"plan": plan}})


class EmitPlan(unittest.TestCase):
    def test_three_numbered_lines(self):
        r = Run(payload(PLAN))
        self.assertEqual(r.code, 0)
        self.assertEqual(r.out, "")
        self.assertEqual(r.argv, ["emit", "info",
                                  "Read the config module\nAdd a parser for the input\nWrite tests for the parser",
                                  "--key", "plan-rule:t1"])
        self.assertNotIn("*", r.argv[2])
        self.assertNotIn("`", r.argv[2])

    def test_no_rapp_term_does_nothing(self):
        for term in (None, ""):
            r = Run(payload(PLAN), term=term)
            self.assertEqual((r.code, r.out, r.argv), (0, "", None))

    def test_always_exits_zero(self):
        r = Run(payload(PLAN), rapp_exit=1)
        self.assertEqual((r.code, r.out), (0, ""))
        self.assertIsNotNone(r.argv)

    def test_missing_binary_exits_zero(self):
        r = Run(payload(PLAN), with_rapp=False)
        self.assertEqual((r.code, r.out), (0, ""))

    def test_no_numbered_line_does_nothing(self):
        r = Run(payload("Just some prose\n- a bullet\n"))
        self.assertEqual((r.code, r.out, r.argv), (0, "", None))

    def test_bad_stdin_exits_zero(self):
        for s in ("", "not json", "{}", "[]", '{"tool_input": null}'):
            r = Run(s)
            self.assertEqual((r.code, r.out, r.argv), (0, "", None), s)

    def test_no_plan_text_on_output(self):
        r = Run(payload(PLAN), rapp_exit=1)
        self.assertNotIn("parser", r.out + r.err)

    def test_settings_example_is_valid(self):
        with open(os.path.join(HERE, "settings.example.json")) as f:
            s = json.load(f)
        entry = s["hooks"]["PreToolUse"][0]
        self.assertEqual(entry["matcher"], "ExitPlanMode")
        self.assertEqual(entry["hooks"][0]["type"], "command")
        self.assertIn("emit_plan.py", entry["hooks"][0]["command"])


if __name__ == "__main__":
    unittest.main()
