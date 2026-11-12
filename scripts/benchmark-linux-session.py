#!/usr/bin/env python3
"""Compare headless frame transport/expansion, not end-to-end interactive FPS."""
import json
import os
import socket
import struct
import subprocess
import sys
import threading
import time
import zlib

WIDTH = int(os.environ.get("RAPP_BENCH_WIDTH", "1920"))
HEIGHT = int(os.environ.get("RAPP_BENCH_HEIGHT", "1080"))
FRAMES = int(os.environ.get("RAPP_BENCH_FRAMES", "120"))

def packet(kind, body):
    return struct.pack('<BI', kind, len(body)) + body

def exact(stream, n):
    data = bytearray(n)
    view = memoryview(data)
    while view:
        count = stream.readinto(view)
        if not count:
            raise EOFError()
        view = view[count:]
    return data

for binary in sys.argv[1:]:
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen()
    p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    p.stdin.write((json.dumps(dict(port=listener.getsockname()[1], token='benchmark', mode='color16', fps=30, density=1))+'\n').encode())
    p.stdin.flush()
    peer, _ = listener.accept()
    wire = peer.makefile('rb')
    header = exact(wire, 5)
    exact(wire, struct.unpack_from('<I', header, 1)[0])
    peer.sendall(packet(2, struct.pack('<H', 5)+b'Bench'+struct.pack('<HH', WIDTH, HEIGHT)))
    def feed():
        z = zlib.compressobj()
        tiles = ((WIDTH+63)//64)*((HEIGHT+63)//64)
        body = struct.pack('<H', tiles)+b''.join(struct.pack('<HBH', i, 0, 0xf800) for i in range(tiles))
        for i in range(FRAMES):
            payload = z.compress(body if i == 0 else b'\0\0')+z.flush(zlib.Z_SYNC_FLUSH)
            peer.sendall(packet(4, struct.pack('<BffffHHB', 2, 0., 0., float(WIDTH), float(HEIGHT), WIDTH, HEIGHT, i == 0)+payload))
    start = time.monotonic()
    t = threading.Thread(target=feed)
    t.start()
    seen = 0
    while seen < FRAMES:
        n = struct.unpack('<I', exact(p.stdout, 4))[0]
        payload = exact(p.stdout, n)
        if payload[0] == 1:
            assert len(payload) == 25+WIDTH*HEIGHT*4
            seen += 1
    elapsed = time.monotonic()-start
    print(json.dumps(dict(binary=binary, frames=seen, seconds=round(elapsed,3), throughput_fps=round(seen/elapsed,1))), flush=True)
    t.join()
    p.stdin.close()
    p.stdout.read()
    p.wait(timeout=5)
    wire.close()
    peer.close()
    listener.close()
