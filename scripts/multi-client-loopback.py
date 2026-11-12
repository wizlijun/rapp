#!/usr/bin/env python3
"""Host-side check of multi-client takeover, input yielding and v5 clients (protocol v6).

usage: scripts/multi-client-loopback.py <path to rapp-host>

Starts `rapp-host serve` on 127.0.0.1 (port 0) for Calculator and plays several
clients against it, naming them to the host the way rapp-service does (stdin
`peer` / `yield`). Calculator is launched by rapp-host itself; if one is already
running this script does nothing (that one is the user's). At the end only the
processes this script started are stopped, by PID. The only input sent is one
mouse move that the host is expected to drop; the token is never printed.
"""
import json, os, select, shutil, signal, socket, struct, subprocess, sys, tempfile, threading, time

TOKEN = "runtest123"
APP = "com.apple.calculator"
HELLO, READY, ERROR, FRAME, MOUSE, INPUT_BLOCKED = 1, 2, 3, 4, 7, 26
MOVE, LEFT = 3, 0


def msg(mtype, payload=b""):
    return bytes([mtype]) + struct.pack("<I", len(payload)) + payload


def s16(text):
    b = text.encode()
    return struct.pack("<H", len(b)) + b


def hello(version=6, token=TOKEN):
    return msg(HELLO, bytes([version]) + s16(token) + s16(APP) + bytes([0, 15]) + struct.pack("<f", 1.0))


def mouse_move():
    # kind, button, window, x, y, clickCount; window 0 and a harmless point, dropped by the host anyway
    return msg(MOUSE, bytes([MOVE, LEFT]) + struct.pack("<Iff", 0, 10.0, 10.0) + bytes([0]))


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


def expect_closed(sock, timeout=5):
    end = time.time() + timeout
    while time.time() < end:
        try:
            if not select.select([sock], [], [], 0.2)[0]:
                continue
            if not sock.recv(65536):
                return
        except (ConnectionResetError, OSError):
            return
    raise AssertionError("connection was not closed")


def watch(sock, seconds):
    """Reads for `seconds`; returns (set of message types seen, whether the host closed it)."""
    seen, end = set(), time.time() + seconds
    while time.time() < end:
        try:
            t, _ = read_msg(sock, max(0.2, end - time.time()))
            seen.add(t)
        except TimeoutError:
            break
        except (EOFError, OSError):
            return seen, True
    return seen, False


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

    work = tempfile.mkdtemp(prefix="multi-client-loopback-")
    errlog = open(os.path.join(work, "host.log"), "w")
    host = None
    socks = {}
    calc_pid = None
    state = {}
    try:
        host = Host(host_bin, errlog)
        port = host.port

        def open_client(n, version=6, name=None, token=TOKEN):
            s = connect(port)
            socks[n] = s
            if name:
                # the host keys device names on the client's port as it sees it = our local port
                host.command({"cmd": "peer", "port": s.getsockname()[1], "name": name})
                time.sleep(0.3)
            s.sendall(hello(version, token))
            return s

        def s1():
            c1 = open_client(1)
            read_until(c1, READY, 30)
            pids = calculator_pids()
            state["calc"] = pids[0] if len(pids) == 1 else None
            return "v6 hello got ready"

        if not step("1 hello v6 -> ready", s1):
            raise SystemExit(1)
        calc_pid = state.get("calc")

        def s2():
            m = host.mark()
            c2 = open_client(2, name="test-b2")
            read_until(c2, READY, 30)
            err = text_of(read_until(socks[1], ERROR, 10))
            assert err == "taken over by test-b2", f"conn 1 error was {err!r}"
            expect_closed(socks[1])
            host.wait_event(lambda e: e.get("event") == "session" and e.get("state") == "ended"
                            and e.get("reason") == "taken over by test-b2", 10, m)
            return "conn 1 told 'taken over by test-b2' and closed, conn 2 ready, session ended event seen"

        step("2 takeover names the new device", s2)

        def s3():
            m = host.mark()
            c3 = open_client(3, token="wrong-token")
            err = text_of(read_until(c3, ERROR, 10))
            assert "bad token" in err, f"conn 3 error was {err!r}"
            host.wait_event(lambda e: e.get("event") == "rejected" and "bad token" in e.get("reason", ""), 10, m)
            seen, closed = watch(socks[2], 3)
            assert not closed, "conn 2 was dropped by a bad-token hello"
            return f"rejected with bad token; conn 2 still open (message types seen: {sorted(seen)})"

        step("3 bad token leaves the session alone", s3)

        def s4():
            c4 = open_client(4)
            read_until(c4, READY, 30)
            err = text_of(read_until(socks[2], ERROR, 10))
            assert err.startswith("taken over"), f"conn 2 error was {err!r}"
            expect_closed(socks[2])
            return "conn 2 taken over by conn 4, conn 4 ready"

        step("4 third client takes over", s4)

        def s5():
            c4 = socks[4]
            m = host.mark()
            host.command({"cmd": "yield", "by": "x"})
            time.sleep(0.2)  # the host takes stdin on its queue; well inside the 1.0 s block
            c4.sendall(mouse_move())  # expected to be dropped
            assert text_of(read_until(c4, INPUT_BLOCKED, 5)) == "x", "inputBlocked carried the wrong name"
            host.wait_event(lambda e: e.get("event") == "input_blocked" and e.get("by") == "x", 5, m)
            return "conn 4 got inputBlocked('x'); input_blocked event seen; the move was dropped"

        step("5 yield blocks input and tells the client", s5)

        def s6():
            c5 = open_client(5, version=5)
            read_until(c5, READY, 30)
            expect_closed(socks[4])
            time.sleep(1.2)  # let the first block expire
            m = host.mark()
            host.command({"cmd": "yield", "by": "x"})
            time.sleep(0.2)
            c5.sendall(mouse_move())  # expected to be dropped
            host.wait_event(lambda e: e.get("event") == "input_blocked" and e.get("by") == "x", 5, m)
            seen, closed = watch(c5, 2)
            assert INPUT_BLOCKED not in seen, "a v5 client was sent message 26"
            assert not closed, "the v5 client was disconnected"
            return "v5 client ready; blocked on the host side, got no 26, stayed connected"

        step("6 v5 client is blocked silently", s6)
    except SystemExit:
        raise
    except BaseException as e:
        failures.append("unexpected")
        print(f"FAIL unexpected: {type(e).__name__}: {e}", flush=True)
    finally:
        for s in socks.values():
            try:
                s.close()
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
        # Only the Calculator this run started, by PID.
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


if __name__ == "__main__":
    main()
