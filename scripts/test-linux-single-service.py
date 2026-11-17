#!/usr/bin/env python3
"""Real process regression: concurrent starts, alternate roots and crash recovery.

Run with no other updated rapp-service running for this user. Existing services
are never stopped. All test data and logs live in a temporary directory.
"""
import concurrent.futures
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1] if len(sys.argv) > 1 else "rust/target/debug/rapp-service").resolve()
address = f"\0com.rapp.service.{os.geteuid()}"


def available():
    with socket.socket(socket.AF_UNIX) as probe:
        try:
            probe.bind(address)
            return True
        except OSError:
            return False


def until(predicate):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("timed out")


if not available():
    sys.exit("An updated rapp-service is already running; it was left untouched.")

with tempfile.TemporaryDirectory(prefix="rapp-single-service-") as tmp:
    work = Path(tmp)
    root = work / "data"
    (root / "local").mkdir(parents=True)
    (root / "local/service.json").write_text(json.dumps({"port": 0, "ipc_port": 0}))
    env = dict(os.environ, RAPP_HOME=str(root), RAPP_LOG_DIR=str(work / "logs"),
               XDG_CONFIG_HOME=str(work / "config"), RAPP_BIN_DIR=str(work / "bin"))
    processes = []
    with (work / "stderr.log").open("w+") as log:
        def start():
            return subprocess.Popen([binary], env=env, stdout=log, stderr=log)

        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
                processes.extend(pool.map(lambda _: start(), range(6)))
            until(lambda: sum(p.poll() is None for p in processes) == 1)
            primary = next(p for p in processes if p.poll() is None)
            assert all(p.poll() == 0 for p in processes if p is not primary)
            token = root / "local/ipc.token"
            until(token.exists)
            original_token = token.read_bytes()
            other = work / "other-data"
            result = subprocess.run([binary], env=dict(env, RAPP_HOME=str(other)),
                                    capture_output=True, text=True, timeout=10)
            assert result.returncode == 0 and "already running" in result.stderr, result
            assert not other.exists(), "duplicate startup touched its data root"
            assert token.read_bytes() == original_token
            assert primary.poll() is None
            print("PASS concurrent starts elect one service; alternate root cannot bypass it")

            primary.kill()
            primary.wait(timeout=5)
            assert available(), "SIGKILL left stale ownership"
            replacement = start()
            processes.append(replacement)
            until(lambda: token.read_bytes() != original_token)
            assert replacement.poll() is None
            replacement.terminate()
            assert replacement.wait(timeout=10) == 0
            assert available()
            print("PASS crash recovery and normal shutdown release ownership")
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
