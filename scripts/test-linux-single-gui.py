#!/usr/bin/env python3
"""Exercise the built GUI on Omarchy/Hyprland 0.56+ using a private session bus.

Temporarily opens test windows and switches to an empty workspace. Existing
apps/data are untouched, and the original focused window is restored afterward.
Usage: python3 scripts/test-linux-single-gui.py [path/to/rapp-gui]
"""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1] if len(sys.argv) > 1 else
              "gui/build/linux/x64/release/bundle/rapp").resolve()


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
               RAPP_BIN_DIR=str(Path("rust/target/release").resolve()),
               GDK_BACKEND="wayland", GIO_USE_VFS="local", NO_AT_BRIDGE="1")
    processes = []
    with (work / "gui.log").open("w+") as log:
        def start(args=()):
            process = subprocess.Popen([binary, *args], env=env, stdout=log, stderr=log)
            processes.append(process)
            return process

        def launch(args=()):
            result = subprocess.run([binary, *args], env=env, stdout=log, stderr=log, timeout=10)
            assert result.returncode == 0

        def windows(process):
            return [w for w in hypr("clients") if w["pid"] == process.pid]

        def window(process, title):
            found = until(lambda: next((w for w in windows(process) if w["title"] == title), None))
            # window_manager maps the shell before Dart has installed its close
            # listener and tray. Allow the first frame/startup callbacks to run.
            time.sleep(2)
            return found

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
            # Automatic connection notifications must not create a process or
            # engine that survives to map a monitor window on the desktop.
            launch(["--cm", "--background"])
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                list(pool.map(lambda _: start(), range(4)))
            until(lambda: sum(p.poll() is None for p in processes) == 1)
            primary = next(p for p in processes if p.poll() is None)
            assert all(p.poll() == 0 for p in processes if p is not primary)
            main = window(primary, "rapp")
            assert len(windows(primary)) == 1
            until(lambda: len(hubs(primary)) == 1)
            original_hubs = hubs(primary)
            print("PASS simultaneous launches create one GUI, main window and hub", flush=True)

            launch(["--cm", "--background"])
            assert len(windows(primary)) == 1
            assert hypr("activewindow").get("address") == main["address"]
            print("PASS automatic connection manager stays hidden without stealing focus", flush=True)

            close(main["address"])
            until(lambda: not windows(primary))
            launch()
            main = window(primary, "rapp")
            until(lambda: hypr("activewindow").get("address") == main["address"])
            print("PASS launch restores and focuses the hidden main window", flush=True)

            used = {w["id"] for w in hypr("workspaces")}
            empty = next(i for i in range(90, 190) if i not in used)
            dispatch(f"hl.dsp.focus({{workspace={empty}}})")
            launch()
            until(lambda: hypr("activewindow").get("address") == main["address"])
            print("PASS launch focuses the main window from another workspace", flush=True)

            launch(["--cm"])
            cm = window(primary, "rapp 连接管理")
            launch(["--cm"])
            assert len(windows(primary)) == 2, [(w["address"], w["title"]) for w in windows(primary)]
            launch()
            until(lambda: hypr("activewindow").get("address") == main["address"])
            close(cm["address"])
            until(lambda: len(windows(primary)) == 1 and windows(primary)[0]["title"] == "rapp")
            assert primary.poll() is None
            launch(["--cm"])
            cm = window(primary, "rapp 连接管理")
            assert len(windows(primary)) == 2, [(w["address"], w["title"]) for w in windows(primary)]
            assert hubs(primary) == original_hubs
            launch(["--cm", "--background"])
            assert hypr("activewindow").get("address") == cm["address"]
            close(cm["address"])
            until(lambda: len(windows(primary)) == 1 and windows(primary)[0]["title"] == "rapp")
            assert primary.poll() is None
            print("PASS connection manager reuses the process and can close/reopen independently", flush=True)
            primary.terminate()
            primary.wait(timeout=10)

            # Starting the connection manager first must not capture normal
            # launches or prevent the main window (and its hub) from opening.
            primary = start(["--cm"])
            cm = window(primary, "rapp 连接管理")
            launch()
            window(primary, "rapp")
            close(cm["address"])
            until(lambda: len(windows(primary)) == 1 and windows(primary)[0]["title"] == "rapp")
            assert primary.poll() is None
            print("PASS --cm-first startup still opens a unique main window", flush=True)
            primary.terminate()
            primary.wait(timeout=10)
            primary = start(["--cm"])
            cm = window(primary, "rapp 连接管理")
            close(cm["address"])
            assert primary.wait(timeout=10) == 0
            print("PASS closing a standalone manager exits without a background engine", flush=True)
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
