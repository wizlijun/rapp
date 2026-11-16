#!/usr/bin/env python3
"""Host-side check of focusRegion (protocol v12): sent when setStream has the focus bit, not otherwise.

usage: scripts/focus-loopback.py <path to rapp-host>

Starts `rapp-host serve` on 127.0.0.1 (port 0) for Calculator. With setStream's flag byte = 2 (focus) a
focusRegion (type 36) must arrive within 10 s; with the flag byte = 0 none may arrive in the next 3 s.
Calculator is launched by rapp-host itself; if one is already running this script does nothing. At the end
only the processes this script started are stopped, by PID. No input is sent; the token is never printed.
Needs Screen Recording for the host's capture; Accessibility is optional (without it the host still sends
focusRegion, whole window).
"""
import json, os, select, shutil, signal, socket, struct, subprocess, sys, tempfile, threading, time

TOKEN = "runtest123"
APP = "com.apple.calculator"
HELLO, READY, ERROR, SET_STREAM, FOCUS_REGION = 1, 2, 3, 11, 36


def msg(mtype, payload=b""):
    return bytes([mtype]) + struct.pack("<I", len(payload)) + payload


def s16(text):
    b = text.encode()
    return struct.pack("<H", len(b)) + b


def hello(version=12, token=TOKEN):
    return msg(HELLO, bytes([version]) + s16(token) + s16(APP) + bytes([0, 15]) + struct.pack("<f", 1.0))


def set_stream(flags):
    # mode 2 (color16), fps 15, density 1.0, flag byte: bit0 pinned, bit1 focus
    return msg(SET_STREAM, bytes([2, 15]) + struct.pack("<f", 1.0) + bytes([flags]))


def text_of(p):
    return p[2:2 + struct.unpack("<H", p[:2])[0]].decode()


def recv_exact(sock, n, timeout):
    buf = b""
    end = time.time() + timeout
    while len(buf) < n:
        left = end - time.time()
        if left <= 0 or not select.select([sock], [], [], left)[0]:
            raise TimeoutError("timed out reading from host")
        try:
            part = sock.recv(n - len(buf))
        except ConnectionResetError:
            raise EOFError("host reset the connection")
        if not part:
            raise EOFError("host closed the connection")
        buf += part
    return buf


def read_msg(sock, timeout=10):
    head = recv_exact(sock, 5, timeout)
    length = struct.unpack("<I", head[1:])[0]
    return head[0], recv_exact(sock, length, timeout)


def read_until(sock, wanted, timeout=15):
    """Reads (and drops) messages until one of type `wanted`; returns its payload."""
    end = time.time() + timeout
    while True:
        t, p = read_msg(sock, max(0.5, end - time.time()))
        if t == wanted:
            return p
        if t == ERROR and wanted != ERROR:
            raise AssertionError(f"host sent error {text_of(p)!r}")
        if time.time() > end:
            raise TimeoutError(f"no message of type {wanted}")


def connect(port):
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s


class Host:
    """rapp-host serve with a reader thread collecting its stdout events."""

    def __init__(self, binary, errlog):
        self.proc = subprocess.Popen([binary, "serve", "--app", APP, "--bind", "127.0.0.1", "--port", "0",
                                      "--token-env", "T", "--json"], env=dict(os.environ, T=TOKEN),
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errlog, text=True)
        self.events, self.cond, self.port = [], threading.Condition(), None
        threading.Thread(target=self._read, daemon=True).start()
        self.port = self.wait_event(lambda e: e.get("event") == "listening", 20)["port"]

    def _read(self):
        for line in self.proc.stdout:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            with self.cond:
                self.events.append(ev)
                self.cond.notify_all()

    def wait_event(self, pred, timeout=10, since=0):
        end = time.time() + timeout
        with self.cond:
            while True:
                for ev in self.events[since:]:
                    if pred(ev):
                        return ev
                left = end - time.time()
                if left <= 0:
                    raise TimeoutError("expected host event did not appear")
                self.cond.wait(left)

    def mark(self):
        with self.cond:
            return len(self.events)

    def command(self, obj):
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()


def calculator_pids():
    r = subprocess.run(["pgrep", "-x", "Calculator"], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()]


failures = []


def step(name, fn):
    try:
        reason = fn()
        print(f"PASS {name}" + (f": {reason}" if reason else ""), flush=True)
        return True
    except (AssertionError, TimeoutError, EOFError, OSError) as e:
        failures.append(name)
        print(f"FAIL {name}: {type(e).__name__}: {e}", flush=True)
        return False


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    host_bin = os.path.abspath(sys.argv[1])
    if calculator_pids():
        sys.exit("Calculator is already running (not started by this script); close it and run again. Nothing done.")
    work = tempfile.mkdtemp(prefix="focus-loopback-")
    errlog = open(os.path.join(work, "host.log"), "w")
    host = None
    sock = None
    calc_pid = None
    try:
        host = Host(host_bin, errlog)
        sock = connect(host.port)
        sock.sendall(hello())
        read_until(sock, READY, 30)
        pids = calculator_pids()
        calc_pid = pids[0] if len(pids) == 1 else None

        def on():
            sock.sendall(set_stream(2))
            p = read_until(sock, FOCUS_REGION, 10)
            window, count = struct.unpack("<IB", p[:5])
            assert count <= 3 and len(p) == 5 + 16 * count, f"malformed focusRegion (count {count}, {len(p)} bytes)"
            return f"focusRegion for window {window} with {count} rect(s)"

        step("1 focus bit on -> focusRegion within 10 s", on)

        def off():
            sock.sendall(set_stream(0))
            # A focusRegion already in flight when the host handles the bit is legitimate: ignore type 36
            # for the first 0.3 s, then none may arrive for 3 s, and the host must not close.
            drain(sock, 0.3)
            seen = watch_types(sock, 3)
            assert FOCUS_REGION not in seen, "focusRegion arrived after the focus bit went off"
            return f"none in 3 s (types seen: {sorted(seen)})"

        step("2 focus bit off -> no focusRegion", off)
    except BaseException as e:
        failures.append("unexpected")
        print(f"FAIL unexpected: {type(e).__name__}: {e}", flush=True)
    finally:
        if sock:
            try:
                sock.close()
            except OSError:
                pass
        if host:
            try:
                host.proc.stdin.close()
            except OSError:
                pass
            try:
                host.proc.wait(5)
            except subprocess.TimeoutExpired:
                host.proc.terminate()
                try:
                    host.proc.wait(5)
                except subprocess.TimeoutExpired:
                    host.proc.kill()
        if calc_pid:
            try:
                os.kill(calc_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        elif failures:
            print("note: rapp-host may have launched Calculator; you can quit it yourself if it is still open")
        if failures:
            errlog.flush()
            try:
                print("--- host log tail ---")
                print("".join(open(os.path.join(work, "host.log")).readlines()[-20:]))
            except OSError:
                pass
        shutil.rmtree(work, ignore_errors=True)
    if failures:
        print("FAIL: " + ", ".join(failures))
        sys.exit(1)
    print("PASS")


def drain(sock, seconds):
    end = time.time() + seconds
    while time.time() < end:
        try:
            read_msg(sock, max(0.1, end - time.time()))
        except TimeoutError:
            break
        # EOFError/OSError propagate: the host must not close here


def watch_types(sock, seconds):
    seen, end = set(), time.time() + seconds
    while time.time() < end:
        try:
            t, _ = read_msg(sock, max(0.2, end - time.time()))
            seen.add(t)
        except TimeoutError:
            break
    return seen


if __name__ == "__main__":
    main()
