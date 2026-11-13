#!/usr/bin/env python3
"""Weak-network measurement (spec §4.3): runs RappTestPage through A's service, the rapp-weaknet proxy and
B's hub + rapp-session, and writes a markdown table.

usage: scripts/measure-weak.py --profile s0|n1|n2|n3|n4|lan [--path direct|relay] --minutes M [--seed N] --out FILE.md
Needs: cargo build --release (rust/), swift build -c release, bash scripts/testpage-app.sh.
Reads the frame number drawn by the test page out of the decoded frames; one clock (CLOCK_UPTIME_RAW) for all times.
"""
import argparse, bisect, collections, os, queue, shutil, signal, statistics, struct, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
from rig import Rig, RigError, ROOT
from bside import BSide, uptime_ns

APP_ID = "dev.rapp.testpage"
APP_BUNDLE = os.path.join(ROOT, ".build/RappTestPage.app")
APP_EXE = "RappTestPage.app/Contents/MacOS/RappTestPage"
PAGE_DOWN = 121
BACKOFF = (1, 2, 4, 8, 15)  # seconds, then 15 for ever (same policy as the GUI)
FLIP_TIMEOUT = 30.0  # a flip that is not readable after this long counts as failed
EDITOR_LIMIT = 300.0  # the whole typing phase
RECOVERY_LIMIT = 120.0  # no readable flip this long after the network is back: needs a human
NS = 1e9

# What §4.3 asks for (None = not asked), by profile.
TARGET_OPEN = {"n1": 8, "n2": 15, "n3": 8, "n4": 5}
TARGET_FLIP = {"n1": 3, "n2": 5, "n3": 3, "n4": 2}
TARGET_RECOVERY = {"n1": 5, "n4": 5}

RULES = """Rules (fixed in the script):
- **readable**: the frame number read from the screen equals the expected page and no newer frame arrives for 1 s;
  the time is the arrival of that last frame.
- **flip**: PageDown sent -> readable. Flips started during an outage, or overlapping one, are not counted.
- **recovery**: after the network is back, PageDown every 0.5 s; the probe credited is the last one sent at or before the
  first frame showing a new page, and only if that page is readable within 3 s of its send (else restart from the screen as it is);
  recovery = that PageDown's send time - the time the network came back.
- **outage edges** are computed from the profile's outage schedule and the proxy's start time (known to within tens of ms),
  not from its once-a-second stats.
- **auto-reconnect** (the script's own loop, hub `open` with `reconnect`): when rapp-session reports `disconnected`
  (not "taken over" or "... quit"), reopen after 1, 2, 4, 8, 15, 15... s.
- **typing**: 200 distinct characters in 10 pastes of 20, 300 s for all ten; an unconfirmed paste is re-sent after reconnect; the editor's file is
  compared with the text as a multiset of characters (missing / extra).
- **screen latency** (no v7 stats yet): the draw time of a frame number in the clip's marks file -> arrival of that number at B."""


def uptime_s():
    return uptime_ns() / NS


def pids():
    out = subprocess.run(["pgrep", "-f", APP_EXE], capture_output=True, text=True).stdout
    return {int(x) for x in out.split()}


