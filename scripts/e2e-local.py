#!/usr/bin/env python3
"""M4 end-to-end on one Mac: rapp-relay + rapp-service + rapp-hub with the
real Swift rapp-host and rapp-client. For each path (lan, relay) it opens an
app through the hub, waits, takes a screenshot, then kicks the session over
the service IPC (what the --cm window's 断开 button sends) and waits for the
hub's `closed` event. Each round also checks the client logged at least one
window from the host's window table (protocol v4). A third round ("id@ip") uses a hub with no relay at all
that adds A by the first `id@ip` A's status reports.

usage: scripts/e2e-local.py <work dir> [app id]   (default com.apple.Safari)
Needs: swift build -c release, and cargo build --release in rust/.
With RAPP_E2E_BUNDLE=<path to rapp.app> the service, hub, host and client all
come from the app's Contents/MacOS and RAPP_BIN_DIR is not set, so the
"workers sit next to the service" lookup is what gets tested.
"""
import json, os, re, socket, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUST = os.path.join(ROOT, "rust/target/release")
SWIFT = os.path.join(ROOT, ".build/release")
WORK = os.path.abspath(sys.argv[1])
APP = sys.argv[2] if len(sys.argv) > 2 else "com.apple.Safari"
BUNDLE = os.environ.get("RAPP_E2E_BUNDLE")
SERVICE_DIR = os.path.join(BUNDLE, "Contents/MacOS") if BUNDLE else RUST
KEY = "e2e-key"
PASSWORD = "e2epass1"


def free_udp_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def wait_for(pred, seconds, what):
    end = time.time() + seconds
    while time.time() < end:
        v = pred()
        if v:
            return v
        time.sleep(0.1)
    sys.exit(f"timed out waiting for {what}")


def read_text(path):
    try:
        with open(path) as f:
            return f.read()
    except FileNotFoundError:
        return ""


class Hub:
    def __init__(self, home, bins, force):
        env = dict(os.environ, RAPP_HOME=home)
        if force:
            env["RAPP_FORCE_PATH"] = force
        if bins:
            env["RAPP_BIN_DIR"] = bins
        self.log = os.path.join(WORK, f"hub-{force}.log")
        self.p = subprocess.Popen([os.path.join(SERVICE_DIR, "rapp-hub")], env=env, text=True, bufsize=1,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(self.log, "w"))
        self.req = 0

    def send(self, **cmd):
        self.req += 1
        cmd["req"] = self.req
        self.p.stdin.write(json.dumps(cmd) + "\n")
        return self.req

    def wait(self, event, seconds=20, **match):
        end = time.time() + seconds
        while time.time() < end:
            line = self.p.stdout.readline()
            if not line:
                sys.exit(f"hub exited while waiting for {event}")
            ev = json.loads(line)
            print("  hub:", line.strip())
            if ev.get("event") == "error":
                sys.exit(f"hub error: {ev}")
            if ev.get("event") == event and all(ev.get(k) == v for k, v in match.items()):
                return ev
        sys.exit(f"timed out waiting for hub {event}")

    def stop(self):
        self.p.stdin.close()
        self.p.wait(10)


def ipc(port, token, cmd):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as s:
        f = s.makefile("rw")
        f.write(json.dumps({"token": token}) + "\n")
        f.write(json.dumps(cmd) + "\n")
        f.flush()
        return json.loads(f.readline())


