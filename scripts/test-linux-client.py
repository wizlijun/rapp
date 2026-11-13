#!/usr/bin/env python3
"""Exercise the real GTK worker against an independent Python v4/v5 host fixture.
Requires a graphical session (or xvfb-run). No real host credentials are used.
"""
import json
import os
from pathlib import Path
import queue
import socket
import struct
import subprocess
import sys
import threading
import time
import tomllib
import zlib

INPUT = "--input" in sys.argv
paths = [a for a in sys.argv[1:] if a != "--input"]
BINARY = Path(paths[0] if paths else "rust/target/release/rapp-client").resolve()

version = json.loads(subprocess.check_output([str(BINARY), "version", "--json"], text=True))
workspace = tomllib.loads((Path(__file__).resolve().parents[1] / "rust/Cargo.toml").read_text())
assert version == {"version": workspace["workspace"]["package"]["version"], "protocol": 5}, version
print("PASS client version matches workspace")

def string(s):
    b = s.encode()
    return struct.pack("<H", len(b)) + b

def send(s, kind, data):
    s.sendall(struct.pack("<BI", kind, len(data)) + data)

def exact(s, n):
    out = b""
    while len(out) < n:
        chunk = s.recv(n - len(out))
        if not chunk:
            raise EOFError()
        out += chunk
    return out

def recv(s):
    kind, length = struct.unpack("<BI", exact(s, 5))
    return kind, exact(s, length)

