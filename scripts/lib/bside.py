"""B side of the measurement rig: one rapp-session worker fed through the hub's embedded port.

Packets on its stdout are `u32 length` + body; body[0] = 0 JSON event, 1 frame (24-byte header
`u32 w, u32 h, 4 x f32 region` then w*h*4 BGRA pixels). Only the frame mark is decoded from frames.
"""
import json, os, queue, struct, subprocess, threading, time

from frame_mark import read_mark

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SESSION = os.path.join(ROOT, "rust/target/release/rapp-session")
MARK_ORIGIN, MARK_CELL = 12, 24  # points, from Sources/RappCore/FrameMark.swift
PAGE_H = 720  # RappTestPage content height in points (Sources/rapp-testpage/main.swift)


def uptime_ns():
    return time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)


class BSide:
    def __init__(self, port, token, mode="color16", fps=30, density=1.0, frames=None, events=None):
        """`frames` / `events` may be passed to keep appending to the lists of an earlier (lost) session."""
        self.events = events if events is not None else queue.Queue()
        self.frames = frames if frames is not None else []  # (uptime_ns when the frame had arrived, mark)
        self.last_frame_t = 0  # arrival of the latest frame of any kind, readable or not
        self.ready = False
        self.windows = []
        self.frame_count = 0
        self.unreadable = 0  # frames whose mark could not be read
        self.disconnected = None  # reason once rapp-session reported it
        self._lock = threading.Lock()
        self.p = subprocess.Popen([SESSION], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  bufsize=0)
        self.send_raw(dict(port=port, token=token, mode=mode, fps=fps, density=density))
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()

    def send_raw(self, obj):
        try:
            self.p.stdin.write((json.dumps(obj) + "\n").encode())
        except (OSError, ValueError):
            pass

    def send(self, cmd):
        with self._lock:
            self.send_raw(cmd)

    def _exact(self, n):
        data = bytearray(n)
        view = memoryview(data)
        while view:
            got = self.p.stdout.readinto(view)
            if not got:
                raise EOFError
            view = view[got:]
        return data

    def _mark(self, header, pixels):
        w, h = struct.unpack_from("<II", header, 0)
        rx, ry, rw, rh = struct.unpack_from("<4f", header, 8)
        win = next((x for x in self.windows if "RappTestPage" in (x.get("title") or "")), None)
        if win is None or rw <= 0:
            return None
        scale = w / rw
        # The window rect includes the macOS title bar; the test page's content is always PAGE_W x PAGE_H pt
        # and the strip sits at its origin. (win.x - rx) is the window's offset inside the canvas.
        title = max(0.0, win["h"] - PAGE_H)
        x0 = round((win["x"] - rx + MARK_ORIGIN) * scale)
        y0 = round((win["y"] - ry + title + MARK_ORIGIN) * scale)
        return read_mark(pixels, w, x0, y0, round(MARK_CELL * scale))

    def _read(self):
        try:
            while True:
                n = struct.unpack("<I", self._exact(4))[0]
                body = self._exact(n)
                if body[0] == 0:
                    ev = json.loads(bytes(body[1:]))
                    if ev.get("event") == "windows":
                        self.windows = ev["windows"]
                    elif ev.get("event") == "ready":
                        self.ready = True
                    elif ev.get("event") == "disconnected":
                        self.disconnected = ev.get("reason") or "closed"
                    self.events.put(ev)
                elif body[0] == 1:
                    t = uptime_ns()
                    self.frame_count += 1
                    self.last_frame_t = t
                    mark = self._mark(body[1:25], memoryview(body)[25:])
                    if mark is None:
                        self.unreadable += 1
                    else:
                        self.frames.append((t, mark))
        except (EOFError, OSError, ValueError, struct.error):
            pass
        if self.disconnected is None:
            self.disconnected = "worker exited"
            self.events.put({"event": "disconnected", "reason": self.disconnected})

    def wait_event(self, name, timeout):
        """First event called `name` within `timeout` s (other events are dropped), or None."""
        end = time.time() + timeout
        while True:
            left = end - time.time()
            if left <= 0:
                return None
            try:
                ev = self.events.get(timeout=left)
            except queue.Empty:
                return None
            if ev.get("event") == name:
                return ev

    def exited(self):
        return self.p.poll() is not None

    def close(self):
        try:
            self.p.stdin.close()
        except (OSError, ValueError):
            pass
        try:
            self.p.wait(3)
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.p.wait()
