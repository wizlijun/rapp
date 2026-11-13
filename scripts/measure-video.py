#!/usr/bin/env python3
"""Video measurement (spec §4.2): plays RappTestPage's clip through A's service and B's hub + rapp-session on a
loopback "lan" path, and writes a markdown table with the rows of §4.2.

usage: scripts/measure-video.py --profile lan --mode color16 --density original --fps 30 --minutes M [--seed N] --out FILE.md
Needs: cargo build --release (rust/), cargo build --release -p rapp-testkit, swift build -c release, bash scripts/testpage-app.sh.
Keep the test page window visible and frontmost while it runs: the clip's own frame rate falls when it is not.
Shares TestApp / wait_until with measure-weak.py (one clock, CLOCK_UPTIME_RAW).
"""
import argparse, importlib.util, os, queue, shutil, statistics, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))
from rig import Rig
from bside import BSide, uptime_ns
from marks import load_marks, first_arrivals, latencies

_spec = importlib.util.spec_from_file_location("measure_weak", os.path.join(HERE, "measure-weak.py"))
weak = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(weak)

NS = 1e9
MAX_FPS = 30  # 60 is step 2
TARGETS = {  # §4.2, S1 column (1920x1080 canvas, 60 fps)
    "fps": ">= 57", "gap": "<= 34 ms", "stall": "<= 100 ms", "latency": "<= 50 / 80 ms", "rate": "<= 20 Mbps",
    "encode": "<= 8 ms",
}


def pct(vals, q):
    s = sorted(vals)
    return s[min(len(s) - 1, int(q * len(s)))] if s else None


def measure(args, work):
    rig = Rig("direct", args.profile, args.seed, work)
    marks = os.path.join(work, "marks.bin")
    app = weak.TestApp("--clip", "--marks", marks)
    bside = None
    crashes, traffic = [], []
    try:
        sid, port, token = rig.open(weak.APP_ID)
        density = 1.0 if args.density == "original" else float(args.density)
        bside = BSide(port, token, args.mode, args.fps, density)
        if not weak.wait_until(lambda: bside.frames, 120):
            sys.exit("no frame with a readable mark within 120 s (is the test page window visible?)")
        t_start = uptime_ns()
        end = time.time() + args.minutes * 60
        while time.time() < end and bside.disconnected is None:
            try:
                ev = bside.events.get(timeout=0.5)
            except queue.Empty:
                continue
            if ev.get("event") == "traffic":
                traffic.append((uptime_ns(), ev["bytes"], ev["frames"]))
        t_end = uptime_ns()
        disconnected = bside.disconnected
        frames = list(bside.frames)
        unreadable, total_frames = bside.unreadable, bside.frame_count
    finally:
        if bside:
            bside.close()
        if not app.alive():
            crashes.append("RappTestPage")
        app.stop()
        crashes += [f"{n} (rig)" for n in rig.alive()]
        rig.close()
    draws = load_marks(marks)
    return dict(frames=frames, draws=draws, traffic=[x for x in traffic if x[0] >= t_start], t_start=t_start,
                t_end=t_end, crashes=crashes, disconnected=disconnected, unreadable=unreadable,
                total_frames=total_frames, drawn=sum(len(v) for v in draws.values()))