class TestApp:
    """RappTestPage started by this script; stopped by PID."""

    def __init__(self, *args):
        before = pids()
        if before:
            sys.exit(f"RappTestPage is already running (pids {sorted(before)}); stop it first")
        subprocess.run(["open", "-n", APP_BUNDLE, "--args", *args], check=True)
        end = time.time() + 15
        while time.time() < end:
            new = pids() - before
            if new:
                self.pid = new.pop()
                time.sleep(1)
                return
            time.sleep(0.2)
        sys.exit("RappTestPage did not start")

    def alive(self):
        return self.pid in pids()

    def stop(self):
        try:
            os.kill(self.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        end = time.time() + 5
        while time.time() < end and self.alive():
            time.sleep(0.1)
        if self.alive():
            os.kill(self.pid, signal.SIGKILL)


class Live:
    """B's session with the script's own auto-reconnect loop. `frames` and `events` survive reconnects."""

    def __init__(self, rig, app_id):
        self.rig, self.app_id = rig, app_id
        self.frames, self.events = [], queue.Queue()
        self.bside = None
        self.sid = None
        self.terminal = None  # reason of a disconnect that is not retried
        self.reconnects = 0
        self.opened_once = False
        self.stop_flag = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def connected(self):
        b = self.bside
        return b is not None and b.ready and b.disconnected is None

    def last_frame_t(self):
        return self.bside.last_frame_t if self.bside else 0

    def key(self, code):
        if self.bside:
            self.bside.send({"cmd": "key", "keyCode": code, "modifiers": 0})

    @staticmethod
    def retried(reason):
        return not ("taken over" in reason or reason.endswith(" quit"))

    def _run(self):
        attempt = 0
        lost = False
        while not self.stop_flag.is_set():
            b = self.bside
            if b is not None and b.ready:
                attempt = 0
            if b is None or b.disconnected is not None:
                if b is not None:
                    if not self.retried(b.disconnected):
                        self.terminal = b.disconnected
                        return
                    b.close()
                    self.rig.close_session(self.sid)
                    self.bside = None
                    lost = True
                    self.reconnects += 1
                if lost or attempt:
                    if self.stop_flag.wait(BACKOFF[min(attempt, len(BACKOFF) - 1)]):
                        return
                    attempt += 1
                try:
                    self.sid, port, token = self.rig.open(self.app_id, reconnect=self.opened_once)
                except RigError as e:
                    print(f"  open failed: {e}", file=sys.stderr)
                    lost = True
                    continue
                self.opened_once = True
                lost = False
                self.bside = BSide(port, token, "color16", 30, 1.0, frames=self.frames, events=self.events)
            self.stop_flag.wait(0.1)

    def close(self):
        self.stop_flag.set()
        self.thread.join(5)
        if self.bside:
            self.bside.close()
            self.rig.close_session(self.sid)


def settled(live, expected, since_ns, at_least=False):
    """Arrival (ns) of the last frame once the screen reads `expected` (or, with `at_least`, a later page:
    recovery probes overlap, so an earlier probe's page may already be superseded) and nothing newer came for 1 s."""
    if not live.frames:
        return None
    t, mark = live.frames[-1]
    if t < since_ns or (mark < expected if at_least else mark != expected) or live.last_frame_t() != t or uptime_ns() - t < NS:
        return None
    return t


def last_mark(live):
    return live.frames[-1][1] if live.frames else None


def wait_until(pred, seconds):
    end = time.time() + seconds
    while time.time() < end:
        v = pred()
        if v:
            return v
        time.sleep(0.05)
    return None


# ---------------------------------------------------------------- phases


def credit_probe(live, rec, res):
    """Recovery: credit only the probe whose own PageDown caused the first new page. That is the last probe sent
    at or before the first frame showing a page beyond `m0`; it counts if its page was readable within 3 s of
    its send. Otherwise the probes so far are written off and the search restarts from the screen as it is."""
    first = next(((t, m) for t, m in live.frames[rec["idx"]:] if m > rec["m0"]), None)
    if first is None:
        return
    t_first, _ = first
    sent = [t for t in rec["probes"] if t <= t_first]
    if not sent:  # a frame that no probe of ours can have caused (old queued data): move the baseline
        rec["m0"] = first[1]
        rec["idx"] = len(live.frames)
        return
    t_ready = settled(live, rec["m0"] + 1, t_first, at_least=True)
    if not t_ready:
        return
    if t_ready - sent[-1] <= 3 * NS:
        res["recovery"].append((sent[-1] - rec["back"]) / NS)
        rec.clear()
    else:
        rec.update(m0=last_mark(live), idx=len(live.frames), probes=[])


def phase_reading(rig, seconds, res):
    app = TestApp("--reading")
    live = Live(rig, APP_ID)
    t0 = uptime_ns()
    try:
        t = wait_until(lambda: settled(live, 0, t0), 120)
        res["open"] = (t - t0) / NS if t else None
        end = time.time() + seconds
        pending = None  # (t_send, expected)
        recovery = None  # dict(back, m0, idx, probes=[t_send])
        was_down = rig.down_at(uptime_ns())
        next_flip = 0.0
        while time.time() < end or recovery or pending:
            if time.time() > end + 150 or live.terminal:
                break
            now = uptime_ns()
            now_down = rig.down_at(now)
            if now_down and not was_down:
                recovery = None
                res["outages"] += 1
            if was_down and not now_down and last_mark(live) is not None:
                recovery = dict(back=rig.last_back_ns(now), m0=last_mark(live), idx=len(live.frames), probes=[], next=0.0)
                pending = None
            was_down = now_down
            tick = time.time()
            if recovery:
                if tick >= recovery["next"] and live.frames:
                    recovery["next"] = tick + 0.5
                    recovery["probes"].append(uptime_ns())
                    live.key(PAGE_DOWN)
                credit_probe(live, recovery, res)
                if not recovery:
                    recovery = None
                elif (uptime_ns() - recovery["back"]) / NS > RECOVERY_LIMIT:
                    res["stuck"] += 1
                    recovery = None
            elif pending:
                t_send, expected = pending
                t_ready = settled(live, expected, t_send)
                if t_ready:
                    if not rig.outage_between(t_send, t_ready):
                        res["flips"].append((t_ready - t_send) / NS)
                    pending = None
                    next_flip = time.time() + 0.5
                elif (uptime_ns() - t_send) / NS > FLIP_TIMEOUT:
                    if not rig.outage_between(t_send, now):
                        res["flip_timeouts"] += 1
                        print(f"  flip timeout: expected page {expected}, screen reads {last_mark(live)}", file=sys.stderr)
                    pending = None
            elif not now_down and live.connected() and live.frames and time.time() < end and time.time() >= next_flip:
                pending = (uptime_ns(), last_mark(live) + 1)
                live.key(PAGE_DOWN)
            time.sleep(0.05)
    finally:
        res["reconnects"] += live.reconnects
        if live.terminal:
            res["human"].append(f"reading: {live.terminal}")
        live.close()
        if not app.alive():
            res["crashes"].append("RappTestPage (reading)")
        app.stop()


def send_segment(live, seq, text, deadline):
    """Paste `text` and wait for its paste_result. Re-sent only after a reconnect (never while the session
    lives: that would duplicate text if only the answer was slow)."""
    while time.time() < deadline and not live.terminal:
        bside = live.bside
        if not live.connected():
            time.sleep(0.2)
            continue
        bside.send({"cmd": "paste", "seq": seq, "text": text})
        while time.time() < deadline and bside.disconnected is None:
            try:
                ev = live.events.get(timeout=0.2)
            except queue.Empty:
                continue
            if ev.get("event") == "paste_result" and ev.get("seq") == seq:
                return ev.get("error") in (None, "")
        if bside.disconnected is None:
            return False
    return False


def phase_editor(rig, res):
    original = "".join(chr(0x4E00 + i) for i in range(200))
    path = os.path.join(rig.work, "editor.txt")
    app = TestApp("--editor", path)
    live = Live(rig, APP_ID)
    try:
        wait_until(lambda: live.connected(), 120)
        time.sleep(1)
        deadline = time.time() + EDITOR_LIMIT  # one deadline for all ten pastes
        for i in range(10):
            if not send_segment(live, i + 1, original[i * 20:(i + 1) * 20], deadline):
                res["unconfirmed"].append(i + 1)
        time.sleep(1)
        got = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
        a, b = collections.Counter(original), collections.Counter(got)
        res["typing"] = (sum((a - b).values()), sum((b - a).values()), len(got))
    finally:
        res["reconnects"] += live.reconnects
        if live.terminal:
            res["human"].append(f"editor: {live.terminal}")
        live.close()
        if not app.alive():
            res["crashes"].append("RappTestPage (editor)")
        app.stop()


def phase_clip(rig, seconds, res):
    marks = os.path.join(rig.work, "marks.bin")
    app = TestApp("--clip", "--marks", marks)
    live = Live(rig, APP_ID)
    try:
        wait_until(lambda: live.frames, 120)
        t_start = uptime_ns()
        end = time.time() + seconds
        while time.time() < end and not live.terminal:
            time.sleep(0.5)
        t_end = uptime_ns()
    finally:
        res["reconnects"] += live.reconnects
        if live.terminal:
            res["human"].append(f"clip: {live.terminal}")
        frames = list(live.frames)
        live.close()
        if not app.alive():
            res["crashes"].append("RappTestPage (clip)")
        app.stop()
    data = open(marks, "rb").read()
    draws = collections.defaultdict(list)  # mark -> draw times, in order
    for off in range(0, len(data) - len(data) % 10, 10):
        n, ns = struct.unpack_from("<HQ", data, off)
        draws[n].append(ns)
    lat = []  # (arrival, latency_s)
    for t, mark in frames:
        if t < t_start or t > t_end:
            continue
        times = draws.get(mark)
        i = bisect.bisect_right(times, t) - 1 if times else -1
        if i >= 0:
            lat.append((t, (t - times[i]) / NS))
    res["latency"] = [(t - t_start) / NS for t, _ in lat], [v for _, v in lat], (t_end - t_start) / NS


# ---------------------------------------------------------------- report


def fmt_s(v):
    return f"{v:.2f} s"


def latency_bins(res):
    if not res.get("latency"):
        return []
    ts, vals, total = res["latency"]
    width = 300.0
    bins = []
    for k in range(max(1, int(-(-total // width)))):
        lo, hi = k * width, min((k + 1) * width, total)
        v = [x for t, x in zip(ts, vals) if lo <= t < hi]
        if v:
            bins.append((lo / 60, hi / 60, statistics.median(v), len(v)))
    return bins


def report(args, res):
    p = args.profile
    rows = []

    def target(table):
        return f"<= {table[p]} s" if p in table else "-"

    o = res["open"]
    rows.append(("open to first readable screen", fmt_s(o) if o is not None else "n/a (not readable in 120 s)", target(TARGET_OPEN)))
    fl = res["flips"]
    if fl:
        cell = f"median {fmt_s(statistics.median(fl))} (n={len(fl)}, {res['flip_timeouts']} not readable in {FLIP_TIMEOUT:.0f} s)"
    else:
        cell = f"n/a (no flip completed; {res['flip_timeouts']} timed out)"
    rows.append(("page flip, median", cell, target(TARGET_FLIP)))
    miss, extra, size = res["typing"]
    rows.append(("200 characters typed, identical",
                 f"missing {miss}, extra {extra} (editor file has {size}); "
                 + (f"{len(res['unconfirmed'])} paste(s) unconfirmed or failed (#{', #'.join(map(str, res['unconfirmed']))})"
                    if res["unconfirmed"] else "all 10 pastes confirmed"), "identical" if p in TARGET_FLIP else "-"))
    rc = res["recovery"]
    if rc:
        cell = f"median {fmt_s(statistics.median(rc))} (n={len(rc)}, max {fmt_s(max(rc))})"
    elif res["outages"]:
        cell = f"n/a ({res['outages']} outage(s), none recovered within the run)"
    else:
        cell = f"n/a (no outage in {p} during the reading phase)"
    rows.append(("network back to usable", cell, target(TARGET_RECOVERY)))
    bins = latency_bins(res)
    cell = "; ".join(f"{lo:g}-{hi:.2g} min: {m * 1000:.0f} ms (n={n})" for lo, hi, m, n in bins) or "n/a (no frames matched)"
    rows.append(("screen latency over time (median per 5 min)", cell, "does not grow"))
    crash = f"{len(res['crashes'])} crashed ({', '.join(res['crashes']) or 'none'}); {len(res['human']) + res['stuck']} needed a human"
    if res["human"]:
        crash += f" ({'; '.join(res['human'])})"
    if res["stuck"]:
        crash += f" ({res['stuck']} recovery not readable within {RECOVERY_LIMIT:.0f} s)"
    rows.append(("crash / needs a click", crash + f"; {res['reconnects']} auto-reconnect(s)", "0 / 0"))

    out = [f"# weak-network run: profile {p}, path {args.path}, {args.minutes:g} min, seed {args.seed}", "",
           "| task | result | target (§4.3) |", "|---|---|---|"]
    out += [f"| {a} | {b} | {c} |" for a, b, c in rows]
    out += ["", RULES]
    if p == "s0":
        ok = lambda b: "pass" if b else "FAIL"
        grow = "n/a (needs at least 2 five-minute bins)"
        if len(bins) >= 2:
            grow = ok(bins[-1][2] - bins[0][2] <= 0.5) + f" (first bin {bins[0][2]:.2f} s, last {bins[-1][2]:.2f} s, allowed +0.5 s)"
        rec = "n/a (no recovery measured)" if not rc else ok(max(rc) <= 5) + f" (max {max(rc):.2f} s)"
        new = "n/a (no flip)" if not fl else ok(statistics.median(fl) <= 2) + f" (median {statistics.median(fl):.2f} s)"
        text = ok(miss == 0 and extra == 0) + f" (missing {miss}, extra {extra})"
        out += ["", "## Step 1 acceptance (s0)", "", "| check | result |", "|---|---|",
                f"| new screen <= 2 s | {new} |", f"| latency does not grow | {grow} |",
                f"| recovery <= 5 s | {rec} |", f"| text not lost | {text} |"]
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--profile", required=True, choices=["s0", "n1", "n2", "n3", "n4", "lan"])
    ap.add_argument("--path", default="direct", choices=["direct", "relay"])
    ap.add_argument("--minutes", type=float, required=True)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    if not os.path.isdir(APP_BUNDLE):
        sys.exit("run bash scripts/testpage-app.sh first")
    total = args.minutes * 60
    reading_s = max(20.0, total * 0.3)
    clip_s = max(20.0, total - reading_s - 10)
    res = dict(open=None, flips=[], flip_timeouts=0, typing=(200, 0, 0), recovery=[], outages=0, stuck=0,
               reconnects=0, unconfirmed=[], crashes=[], human=[], latency=None)
    work = tempfile.mkdtemp(prefix="rapp-weak-")
    rig = Rig(args.path, args.profile, args.seed, work)
    try:
        print(f"work dir {work}; proxy port {rig.proxy_port}", file=sys.stderr)
        phase_reading(rig, reading_s, res)
        phase_editor(rig, res)
        phase_clip(rig, clip_s, res)
        res["crashes"] += [f"{n} (rig)" for n in rig.alive()]
    finally:
        rig.close()
    text = report(args, res)
    with open(args.out, "w") as f:
        f.write(text)
    print(text)
    if not (res["crashes"] or res["human"] or res["stuck"]):
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
