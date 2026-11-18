#!/usr/bin/env python3
"""Read-only native desktop capture: CPU, compositor CPU and ping latency.

Starts an isolated host (no saved devices, input, clipboard or lock requests).
Run the same duration/fps/density before and after a change on an idle desktop.
"""
import argparse
import json
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary', type=Path)
parser.add_argument('--seconds', type=float, default=10)
parser.add_argument('--fps', type=int, choices=[1, 5, 15, 30], default=15)
parser.add_argument('--density', type=float, default=2)
protocol = int(re.search(r'pub const VERSION: u8 = (\d+);',
               (Path(__file__).resolve().parents[1] / 'rust/client-core/src/protocol.rs').read_text())[1])
parser.add_argument('--protocol', type=int, default=protocol,
                    help='override when benchmarking a host built from older source')
args = parser.parse_args()


def usage(pid):
    stat = Path(f'/proc/{pid}/stat').read_text().split(') ', 1)[1].split()
    return (int(stat[11]) + int(stat[12])) / os.sysconf('SC_CLK_TCK')


def packet(kind, data):
    return struct.pack('<BI', kind, len(data)) + data


def string(value):
    value = value.encode()
    return struct.pack('<H', len(value)) + value


compositors = subprocess.run(['pgrep', '-u', str(os.getuid()), '-x', 'Hyprland'],
                            capture_output=True, text=True).stdout.split()
host = subprocess.Popen([str(args.binary.resolve()), 'serve', '--app', 'desktop:',
                         '--bind', '127.0.0.1', '--port', '0', '--token-env',
                         'RAPP_BENCH_TOKEN', '--json'], stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, env={**os.environ, 'RAPP_BENCH_TOKEN': 'benchmark-only'})
peer = None
stop = threading.Event()
errors, latency, frames = [], [], []
sent = {}
lock = threading.Lock()
try:
    hello = json.loads(host.stdout.readline())
    assert hello['event'] == 'listening', hello
    peer = socket.create_connection(('127.0.0.1', hello['port']), timeout=10)
    peer.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    peer.sendall(packet(1, bytes([args.protocol]) + string('benchmark-only') + string('') +
                        struct.pack('<BBf', 2, args.fps, args.density)))

    def read():
        def exact(n):
            data = bytearray()
            while len(data) < n:
                part = peer.recv(n - len(data))
                if not part:
                    raise EOFError('host disconnected')
                data.extend(part)
            return data
        try:
            while not stop.is_set():
                kind, size = struct.unpack('<BI', exact(5))
                assert size <= 64 * 1024 * 1024
                data = exact(size)
                if kind == 3:
                    raise RuntimeError(data[2:].decode())
                if kind == 4:
                    frames.append(size)
                    with lock:
                        peer.sendall(packet(27, struct.pack('<H', 0)))
                if kind == 32:
                    seq = struct.unpack('<I', data)[0]
                    with lock:
                        latency.append((time.monotonic() - sent.pop(seq)) * 1000)
        except Exception as error:
            if not stop.is_set():
                errors.append(str(error))

    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    before = {int(p): usage(int(p)) for p in [str(host.pid), *compositors]}
    began = time.monotonic()
    seq = 0
    while time.monotonic() - began < args.seconds and not errors:
        with lock:
            sent[seq] = time.monotonic()
            peer.sendall(packet(31, struct.pack('<I', seq)))
        seq += 1
        time.sleep(.02)
    elapsed = time.monotonic() - began
    cpu = {p: round((usage(p) - ticks) / elapsed * 100, 1) for p, ticks in before.items()}
    assert not errors, errors
    assert latency and frames, 'no frame or pong'
    latency.sort()
    print(json.dumps({'seconds': round(elapsed, 2), 'fps': args.fps, 'density': args.density,
                      'host_cpu_percent': cpu.pop(host.pid), 'compositor_cpu_percent': cpu,
                      'frames': len(frames), 'pongs': len(latency), 'pending_pings': len(sent),
                      'ping_p50_ms': round(latency[len(latency)//2], 2),
                      'ping_p95_ms': round(latency[min(len(latency)-1, int(len(latency)*.95))], 2),
                      'ping_max_ms': round(latency[-1], 2)}, indent=2))
finally:
    stop.set()
    if peer:
        try:
            peer.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        peer.close()
    try:
        host.stdin.close()
    except BrokenPipeError:
        pass
    try:
        host.wait(timeout=10)
    except subprocess.TimeoutExpired:
        host.kill()
        host.wait()
