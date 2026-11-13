"""Shared test rig: process helpers used by e2e-local.py, and `Rig`, the weak-network setup used by
measure-weak.py (A's service + optional relay + rapp-weaknet + B's hub).

Needs: cargo build --release (rust/), cargo build --release -p rapp-testkit, swift build -c release.
"""
import json, os, queue, re, socket, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RUST = os.path.join(ROOT, "rust/target/release")
SWIFT = os.path.join(ROOT, ".build/release")
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
    def __init__(self, home, bins, force, work, service_dir=RUST):
        env = dict(os.environ, RAPP_HOME=home)
        if force:
            env["RAPP_FORCE_PATH"] = force
        if bins:
            env["RAPP_BIN_DIR"] = bins
        self.log = os.path.join(work, f"hub-{force}.log")
        self.p = subprocess.Popen([os.path.join(service_dir, "rapp-hub")], env=env, text=True, bufsize=1,
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


def weaknet_binary():
    for d in ("release", "debug"):
        p = os.path.join(ROOT, "rust/target", d, "rapp-weaknet")
        if os.path.exists(p):
            return p
    sys.exit("rapp-weaknet not built: cargo build --release -p rapp-testkit")


class RigError(Exception):
    pass


class Rig:
    """A's service and B's hub with rapp-weaknet in between.

    path "direct": proxy sits between B's hub and A's service port; B's hub has no relay and adds
    `id@127.0.0.1:<proxy>`. path "relay": a relay runs, A registers with it directly, and B's
    service.json names the proxy as the relay (proxy -> relay), with the hub forced onto "relay".
    `down_at(t)` / `outage_between(a, b)` / `last_back_ns(t)` give the proxy's outage state exactly.
    """

    def __init__(self, path, profile, seed, work=None):
        assert path in ("direct", "relay")
        self.path = path
        self.work = work or tempfile.mkdtemp(prefix="rapp-rig-")
        self.procs = []
        self.outages = []
        self.proxy_start_ns = 0
        self.stats = {}
        self.events = queue.Queue()
        self.closed = set()
        self._lock = threading.Lock()
        try:
            self._start(profile, seed)
        except BaseException:
            self.close()
            raise

    def _spawn(self, argv, log, **kw):
        p = subprocess.Popen(argv, stderr=open(os.path.join(self.work, log), "w"), **kw)
        self.procs.append(p)
        return p

    def _start(self, profile, seed):
        a_home, b_home = os.path.join(self.work, "a"), os.path.join(self.work, "b")
        bins = os.path.join(self.work, "bin")
        os.makedirs(bins)
        os.makedirs(os.path.join(a_home, "local"))
        os.makedirs(os.path.join(b_home, "local"))
        os.symlink(os.path.join(SWIFT, "rapp-host"), os.path.join(bins, "rapp-host"))
        os.symlink(os.path.join(SWIFT, "rapp-client"), os.path.join(bins, "rapp-client"))
        relay_addr = None
        a_cfg = {"id": None, "secret": "", "name": "rig-a", "password": PASSWORD, "port": 0, "ipc_port": 0}
        if self.path == "relay":
            relay_addr = f"127.0.0.1:{free_udp_port()}"
            self._spawn([os.path.join(RUST, "rapp-relay"), "--key", KEY, "--listen", relay_addr,
                         "--db", os.path.join(self.work, "relay.json")], "relay.log")
            a_cfg.update(relay=relay_addr, key=KEY)
        with open(os.path.join(a_home, "local", "service.json"), "w") as f:
            json.dump(a_cfg, f)
        os.chmod(os.path.join(a_home, "local", "service.json"), 0o600)
        svc_log = os.path.join(a_home, "local", "logs", "service.log")
        self._spawn([os.path.join(RUST, "rapp-service")], "service.err",
                    env=dict(os.environ, RAPP_HOME=a_home, RAPP_GUI="/nonexistent", RAPP_BIN_DIR=bins))
        ipc_port = int(wait_for(lambda: (re.search(r'"ipc_port":(\d+)', read_text(svc_log)) or [None, None])[1],
                                10, "service ipc port"))
        if relay_addr:
            self.host_id = wait_for(lambda: (re.search(r"registered as (\d+)", read_text(svc_log)) or [None, None])[1],
                                    10, "relay registration")
        token = read_text(os.path.join(a_home, "local", "ipc.token")).strip()
        status = ipc(ipc_port, token, {"cmd": "status"})
        self.host_id = status["id"]
        a_port = int(status["lan_ids"][0].rsplit(":", 1)[1])

        target = relay_addr or f"127.0.0.1:{a_port}"
        weak = self._spawn([weaknet_binary(), "--listen", "127.0.0.1:0", "--to", target, "--profile", profile,
                            "--seed", str(seed)], "weaknet.log", stdout=subprocess.PIPE, text=True, bufsize=1)
        first = json.loads(weak.stdout.readline())
        assert first.get("event") == "listening", first
        self.proxy_port = first["port"]
        # rapp-weaknet's outages are a fixed schedule from its start, so the exact edges are computed here
        # (its once-a-second stats line would only give them to within 1 s).
        self.proxy_start_ns = time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)
        prof = profile if os.path.exists(profile) else os.path.join(ROOT, "rust/testkit/profiles", profile + ".json")
        with open(prof) as f:
            self.outages = json.load(f).get("outages", [])
        threading.Thread(target=self._read_stats, args=(weak,), daemon=True).start()

        if self.path == "relay":
            with open(os.path.join(b_home, "local", "service.json"), "w") as f:
                json.dump({"relay": f"127.0.0.1:{self.proxy_port}", "key": KEY}, f)
        self.hub = Hub(b_home, bins, "relay" if self.path == "relay" else None, self.work)
        self.procs.append(self.hub.p)
        threading.Thread(target=self._read_hub, daemon=True).start()
        if self.path == "relay":
            self._hub_cmd("host_added", 120, cmd="add_host", id=self.host_id, password=PASSWORD)
        else:
            self._hub_cmd("host_added", 120, cmd="add_host", id=f"{self.host_id}@127.0.0.1:{self.proxy_port}",
                          password=PASSWORD)

    def _read_stats(self, weak):
        for line in weak.stdout:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if ev.get("event") == "stats":
                self.stats = ev

    def _windows(self, o, upto_s):
        """(start, end) in seconds since the proxy started of o's outages that begin before `upto_s`."""
        k = 0
        while o["every_s"] > 0 and o["offset_s"] + k * o["every_s"] < upto_s:
            s = o["offset_s"] + k * o["every_s"]
            yield s, s + o["for_s"]
            k += 1

    def down_at(self, t_ns):
        t = (t_ns - self.proxy_start_ns) / 1e9
        return any(s <= t < e for o in self.outages for s, e in self._windows(o, t + 1e-9))

    def outage_between(self, a_ns, b_ns):
        """True if any outage overlaps [a, b]."""
        a, b = ((x - self.proxy_start_ns) / 1e9 for x in (a_ns, b_ns))
        return any(s <= b and e > a for o in self.outages for s, e in self._windows(o, b + 1e-9))

    def last_back_ns(self, t_ns):
        """When the network last came back (end of the latest outage that is over at t_ns)."""
        t = (t_ns - self.proxy_start_ns) / 1e9
        ends = [e for o in self.outages for s, e in self._windows(o, t) if e <= t]
        return self.proxy_start_ns + int(max(ends) * 1e9) if ends else t_ns

    def _read_hub(self):
        for line in self.hub.p.stdout:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if ev.get("event") == "closed":
                self.closed.add(ev.get("sid"))
            self.events.put(ev)

    def _hub_cmd(self, event, timeout, **cmd):
        with self._lock:
            req = self.hub.send(**cmd)
        end = time.time() + timeout
        while time.time() < end:
            try:
                ev = self.events.get(timeout=0.2)
            except queue.Empty:
                continue
            if ev.get("req") == req and ev.get("event") == "error":
                raise RigError(ev.get("error"))
            if ev.get("event") == event and (ev.get("req") in (req, None)):
                return ev
        raise RigError(f"timed out waiting for hub {event}")

    def open(self, app, reconnect=False, timeout=60):
        """Open `app` embedded; returns (sid, port, token). `reconnect` marks a retry of a lost session."""
        cmd = dict(cmd="open", id=self.host_id, app=app, embed=True)
        if reconnect:
            cmd["reconnect"] = True
        ev = self._hub_cmd("opened", timeout, **cmd)
        return ev["sid"], ev["port"], ev["token"]

    def close_session(self, sid):
        try:
            with self._lock:
                self.hub.send(cmd="close", sid=sid)
        except (OSError, ValueError):
            pass

    def alive(self):
        """Names of the processes this rig started that have exited."""
        return [os.path.basename(p.args[0]) for p in self.procs if p.poll() is not None]

    def close(self):
        """Stop everything this rig started, by handle (no name matching)."""
        try:
            self.hub.p.stdin.close()
        except (AttributeError, OSError, ValueError):
            pass
        for p in self.procs:
            if p.poll() is None:
                p.terminate()
        for p in self.procs:
            try:
                p.wait(10)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()