class Session:
    def __init__(self, version=5):
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen()
        self.listener.settimeout(15)
        env = dict(os.environ, RAPP_FIXTURE_TOKEN="fixture-secret", GTK_A11Y="none")
        if INPUT:
            env["GDK_BACKEND"] = "x11"
            env["GTK_IM_MODULE"] = "simple"
            env["GDK_SCALE"] = "1"
            env["GDK_DPI_SCALE"] = "1"
        self.p = subprocess.Popen([str(BINARY), f"rapp://127.0.0.1:{self.listener.getsockname()[1]}/?mode=color16&protocol={version}", "--token-env", "RAPP_FIXTURE_TOKEN", "--json"], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.events = queue.Queue()
        self.err = []
        threading.Thread(target=lambda: [self.events.put(json.loads(l)) for l in self.p.stdout], daemon=True).start()
        threading.Thread(target=lambda: self.err.extend(self.p.stderr), daemon=True).start()
        self.s, _ = self.listener.accept()
        self.s.settimeout(8)
        kind, hello = recv(self.s)
        assert kind == 1 and hello[0] == version
        assert hello[1:17] == string("fixture-secret")
        self.hello=hello

    def event(self, name):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            e = self.events.get(timeout=12)
            if e["event"] == name:
                return e
            assert e["event"] != "exit", (e, self.err)
        raise AssertionError(f"missing {name}")

    def ready(self):
        send(self.s, 2, string("rapp protocol fixture") + struct.pack("<HH", 800, 600))
        window = struct.pack("<IIBBfffff", 1, 0, 0, 3, 100., 100., 320., 240., 0.) + string("Fixture")
        send(self.s, 13, struct.pack("<H", 1) + window)
        leaf = string("Test") + bytes([1]) + string("") + bytes([0]) + struct.pack("<H", 0)
        send(self.s, 17, struct.pack("<H", 1) + string("File") + bytes([1]) + string("") + bytes([0]) + struct.pack("<H", 1) + leaf)
        self.event("ready")
        self.event("windows")

    def frame(self, z, full, color, mode=2):
        sample_format="<HBH" if mode in (2,4) else "<HBB"
        body = struct.pack("<H", 20) + b"".join(struct.pack(sample_format, i, 0, color) for i in range(20))
        compressed = z.compress(body) + z.flush(zlib.Z_SYNC_FLUSH)
        send(self.s, 4, struct.pack("<BffffHHB", mode, 100., 100., 320., 240., 320, 240, int(full)) + compressed)

    def finish(self, expected):
        event = self.event("exit")
        assert event["code"] == expected, (event, self.err)
        assert self.p.wait(timeout=8) == expected
        assert not any("panicked" in l or "CRITICAL" in l for l in self.err), self.err
        self.s.close()
        self.listener.close()
        return event

    def cleanup(self):
        if self.p.poll() is None:
            self.p.kill()
            self.p.wait()
        self.s.close()
        self.listener.close()

def case(name, fn, version=5):
    s = Session(version)
    try:
        fn(s)
        print(f"PASS {name}")
    finally:
        s.cleanup()

def normal(s):
    s.ready()
    z = zlib.compressobj()
    s.frame(z, True, 0xf800)
    s.frame(z, False, 0x07e0)
    assert s.hello[-6:-4]==bytes([2,15])
    assert 0<struct.unpack("<f",s.hello[-4:])[0]<=8
    time.sleep(.3)
    assert s.p.poll() is None,s.err
    s.p.stdin.write('{"cmd":"quit"}\n')
    s.p.stdin.flush()
    assert s.finish(0)["reason"] == "quit"

def eof(s):
    s.ready()
    s.p.stdin.close()
    assert s.finish(0)["reason"] == "stdin closed"

def malformed(s):
    s.ready()
    send(s.s, 4, struct.pack("<BffffHHB", 2, 0., 0., 10., 10., 10, 10, 1) + b"invalid")
    assert "zlib" in s.finish(1)["reason"]

def mismatch(s):
    send(s.s, 3, string("protocol version mismatch: host 6, client 5 (update both sides)"))
    assert "version mismatch" in s.finish(5)["reason"]

case("full frame, delta, menus, adaptive stream, quit", normal)
case("legacy v4 full/delta session", normal, version=4)
case("hub closes stdin", eof)
case("corrupt frame exits cleanly", malformed)
case("protocol mismatch exit code", mismatch)


def keyboard(s):
    s.ready()
    s.frame(zlib.compressobj(), True, 0x001f)
    def xdo(*args):
        return subprocess.check_output(["xdotool", *map(str,args)], text=True).strip()
    time.sleep(0.3)
    window=xdo("search", "--pid", s.p.pid, "--name", "rapp protocol fixture").splitlines()[-1]
    xdo("windowactivate", "--sync", window)
    assert xdo("getactivewindow")==window
    xdo("windowminimize", window)
    time.sleep(0.2)
    s.p.stdin.write('{"cmd":"focus"}\n')
    s.p.stdin.flush()
    deadline = time.monotonic() + 5
    while xdo("getactivewindow") != window:
        assert time.monotonic() < deadline, "hub focus did not restore client window"
        time.sleep(0.05)
    xdo("key", "ctrl+a")
    xdo("type", "--clearmodifiers","test-input")
    assert xdo("getactivewindow")==window
    xdo("key", "Return")
    keys=[]; text=None
    while text is None:
        kind,payload=recv(s.s)
        if kind==6:keys.append(struct.unpack("<HQB",payload))
        if kind==5:text=payload.decode()
    assert keys[:2]==[(0,1<<20,1),(0,1<<20,0)],keys
    assert text=="test-input",text
    geom=dict(line.split("=",1) for line in xdo("getwindowgeometry","--shell",window).splitlines())
    x,y=int(geom["WIDTH"])//2,int(geom["HEIGHT"])//2
    assert xdo("getactivewindow")==window
    xdo("mousemove","--window",window,x,y)
    xdo("click","1")
    xdo("click","3")
    xdo("click","4")
    mouse=[];wheel=None
    while len(mouse)<4 or wheel is None:
        try: kind,payload=recv(s.s)
        except TimeoutError: raise AssertionError(("missing mouse events",mouse,wheel,geom,xdo("getmouselocation","--shell"),s.err))
        if kind==7:mouse.append(struct.unpack("<BBIffB",payload))
        if kind==8:wheel=struct.unpack("<Iffff",payload)
    assert [(m[0],m[1],m[2]) for m in mouse[:4]]==[(0,0,1),(1,0,1),(0,1,1),(1,1,1)],mouse
    assert all(0<=m[3]<=320 and 0<=m[4]<=240 for m in mouse),mouse
    assert wheel[0]==1 and wheel[4]>0,wheel
    xdo("mousedown","1")
    xdo("mousemove","--window",window,x+20,y+20)
    time.sleep(0.05)
    xdo("mouseup","1")
    drag=[]
    while not drag or drag[-1][0]!=1:
        kind,payload=recv(s.s)
        if kind==7:drag.append(struct.unpack("<BBIffB",payload))
    assert drag[0][0]==0 and any(m[0]==2 for m in drag),drag
    s.p.stdin.close();s.finish(0)

if INPUT:
    case("GTK keyboard, text, mouse buttons and scrolling",keyboard)


def stream_menu(s):
    s.ready();s.frame(zlib.compressobj(),True,0x001f)
    def xdo(*args):return subprocess.check_output(["xdotool",*map(str,args)],text=True).strip()
    time.sleep(0.4)
    window=xdo("search","--pid",s.p.pid,"--name","rapp protocol fixture").splitlines()[-1]
    xdo("windowactivate","--sync",window)
    geom=dict(line.split("=",1) for line in xdo("getwindowgeometry","--shell",window).splitlines())
    xdo("mousemove","--window",window,int(geom["WIDTH"])-250,40)
    xdo("click","3")
    time.sleep(0.3)
    xdo("key","Home","Return")
    while True:
        kind,payload=recv(s.s)
        if kind==11 and payload[:2]==bytes([3,1]):break
    assert struct.unpack("<f",payload[2:])[0]>0
    z=zlib.compressobj();s.frame(z,True,15,mode=3);s.frame(z,False,5,mode=3)
    time.sleep(.3)
    xdo("mousemove","--window",window,int(geom["WIDTH"])-250,40)
    xdo("click","3")
    time.sleep(0.3)
    xdo("key","Home","Down","Return")
    while True:
        kind,payload=recv(s.s)
        if kind==11 and payload[:2]==bytes([2,15]):break
    assert struct.unpack("<f",payload[2:])[0]==8.,payload
    s.frame(zlib.compressobj(),True,0xf800)
    time.sleep(.2)
    s.p.stdin.close();s.finish(0)

if INPUT:
    case("traffic context menu presets reach the host",stream_menu)
