#!/usr/bin/env python3
"""Exercise the built GUI on Omarchy/Hyprland 0.56+ using a private session bus.

Temporarily opens test windows and switches to an empty workspace. Existing
apps/data are untouched, and the original focused window is restored afterward.
Usage: python3 scripts/test-linux-single-gui.py [path/to/rapp-gui]
"""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("binary", nargs="?", default="gui/build/linux/x64/release/bundle/rapp")
parser.add_argument("--stress-cycles", type=int, default=0,
                    help="repeat close/reopen, resize and maximize on test windows only")
parser.add_argument("--backend", choices=["wayland", "x11"], default="wayland")
args = parser.parse_args()
assert 0 <= args.stress_cycles <= 100
binary = Path(args.binary).resolve()


def hypr(query):
    return json.loads(subprocess.check_output(["hyprctl", query, "-j"]))


def dispatch(expression):
    subprocess.run(["hyprctl", "dispatch", expression], check=True, capture_output=True)


def focus(address):
    dispatch("hl.dsp.focus({window=" + json.dumps("address:" + address) + "})")


def close(address):
    dispatch("hl.dsp.window.close({window=" + json.dumps("address:" + address) + "})")


def until(predicate):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError("timed out waiting for GUI state")


previous = hypr("activewindow").get("address")
monitors = hypr("monitors")
assert monitors and all(m.get("dpmsStatus", True) for m in monitors), \
    "Unlock and wake the desktop before running GUI focus tests"
assert not any("LOCK" in m.get("solitaryBlockedBy", []) for m in monitors), \
    "Unlock the desktop before running GUI focus tests"
