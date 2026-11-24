#!/usr/bin/env python3
"""Exercise the actual local recognizer without ever opening a microphone.

Provide the checksum-verified ggml-base.bin and 16 kHz mono signed s16le PCM of
whisper.cpp's public samples/jfk.wav. No downloads or user recordings occur here.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--worker', type=Path, required=True)
parser.add_argument('--model', type=Path, required=True)
parser.add_argument('--pcm', type=Path, required=True)
args = parser.parse_args()
assert hashlib.sha256(args.model.read_bytes()).hexdigest() == '60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe'


def start(extra=None, env=None):
    p = subprocess.Popen([args.worker.resolve()], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, env=env)
    p.stdin.write((json.dumps({'model': str(args.model.resolve()), 'language': 'en', **(extra or {})}) + '\n').encode())
    p.stdin.flush()
    return p


def event(p, wanted):
    deadline = time.monotonic() + 300
    # Unbuffered reads prevent select missing a line already in Python's user-space buffer.
    line = bytearray()
    while time.monotonic() < deadline:
        assert select.select([p.stdout], [], [], max(0, deadline - time.monotonic()))[0], 'worker timeout'
        byte = os.read(p.stdout.fileno(), 1)
        assert byte, f'worker ended before {wanted}'
        if byte != b'\n':
            line.extend(byte)
            continue
        data = json.loads(line)
        line.clear()
        assert data['event'] != 'error', data
        if data['event'] == wanted:
            return data
    raise AssertionError('worker timeout')


def stopped(pid):
    for _ in range(100):
        try:
            state = Path(f'/proc/{pid}/stat').read_text().split(') ', 1)[1].split()[0]
        except FileNotFoundError:
            return
        if state == 'Z':  # dead, waiting for the system's child reaper
            return
        time.sleep(.02)
    raise AssertionError('microphone recorder survived its owner')


with tempfile.TemporaryDirectory(prefix='rapp-voice-fixture-') as directory:
    tmp = Path(directory)
    sample = args.pcm.read_bytes()
    (tmp / 'silent.pcm').write_bytes(bytes(16000 * 2))
    # Put the public speech near the five-minute boundary: a stale 60 s buffer
    # would return silence. Feed speech after the cap too, which must be ignored.
    assert len(sample) < 16000 * 2 * 60
    (tmp / 'long.pcm').write_bytes(bytes(16000 * 2 * 299 - len(sample)) + sample)
    (tmp / 'over-cap.pcm').write_bytes(bytes(16000 * 2 * 300) + sample)
    for name, pcm, word in [
        ('speech', args.pcm.resolve(), 'country'),
        ('silence', tmp / 'silent.pcm', ''),
        ('speech near five minutes', tmp / 'long.pcm', 'country'),
        ('speech beyond five minutes is excluded', tmp / 'over-cap.pcm', ''),
    ]:
        p = start({'pcm_path': str(pcm)})
        try:
            event(p, 'ready')
            text = event(p, 'final')['text']
            assert word in text.lower() if word else text == '', text
            assert p.wait(timeout=3) == 0
            print(f'PASS actual Whisper model: {name}')
        finally:
            if p.poll() is None:
                p.kill()
            p.wait()
            p.stdin.close()
            p.stdout.close()

    # A fake parec produces silence and exposes its PID; real PulseAudio is never used.
    capture = tmp / 'parec'
    capture.write_text('''#!/usr/bin/env python3
import os,time,sys
open(os.environ['RAPP_CAPTURE_PID'], 'w').write(str(os.getpid()))
while True:
    sys.stdout.buffer.write(bytes(640))
    sys.stdout.buffer.flush()
    time.sleep(.02)
''')
    capture.chmod(0o755)
    pid_file = tmp / 'capture.pid'
    env = {**os.environ, 'PATH': str(tmp) + os.pathsep + os.environ['PATH'], 'RAPP_CAPTURE_PID': str(pid_file)}
    for action in ['stop', 'cancel', 'crash']:
        p = start(env=env)
        try:
            event(p, 'ready')
            pid = int(pid_file.read_text())
            if action == 'crash':
                p.send_signal(signal.SIGKILL)
            else:
                p.stdin.write((json.dumps({'cmd': action}) + '\n').encode())
                p.stdin.flush()
                if action == 'stop':
                    assert event(p, 'final')['text'] == ''
            p.wait(timeout=3)
            stopped(pid)
            print(f'PASS {action} closes capture process')
        finally:
            if p.poll() is None:
                p.kill()
            p.wait()
            p.stdin.close()
            p.stdout.close()
