#!/usr/bin/env python3
"""Compare worker ACK latency for the same 4K update in one or many slices.

No remote connection or GUI is used. A local host fixture sends 16 changed
tiles, waiting for each slice's ACK, while a separate thread drains stdout.
This isolates repeated canvas expansion from network bandwidth. It does not
measure input-to-screen latency. Output pixels and metadata order are checked.
Pass old and new release workers to compare them under the same machine load.
"""
import argparse
import json
from pathlib import Path
import socket
import struct
import subprocess
import threading
import time
import zlib

WIDTH, HEIGHT = 3840, 2160


def packet(kind, body):
    return struct.pack('<BI', kind, len(body)) + body


def exact(stream, n):
    data = bytearray(n)
    view = memoryview(data)
    while view:
        count = stream.readinto(view)
        if not count:
            raise EOFError('worker closed')
        view = view[count:]
    return data


def trial(binary, slices):
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        listener.settimeout(10)
        with subprocess.Popen([str(binary)], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as worker:
            peer, reader = None, None
            try:
                start = dict(port=listener.getsockname()[1], token='slice-fixture',
                             mode='color16', fps=30, density=1)
                worker.stdin.write((json.dumps(start) + '\n').encode())
                worker.stdin.flush()
                peer, _ = listener.accept()
                peer.settimeout(15)
                wire = peer.makefile('rb')
                header = exact(wire, 5)
                exact(wire, struct.unpack_from('<I', header, 1)[0])
                counts, errors, done = [0], [], threading.Event()

                def drain():
                    last = None
                    try:
                        while True:
                            n = struct.unpack('<I', exact(worker.stdout, 4))[0]
                            assert 1 <= n <= WIDTH * HEIGHT * 4 + 25
                            body = exact(worker.stdout, n)
                            if body[0] == 1:
                                assert len(body) == WIDTH * HEIGHT * 4 + 25
                                counts[0] += 1
                                last = body
                            elif json.loads(body[1:]).get('event') == 'menu':
                                assert last is not None
                                # All 16 deltas survived coalescing; the following tile is unchanged.
                                for tile in range(17):
                                    at = 25 + tile * 64 * 4
                                    expected = bytes([0, 255, 0, 255] if tile < 16 else [0, 0, 255, 255])
                                    assert last[at:at + 4] == expected, f'stale tile {tile}'
                                done.set()
                    except EOFError:
                        if not done.is_set():
                            errors.append('EOF before final canvas')
                            done.set()
                    except Exception as error:
                        errors.append(str(error))
                        done.set()

                reader = threading.Thread(target=drain, daemon=True)
                reader.start()
                peer.sendall(packet(2, struct.pack('<H', 1) + b'T' + struct.pack('<HH', WIDTH, HEIGHT)))
                compressor = zlib.compressobj()

                def frame(body, flags):
                    data = compressor.compress(body) + compressor.flush(zlib.Z_SYNC_FLUSH)
                    header = struct.pack('<BffffHHB', 2, 0., 0., WIDTH, HEIGHT, WIDTH, HEIGHT, flags)
                    if flags & 2 and not flags & 1:
                        header += struct.pack('<ii', 0, 0)
                    peer.sendall(packet(4, header + data))

                def ack():
                    while True:
                        kind, n = struct.unpack('<BI', exact(wire, 5))
                        assert n <= 65536
                        body = exact(wire, n)
                        if kind == 27:
                            return struct.unpack('<H', body)[0]
                        if kind == 31:
                            peer.sendall(packet(32, body))

                tiles = ((WIDTH + 63) // 64) * ((HEIGHT + 63) // 64)
                frame(struct.pack('<H', tiles) + b''.join(
                    struct.pack('<HBH', i, 0, 0xf800) for i in range(tiles)), 7)
                ack()
                started, processing = time.monotonic(), []
                groups = [list(range(16))] if slices == 1 else [[i] for i in range(16)]
                for i, group in enumerate(groups):
                    flags = (2 if i == 0 else 0) | (4 if i == len(groups) - 1 else 0)
                    frame(struct.pack('<H', len(group)) + b''.join(
                        struct.pack('<HBH', tile, 0, 0x07e0) for tile in group), flags)
                    processing.append(ack())
                elapsed = time.monotonic() - started
                peer.sendall(packet(17, b'\0\0'))  # Must follow the last canvas in stdout.
                assert done.wait(15), 'display output stalled'
                assert not errors, errors
                print(json.dumps(dict(binary=str(binary), slices=slices,
                    update_ack_ms=round(elapsed * 1000, 1), processing_ms=sum(processing),
                    output_canvases=counts[0], pixels_verified=True)), flush=True)
                worker.stdin.close()
                worker.wait(timeout=5)
                wire.close()
            finally:
                if peer is not None:
                    peer.close()
                if worker.poll() is None:
                    worker.kill()
                    worker.wait(timeout=5)
                if reader is not None:
                    reader.join(timeout=5)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binaries', nargs='+', type=Path)
    parser.add_argument('--repeat', type=int, default=1)
    args = parser.parse_args()
    for _ in range(args.repeat):
        for binary in args.binaries:
            for slices in [1, 16]:
                trial(binary.resolve(), slices)
