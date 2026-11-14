#!/usr/bin/env python3
"""Host-side check of the v9 side connections (fetch/put) without touching the clipboard.

usage: scripts/side-loopback.py <path to rapp-host>

Starts `rapp-host serve` on 127.0.0.1 (port 0) for Calculator, opens a session,
and runs the side-connection checks of spec section 7. Calculator is launched by
rapp-host itself when it is not running; if one is already running this script
does nothing (that one is the user's). At the end only the processes this script
started are stopped, by PID. Nothing is sent as mouse or keyboard input and every
put uses kind data (memory), so no files are written.
"""
import json, os, select, shutil, signal, socket, struct, subprocess, sys, tempfile, threading, time

TOKEN = "runtest123"
APP = "com.apple.calculator"
KB = 1024


def msg(mtype, payload=b""):
    return bytes([mtype]) + struct.pack("<I", len(payload)) + payload


def s16(text):
    b = text.encode()
    return struct.pack("<H", len(b)) + b


VERSION = 9


def hello(version=VERSION):
    return msg(1, bytes([version]) + s16(TOKEN) + s16(APP) + bytes([0, 15]) + struct.pack("<f", 1.0))


def fetch(token, clip, file=0, offset=0):
    return msg(22, bytes([VERSION]) + s16(token) + struct.pack("<IHQ", clip, file, offset))


def put(item, total, token=TOKEN, kind=3, uti="public.data", name=""):
    return msg(23, bytes([VERSION]) + s16(token) + struct.pack("<I", item) + bytes([kind]) + s16(uti) + s16(name)
               + struct.pack("<Q", total))


def chunk(data):
    return msg(25, data)


def recv_exact(sock, n, timeout=10):
    buf = b""
    end = time.time() + timeout
    while len(buf) < n:
        left = end - time.time()
        if left <= 0 or not select.select([sock], [], [], left)[0]:
            raise TimeoutError("timed out reading from host")
        part = sock.recv(n - len(buf))
        if not part:
            raise EOFError("host closed the connection")
        buf += part
    return buf


def read_msg(sock, timeout=10):
    head = recv_exact(sock, 5, timeout)
    length = struct.unpack("<I", head[1:])[0]
    return head[0], recv_exact(sock, length, timeout)


def expect_error(sock, text):
    t, p = read_msg(sock)
    assert t == 3, f"wanted error, got type {t}"
    got = p[2:2 + struct.unpack("<H", p[:2])[0]].decode()
    assert text in got, f"wanted error {text!r}, got {got!r}"


def expect_start(sock, total):
    t, p = read_msg(sock)
    assert t == 24, f"wanted transferStart, got type {t} {p[:40]!r}"
    got = struct.unpack("<Q", p)[0]
    assert got == total, f"wanted transferStart({total}), got {got}"


def expect_empty_chunk(sock):
    t, p = read_msg(sock)
    assert t == 25 and p == b"", f"wanted an empty chunk, got type {t} with {len(p)} bytes"


def expect_eof(sock):
    try:
        while True:
            if not sock.recv(65536):
                return
    except (ConnectionResetError, TimeoutError):
        return


def connect(port):
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s


def send_chunks(sock, data):
    for i in range(0, len(data), 256 * KB):
        sock.sendall(chunk(data[i:i + 256 * KB]))


def half_close(sock):
    """Close our side and wait for the host to finish; a plain close could reset away queued data."""
    sock.shutdown(socket.SHUT_WR)
    sock.settimeout(5)
    expect_eof(sock)
    sock.close()


def ok(name):
    print(f"ok {name}", flush=True)