def main():
    os.makedirs(WORK, exist_ok=True)
    bins = None if BUNDLE else os.path.join(WORK, "bin")
    a_home, b_home = os.path.join(WORK, "a"), os.path.join(WORK, "b")
    for d in (a_home, b_home):
        os.makedirs(d, exist_ok=True)
    for name in ("rapp-host", "rapp-client") if bins else ():
        os.makedirs(bins, exist_ok=True)
        link = os.path.join(bins, name)
        if os.path.lexists(link):
            os.remove(link)
        os.symlink(os.path.join(SWIFT, name), link)

    port = free_udp_port()
    relay_addr = f"127.0.0.1:{port}"
    procs = []
    try:
        procs.append(subprocess.Popen(
            [os.path.join(RUST, "rapp-relay"), "--key", KEY, "--listen", relay_addr,
             "--db", os.path.join(WORK, "relay.json")],
            stderr=open(os.path.join(WORK, "relay.log"), "w")))
        os.makedirs(os.path.join(a_home, "local"), exist_ok=True)
        with open(os.path.join(a_home, "local", "service.json"), "w") as f:
            json.dump({"relay": relay_addr, "key": KEY, "id": None, "secret": "", "name": "e2e-a",
                       "password": PASSWORD, "port": 0, "ipc_port": 0}, f)
        os.chmod(os.path.join(a_home, "local", "service.json"), 0o600)
        svc_log = os.path.join(WORK, "service.log")
        svc_env = dict(os.environ, RAPP_HOME=a_home, RAPP_GUI="/nonexistent")
        if bins:
            svc_env["RAPP_BIN_DIR"] = bins
        procs.append(subprocess.Popen(
            [os.path.join(SERVICE_DIR, "rapp-service")], env=svc_env,
            stderr=open(svc_log, "w")))
        ipc_port = int(wait_for(lambda: (re.search(r"ipc 127\.0\.0\.1:(\d+)", read_text(svc_log)) or [None, None])[1],
                                10, "service ipc port"))
        # The ID exists before registration (A picks it), so wait for the relay's answer.
        host_id = wait_for(lambda: (re.search(r"registered as (\d+)", read_text(svc_log)) or [None, None])[1],
                           10, "relay registration")
        token = read_text(os.path.join(a_home, "local", "ipc.token")).strip()
        print(f"relay {relay_addr}; A registered as {host_id}; ipc {ipc_port}")
        os.makedirs(os.path.join(b_home, "local"), exist_ok=True)
        with open(os.path.join(b_home, "local", "service.json"), "w") as f:
            json.dump({"relay": relay_addr, "key": KEY}, f)

        c_home = os.path.join(WORK, "c")  # no service.json: this hub has no relay
        os.makedirs(c_home, exist_ok=True)
        at = ipc(ipc_port, token, {"cmd": "status"})["lan_ids"][0]
        for force in ("lan", "relay", "id@ip"):
            print(f"== path {force} ==")
            if force == "id@ip":
                hub, want = Hub(c_home, bins, None), "lan"
                hub.send(cmd="add_host", id=at, password=PASSWORD)
                print(f"  adding {at} with no relay")
            else:
                hub, want = Hub(b_home, bins, force), force
                hub.send(cmd="add_host", id=host_id, password=PASSWORD)
            hub.wait("host_added")
            hub.send(cmd="apps", id=host_id)
            apps = hub.wait("apps")
            assert any(a["app"] == APP for a in apps["apps"]), f"{APP} not in apps"
            hub.send(cmd="open", id=host_id, app=APP)
            opened = hub.wait("opened")
            assert opened["path"] == want, f"opened over {opened['path']}, wanted {want}"
            time.sleep(5)
            # The client logs "windows: N" to stderr, which the hub writes to its log.
            counts = [int(n) for n in re.findall(r"^windows: (\d+)$", read_text(hub.log), re.M)]
            assert counts and counts[-1] >= 1, f"client saw no window (log windows lines: {counts})"
            print(f"  client windows: {counts[-1]}")
            shot = os.path.join(WORK, f"shot-{force.replace('@', '-at-')}.png")
            subprocess.run(["screencapture", "-x", shot])
            status = ipc(ipc_port, token, {"cmd": "status"})
            sessions = [s for s in status["sessions"] if s["app"] == APP]
            print("  service sessions:", sessions)
            assert sessions, "service lists no session"
            print("  kick:", ipc(ipc_port, token, {"cmd": "kick", "sid": sessions[0]["sid"]}))
            closed = hub.wait("closed", sid=opened["sid"])
            print(f"  OK {force}: opened path={opened['path']}, closed reason={closed.get('reason')!r}, screenshot {shot}")
            hub.stop()
    finally:
        for p in procs:
            p.terminate()
        for p in procs:
            p.wait(5)


if __name__ == "__main__":
    main()