def analyse(r):
    out = {}
    # first arrival of each distinct frame, over all frames (so a run that began before t_start is not counted
    # again), then only those inside the window
    firsts = [(t, m) for t, m in first_arrivals(r["frames"]) if r["t_start"] <= t <= r["t_end"]]
    secs = int((r["t_end"] - r["t_start"]) // NS)
    per = [0] * secs
    for t, _ in firsts:
        k = int((t - r["t_start"]) // NS)
        if k < secs:
            per[k] += 1
    out["per_sec"] = per
    # gaps include the edges: t_start -> first distinct frame, last distinct frame -> t_end (no frame at all: the
    # whole window is one gap)
    stamps = [r["t_start"]] + [t for t, _ in firsts] + [r["t_end"]]
    out["gaps"] = [(b - a) / NS for a, b in zip(stamps, stamps[1:])]
    out["lat"] = [v for t, v in latencies(r["frames"], r["draws"]) if r["t_start"] <= t <= r["t_end"]]
    out["traffic"] = [b * 8 / 1e6 for _, b, _ in r["traffic"]]  # Mbps, one value per second
    return out


def report(args, r, a):
    ms = lambda v: f"{v * 1000:.0f} ms"
    per, gaps, lat, tr = a["per_sec"], a["gaps"], a["lat"], a["traffic"]
    rows = [
        ("distinct frames per second, median / min",
         f"{statistics.median(per):g} / {min(per)} (n={len(per)} s)" if per else "n/a", TARGETS["fps"]),
        ("gap between two frames, p99", f"{ms(pct(gaps, .99))} (n={len(gaps)})" if gaps else "n/a", TARGETS["gap"]),
        ("longest stall", f"{ms(max(gaps))} (n={len(gaps)})" if gaps else "n/a", TARGETS["stall"]),
        ("screen latency, median / p95",
         f"{ms(statistics.median(lat))} / {ms(pct(lat, .95))} (n={len(lat)})" if lat else "n/a (no frames matched)",
         TARGETS["latency"]),
        ("bitrate, mean / max per second",
         f"{statistics.mean(tr):.1f} / {max(tr):.1f} Mbps (n={len(tr)} s)" if tr else "n/a (no traffic events)",
         TARGETS["rate"]),
        ("A encode time per frame", "无（第二步）", TARGETS["encode"]),
    ]
    crash = f"{len(r['crashes'])} crashed ({', '.join(r['crashes']) or 'none'})"
    if r["disconnected"]:
        crash += f"; session ended early: {r['disconnected']}"
    rows.append(("crash", crash, "0"))
    out = [f"# video run: profile {args.profile}, mode {args.mode}, density {args.density}, {args.fps} fps, "
           f"{args.minutes:g} min, seed {args.seed}", "",
           "| row | result | target (§4.2 S1, 60 fps) |", "|---|---|---|"]
    out += [f"| {x} | {y} | {z} |" for x, y, z in rows]
    out += ["", f"Frames at B: {r['total_frames']} received, {r['unreadable']} with unreadable mark; "
            f"{r['drawn']} frames drawn by the clip (marks file).",
            "", "Rules (fixed in the script):",
            "- **distinct frames per second**: frame numbers read from the screen, counted once at their first arrival, "
            "in whole seconds from the first readable frame (the partial last second is dropped).",
            "- **gap / stall**: time between first arrivals of consecutive distinct frame numbers, including the edges "
            "(start of the window -> first distinct frame, last distinct frame -> end of the window); stall = the largest.",
            "- **screen latency**: the draw time of a frame number in the clip's marks file -> the first arrival of that "
            "frame at B (same clock); resends of the same frame are not counted.",
            "- **bitrate**: bytes per second of rapp-session's `traffic` events."]
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--profile", required=True, choices=["lan", "s0", "n1", "n2", "n3", "n4"])
    ap.add_argument("--mode", required=True)
    ap.add_argument("--density", required=True, help="original or a number")
    ap.add_argument("--fps", type=int, required=True)
    ap.add_argument("--minutes", type=float, required=True)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    if args.fps > MAX_FPS or args.fps < 1:
        sys.exit(f"--fps must be 1..{MAX_FPS} (60 fps is step 2)")
    if args.density != "original":
        try:
            float(args.density)
        except ValueError:
            sys.exit("--density must be 'original' or a number")
    if not os.path.isdir(weak.APP_BUNDLE):
        sys.exit("run bash scripts/testpage-app.sh first")
    work = tempfile.mkdtemp(prefix="rapp-video-")
    print(f"work dir {work}", file=sys.stderr)
    r = measure(args, work)
    text = report(args, r, analyse(r))
    with open(args.out, "w") as f:
        f.write(text)
    print(text)
    if not r["crashes"]:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