def calculator_pids():
    r = subprocess.run(["pgrep", "-x", "Calculator"], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()]


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    host_bin = os.path.abspath(sys.argv[1])
    if calculator_pids():
        sys.exit("Calculator is already running (not started by this script); close it and run again. Nothing done.")

    work = tempfile.mkdtemp(prefix="side-loopback-")
    errlog = open(os.path.join(work, "host.log"), "w")
    host = main_sock = None
    calc_pid = None
    try:
        host = subprocess.Popen([host_bin, "serve", "--app", APP, "--bind", "127.0.0.1", "--port", "0",
                                 "--token-env", "T", "--json"], env=dict(os.environ, T=TOKEN),
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errlog, text=True)
        port = None
        end = time.time() + 20
        while port is None and time.time() < end:
            line = host.stdout.readline()
            if not line:
                sys.exit("rapp-host exited before listening")
            ev = json.loads(line)
            if ev.get("event") == "listening":
                port = ev["port"]
        assert port, "no listening event"
        threading.Thread(target=lambda: [None for _ in host.stdout], daemon=True).start()

        main_sock = connect(port)
        main_sock.sendall(hello())
        ready_deadline = time.time() + 30
        while True:
            if time.time() > ready_deadline:
                raise TimeoutError("no ready within 30 s")
            t, _ = read_msg(main_sock, timeout=max(1, ready_deadline - time.time()))
            if t == 2:
                break
            if t == 3:
                sys.exit("host sent an error instead of ready (Screen Recording permission?)")
        ok("ready")
        pids = calculator_pids()
        calc_pid = pids[0] if len(pids) == 1 else None
        # The main connection also gets frames, windows and clips; read and drop them.
        main_sock.settimeout(None)
        drain = threading.Thread(target=lambda: _drain(main_sock), daemon=True)
        drain.start()

        # 1. unknown clip
        s = connect(port)
        s.sendall(fetch(TOKEN, 99))
        expect_error(s, "unknown clip")
        s.close()
        ok("fetch unknown clip")

        # 2. resume an upload
        data = bytes(i % 251 for i in range(600 * KB))
        s = connect(port)
        s.sendall(put(1, 600 * KB))
        expect_start(s, 0)
        send_chunks(s, data[:300 * KB])
        half_close(s)
        s = connect(port)
        s.sendall(put(1, 600 * KB))
        expect_start(s, 300 * KB)
        send_chunks(s, data[300 * KB:])
        expect_empty_chunk(s)
        s.close()
        ok("put resumes")

        # 3. a finished upload
        s = connect(port)
        s.sendall(put(1, 600 * KB))
        expect_start(s, 600 * KB)
        expect_empty_chunk(s)
        s.close()
        ok("put already complete")

        # 4. at most four side connections
        held = []
        for item in range(2, 6):
            held.append(open_put(port, item))
        s = connect(port)
        s.sendall(put(6, 1024 * KB))
        expect_error(s, "busy")
        s.close()
        ok("fifth side connection busy")
        held.pop().close()
        deadline = time.time() + 5
        while True:
            s = connect(port)
            s.sendall(put(6, 1024 * KB))
            t, p = read_msg(s)
            if t == 24:
                assert struct.unpack("<Q", p)[0] == 0
                held.append(s)
                break
            s.close()
            assert time.time() < deadline, "slot was never released"
            time.sleep(0.2)
        ok("slot freed after close")
        for h in held:
            h.close()

        # 5. wrong token, then no session
        s = connect(port)
        s.sendall(fetch("wrong", 1))
        expect_error(s, "bad token")
        s.close()
        ok("bad token")
        main_sock.shutdown(socket.SHUT_RDWR)
        main_sock.close()
        main_sock = None
        deadline = time.time() + 10
        while True:
            s = connect(port)
            s.sendall(fetch(TOKEN, 1))
            t, p = read_msg(s)
            s.close()
            text = p[2:2 + struct.unpack("<H", p[:2])[0]].decode() if t == 3 else ""
            if text == "no session":
                break
            assert time.time() < deadline, f"wanted no session, got type {t} {text!r}"
            time.sleep(0.2)
        ok("no session")

        # 5b. ending a session closes its side connections and frees their slots
        main_sock = connect(port)
        main_sock.sendall(hello())
        end = time.time() + 30
        while read_msg(main_sock, timeout=max(1, end - time.time()))[0] != 2:
            pass
        threading.Thread(target=_drain, args=(main_sock,), daemon=True).start()
        idle = [open_put(port, item) for item in range(10, 14)]
        main_sock.shutdown(socket.SHUT_RDWR)
        main_sock.close()
        main_sock = None
        for h in idle:
            h.settimeout(5)
            expect_eof(h)
            h.close()
        main_sock = connect(port)
        main_sock.sendall(hello())
        end = time.time() + 30
        while read_msg(main_sock, timeout=max(1, end - time.time()))[0] != 2:
            pass
        threading.Thread(target=_drain, args=(main_sock,), daemon=True).start()
        s = connect(port)
        s.sendall(put(20, 1024 * KB))
        expect_start(s, 0)
        s.close()
        ok("session end frees side slots")

        # 6. old protocol
        s = connect(port)
        s.sendall(hello(8))
        expect_error(s, "protocol version mismatch")
        s.close()
        ok("v8 hello rejected")
        print("PASS")
    except BaseException as e:
        print(f"FAIL: {type(e).__name__}: {e}")
        if calc_pid is None:
            print("note: rapp-host may have launched Calculator; you can quit it yourself if it is still open")
        errlog.flush()
        try:
            print("--- host log tail ---")
            print("".join(open(os.path.join(work, "host.log")).readlines()[-20:]))
        except OSError:
            pass
        raise SystemExit(1)
    finally:
        if main_sock:
            main_sock.close()
        if host:
            try:
                host.stdin.close()
            except OSError:
                pass
            try:
                host.wait(5)
            except subprocess.TimeoutExpired:
                host.terminate()
                try:
                    host.wait(5)
                except subprocess.TimeoutExpired:
                    host.kill()
        # Only the Calculator this run started, by PID.
        if calc_pid:
            try:
                os.kill(calc_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        shutil.rmtree(work, ignore_errors=True)


def open_put(port, item):
    for _ in range(25):
        s = connect(port)
        s.sendall(put(item, 1024 * KB))
        t, p = read_msg(s)
        if t == 24:
            assert struct.unpack("<Q", p)[0] == 0
            return s
        s.close()
        time.sleep(0.2)
    raise AssertionError("could not open a put connection")


def _drain(sock):
    try:
        while sock.recv(65536):
            pass
    except OSError:
        pass


if __name__ == "__main__":
    main()