with tempfile.TemporaryDirectory(prefix="rapp-single-gui-") as tmp:
    work = Path(tmp)
    # No service activation directories: tests must not spawn a second portal,
    # keyring or accessibility daemon belonging to the real desktop session.
    config = work / "bus.conf"
    config.write_text('''<busconfig><type>session</type>
<listen>unix:tmpdir=/tmp</listen><policy context="default">
<allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/>
</policy></busconfig>''')
    bus = subprocess.Popen(["dbus-daemon", "--nofork", "--print-address=1",
                            f"--config-file={config}"], stdout=subprocess.PIPE, text=True)
    address = bus.stdout.readline().strip()
    env = dict(os.environ, DBUS_SESSION_BUS_ADDRESS=address,
               RAPP_HOME=str(work / "data"), XDG_CONFIG_HOME=str(work / "config"),
               RAPP_BIN_DIR=str(binary.parent),
               GDK_BACKEND=args.backend, GIO_USE_VFS="local", NO_AT_BRIDGE="1")
    processes = []
    with (work / "gui.log").open("w+") as log:
        def start(args=()):
            process = subprocess.Popen([binary, *args], env=env, stdout=log, stderr=log)
            processes.append(process)
            return process

        def launch(args=()):
            if processes:
                assert any(p.poll() is None for p in processes), "primary GUI exited before launch"
            result = subprocess.run([binary, *args], env=env, stdout=log, stderr=log, timeout=10)
            assert result.returncode == 0

        def windows(process):
            return [w for w in hypr("clients") if w["pid"] == process.pid]

        def window(process, title):
            find = lambda: next((w for w in windows(process) if w["title"] == title), None)
            until(find)
            # window_manager maps the shell before Dart has installed its close
            # listener and tray. Allow the first frame/startup callbacks to run.
            time.sleep(2)
            # Startup fullscreen changes may remap the Wayland surface; use the
            # current compositor address after those callbacks have completed.
            return until(find)

        def hubs(process):
            children = Path(f"/proc/{process.pid}/task/{process.pid}/children").read_text().split()
            found = []
            for pid in children:
                try:
                    if Path(f"/proc/{pid}/exe").resolve(strict=True).name == "rapp-hub":
                        found.append(pid)
                except FileNotFoundError:
                    pass
            return found

        try:
            # A fullscreen application on the user's workspace can intentionally
            # refuse focus changes. Keep all test windows on an unused workspace.
            used = {w["id"] for w in hypr("workspaces")}
            empty = next(i for i in range(1, 11) if i not in used)
            dispatch(f"hl.dsp.focus({{workspace={empty}}})")
            # Automatic connection notifications must not create a process or
            # engine that survives to map a monitor window on the desktop.
            launch(["--cm", "--background"])
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                list(pool.map(lambda _: start(), range(4)))
            until(lambda: sum(p.poll() is None for p in processes) == 1)
            primary = next(p for p in processes if p.poll() is None)
            assert all(p.poll() == 0 for p in processes if p is not primary)
            main = window(primary, "rApp")
            assert len(windows(primary)) == 1
            until(lambda: len(hubs(primary)) == 1)
            original_hubs = hubs(primary)
            print("PASS simultaneous launches create one GUI, main window and hub", flush=True)

            focus(main["address"])
            until(lambda: hypr("activewindow").get("address") == main["address"])
            launch(["--cm", "--background"])
            assert len(windows(primary)) == 1
            assert hypr("activewindow").get("address") == main["address"]
            print("PASS automatic connection manager stays hidden without stealing focus", flush=True)

            close(main["address"])
            until(lambda: not windows(primary))
            launch()
            main = window(primary, "rApp")
            until(lambda: hypr("activewindow").get("address") == main["address"])
            print("PASS launch restores and focuses the hidden main window", flush=True)

            used = {w["id"] for w in hypr("workspaces")}
            empty = next(i for i in range(1, 11) if i not in used)
            dispatch(f"hl.dsp.focus({{workspace={empty}}})")
            launch()
            until(lambda: hypr("activewindow").get("address") == main["address"])
            print("PASS launch focuses the main window from another workspace", flush=True)

            launch(["--cm"])
            cm = window(primary, "rApp 连接管理")
            launch(["--cm"])
            assert len(windows(primary)) == 2, [(w["address"], w["title"]) for w in windows(primary)]
            launch()
            until(lambda: hypr("activewindow").get("address") == main["address"])
            close(cm["address"])
            until(lambda: len(windows(primary)) == 1 and windows(primary)[0]["title"] == "rApp")
            assert primary.poll() is None
            launch(["--cm"])
            cm = window(primary, "rApp 连接管理")
            assert len(windows(primary)) == 2, [(w["address"], w["title"]) for w in windows(primary)]
            assert hubs(primary) == original_hubs
            focus(cm["address"])
            until(lambda: hypr("activewindow").get("address") == cm["address"])
            launch(["--cm", "--background"])
            assert hypr("activewindow").get("address") == cm["address"]
            close(cm["address"])
            until(lambda: len(windows(primary)) == 1 and windows(primary)[0]["title"] == "rApp")
            assert primary.poll() is None
            print("PASS connection manager reuses the process and can close/reopen independently", flush=True)
            if args.stress_cycles:
                selector = json.dumps("address:" + main["address"])
                dispatch(f'hl.dsp.window.float({{action="on",window={selector}}})')
                for cycle in range(args.stress_cycles):
                    launch(["--cm"])
                    until(lambda: len(windows(primary)) == 2)
                    cm = next(w for w in windows(primary) if w["title"] == "rApp 连接管理")
                    selector = json.dumps("address:" + main["address"])
                    for width, height in [(640, 480), (1000, 700), (800, 540)]:
                        dispatch(f"hl.dsp.window.resize({{x={width},y={height},relative=false,window={selector}}})")
                        time.sleep(.08)
                    for action in ["set", "unset"]:
                        dispatch(f'hl.dsp.window.fullscreen({{mode="maximized",action="{action}",window={selector}}})')
                        time.sleep(.08)
                    close(cm["address"])
                    until(lambda: len(windows(primary)) == 1)
                    close(main["address"])
                    until(lambda: not windows(primary))
                    launch(["--cm", "--background"])
                    assert not windows(primary)
                    launch()
                    until(lambda: len(windows(primary)) == 1)
                    assert primary.poll() is None, f"GUI exited in cycle {cycle}"
                    main = windows(primary)[0]
                    assert main["title"] == "rApp"
                    assert hubs(primary) == original_hubs
                time.sleep(1)
                assert primary.poll() is None
                print(f"PASS {args.stress_cycles} close/reopen, resize and maximize cycles", flush=True)
            primary.terminate()
            primary.wait(timeout=10)

            # Starting the connection manager first must not capture normal
            # launches or prevent the main window (and its hub) from opening.
            primary = start(["--cm"])
            cm = window(primary, "rApp 连接管理")
            launch()
            window(primary, "rApp")
            close(cm["address"])
            until(lambda: len(windows(primary)) == 1 and windows(primary)[0]["title"] == "rApp")
            assert primary.poll() is None
            print("PASS --cm-first startup still opens a unique main window", flush=True)
            primary.terminate()
            primary.wait(timeout=10)
            primary = start(["--cm"])
            cm = window(primary, "rApp 连接管理")
            close(cm["address"])
            assert primary.wait(timeout=10) == 0
            print("PASS closing a standalone manager exits without a background engine", flush=True)
            log.flush()
            log.seek(0)
            output = log.read()
            for marker in ["eglMakeCurrent failed", "The implicit view cannot be removed"]:
                assert marker not in output, marker
            print("PASS no EGL make-current or implicit-view removal errors", flush=True)
        except BaseException:
            log.flush()
            log.seek(0)
            print(log.read(), file=sys.stderr)
            raise
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
            bus.terminate()
            bus.wait(timeout=5)
            if previous and any(w["address"] == previous for w in hypr("clients")):
                focus(previous)
