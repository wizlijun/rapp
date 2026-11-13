#!/usr/bin/env python3
"""Regress worker latency with a paused/slow stdout consumer and dependent deltas.

Build rapp-session --release first. Pass --baseline PATH to compare an older
worker without applying the latest-frame assertion to that binary. This measures
worker pipe catch-up, not remote input-to-screen latency.
"""
import argparse
import json
from pathlib import Path
import select
import socket
import struct
import subprocess
import time
import zlib

WIDTH, HEIGHT, FRAMES = 1920, 1080, 60


def packet(kind, body):
    return struct.pack('<BI', kind, len(body)) + body


def probe(binary, latest):
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        listener.settimeout(5)
        with subprocess.Popen([str(binary)], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, bufsize=0) as worker:
            peer = None
            try:
                worker.stdin.write((json.dumps(dict(port=listener.getsockname()[1],
                    token='latency-fixture', mode='color16', fps=30, density=1)) + '\n').encode())
                peer, _ = listener.accept()
                peer.settimeout(5)

                def read_packet():
                    def exact(n):
                        data = bytearray(n)
                        view = memoryview(data)
                        deadline = time.monotonic() + 15
                        while view:
                            remaining = deadline - time.monotonic()
                            if remaining <= 0 or not select.select([worker.stdout], [], [], remaining)[0]:
                                raise TimeoutError('worker output stalled')
                            count = worker.stdout.readinto(view[:65536])
                            if not count:
                                raise EOFError('worker exited')
                            view = view[count:]
                            # Simulate a consumer slower than the host's burst.
                            time.sleep(count / (64 * 1024 * 1024))
                        return data
                    n = struct.unpack('<I', exact(4))[0]
                    assert 1 <= n <= WIDTH * HEIGHT * 4 + 25
                    return exact(n)

                peer.sendall(packet(2, struct.pack('<H', 1) + b'T' + struct.pack('<HH', WIDTH, HEIGHT)))
                assert json.loads(read_packet()[1:])['event'] == 'ready'
                z = zlib.compressobj()
                tiles = ((WIDTH + 63) // 64) * ((HEIGHT + 63) // 64)
                for i in range(FRAMES):
                    if i == 0:
                        body = struct.pack('<H', tiles) + b''.join(
                            struct.pack('<HBH', j, 0, 0xf800) for j in range(tiles))
                    else:
                        # The last frame still needs tile 0 from the FIRST delta.
                        body = struct.pack('<HHBH', 1, 0 if i == 1 else 1,
                                           0, 0x001f if i == 1 else 0x07e0)
                    data = z.compress(body) + z.flush(zlib.Z_SYNC_FLUSH)
                    peer.sendall(packet(4, struct.pack('<BffffHHB', 2, 0., 0.,
                        WIDTH, HEIGHT, WIDTH, HEIGHT, i == 0) + data))
                peer.sendall(packet(17, b'\0\0'))  # ordered marker after every delta
                time.sleep(2)  # stdout is deliberately unread while the burst arrives
                start = time.monotonic()
                frames, last = 0, None
                while True:
                    body = read_packet()
                    if body[0] == 1:
                        frames += 1
                        last = body
                    elif json.loads(body[1:])['event'] == 'menu':
                        break
                elapsed = time.monotonic() - start
                assert last is not None
                assert last[25:29] == bytes([255, 0, 0, 255]), 'lost an earlier delta'
                assert last[25 + 64 * 4:29 + 64 * 4] == bytes([0, 255, 0, 255]), 'stale final canvas'
                if latest:
                    assert frames <= 3, f'pipe drained {frames} stale canvases'
                print(json.dumps(dict(binary=str(binary), decoded_frames=FRAMES,
                    delivered_frames=frames, catchup_seconds=round(elapsed, 3))), flush=True)
            finally:
                if peer is not None:
                    peer.close()
                worker.kill()
                worker.wait(timeout=5)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', nargs='?', default='rust/target/release/rapp-session', type=Path)
    parser.add_argument('--baseline', type=Path)
    args = parser.parse_args()
    if args.baseline:
        probe(args.baseline.resolve(), latest=False)
    probe(args.binary.resolve(), latest=True)
