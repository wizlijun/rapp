"""Shared by measure-video.py and measure-weak.py: the clip's marks file and the screen-latency match.

Marks file: 10-byte records, u16 LE frame number + u64 LE CLOCK_UPTIME_RAW ns, one per draw.
Frames from BSide: (arrival_uptime_ns, mark) in arrival order, same clock.
"""
import bisect, collections, struct

NS = 1e9


def load_marks(path):
    """mark -> draw times (ns), in draw order."""
    with open(path, "rb") as f:
        data = f.read()
    draws = collections.defaultdict(list)
    for off in range(0, len(data) - len(data) % 10, 10):
        n, ns = struct.unpack_from("<HQ", data, off)
        draws[n].append(ns)
    return draws


def first_arrivals(frames):
    """(arrival, mark) of the first arrival of each run of equal marks (a resend of the same frame is not new)."""
    out, last = [], None
    for t, m in frames:
        if m != last:
            out.append((t, m))
        last = m
    return out


def latencies(frames, draws):
    """[(arrival, latency_s)], one per first arrival: arrival minus the latest draw of that mark before it."""
    lat = []
    for t, m in first_arrivals(frames):
        times = draws.get(m)
        i = bisect.bisect_right(times, t) - 1 if times else -1
        if i >= 0:
            lat.append((t, (t - times[i]) / NS))
    return lat


def _selftest():
    draws = {1: [100, 400], 2: [200]}
    frames = [(150, 1), (160, 1), (250, 2), (450, 1), (460, 1)]
    assert first_arrivals(frames) == [(150, 1), (250, 2), (450, 1)]
    got = latencies(frames, draws)
    assert [(t, round(v * NS)) for t, v in got] == [(150, 50), (250, 50), (450, 50)], got
    assert latencies([(50, 1)], draws) == []  # arrives before any draw
    assert latencies([(50, 9)], draws) == []  # unknown mark
    print("marks.py ok")


if __name__ == "__main__":
    _selftest()
