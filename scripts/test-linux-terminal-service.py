#!/usr/bin/env python3
"""Real systemd cgroup regression, with a headless fake terminal owning a real pty.

Requires the user's systemd manager and a built rapp-term. Creates only uniquely
named transient test services; never changes the installed rapp service or opens
a window. Proves a launched holder survives the service cgroup stopping.
"""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

binary = Path(sys.argv[1] if len(sys.argv) > 1 else 'rust/target/debug/rapp-term').resolve()
assert binary.is_file(), binary
unit = 'rapp-terminal-test-' + uuid.uuid4().hex

def run(*args):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

def until(f, seconds=15):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        v = f()
        if v:
            return v
        time.sleep(.1)
    raise AssertionError('timed out waiting for test process')

terminal_unit = None
with tempfile.TemporaryDirectory(prefix='rlt-', dir='/tmp') as td:
    root = Path(td)
    config = root / 'term.json'
    config.write_text('{"allow":true}')
    fakebin = root / 'bin'
    fakebin.mkdir()
    pidfile = root / 'terminal.pid'
    fake = fakebin / 'foot'
    fake.write_text('''#!/usr/bin/python3
import os, sys
from pathlib import Path
args = sys.argv[1:]
assert args.pop(0) == '--'
pid, fd = os.forkpty()
if pid == 0:
    os.execv(args[0], args)
Path(%r).write_text(str(os.getpid()))
try:
    while os.read(fd, 4096): pass
except OSError: pass
finally:
    os.close(fd)
os.waitpid(pid, 0)
''' % str(pidfile))
    fake.chmod(0o755)
    log = root / 'worker.log'
    wrapper = root / 'worker.py'
    cmd = [str(binary), 'serve', '--config', str(config), '--bind', '127.0.0.1', '--port', '0', '--token-env', 'RAPP_TEST_TOKEN', '--json']
    wrapper.write_text('''import os, subprocess
os.environ['PATH'] = %r + ':' + os.environ.get('PATH', '/usr/bin')
os.environ['RAPP_TEST_TOKEN'] = 'test-only'
os.environ['DISPLAY'] = ':rapp-no-real-display'
with open(%r, 'w') as log:
    child = subprocess.Popen(%r, stdin=subprocess.PIPE, stdout=log, stderr=log)
    child.wait()
''' % (str(fakebin), str(log), cmd))
    try:
        run('systemd-run', '--user', '--quiet', '--collect', '--service-type=exec', '--unit', unit, '/usr/bin/python3', str(wrapper))
        def listening():
            if not log.exists(): return None
            for line in log.read_text().splitlines():
                try: event = json.loads(line)
                except ValueError: continue
                if event.get('event') == 'listening': return event['port']
        port = until(listening)
        with socket.create_connection(('127.0.0.1', port), timeout=15) as s:
            s.sendall(b'{"op":"open","app":"foot"}\ntest-only\n')
            reply = json.loads(s.makefile('r').readline())
            assert reply.get('id', '').startswith('term:pty:'), reply
        pid = int(until(lambda: pidfile.read_text() if pidfile.exists() else None))
        # A terminal created as a transient service must not belong to the worker's cgroup.
        group = Path(f'/proc/{pid}/cgroup').read_text()
        assert unit not in group, group
        terminal_unit = next(part for part in group.strip().split('/') if part.startswith('run-') and part.endswith('.service'))
        termdir = root / 'term'
        token = (termdir / 'pty.token').read_text().strip()
        sockets = list((termdir / 'pty').glob('*.sock'))
        assert len(sockets) == 1, sockets
        def status():
            with socket.socket(socket.AF_UNIX) as s:
                s.settimeout(3)
                s.connect(str(sockets[0]))
                s.sendall((json.dumps({'op':'status','v':2})+'\n'+token+'\n').encode())
                return json.loads(s.makefile('r').readline())
        before = status()
        run('systemctl', '--user', 'stop', unit)
        after = status()
        assert after['pid'] == before['pid'], (before, after)
        os.kill(after['pid'], 0)
        print('PASS terminal holder survives stopping the worker service cgroup')
    finally:
        subprocess.run(['systemctl','--user','stop',unit], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if terminal_unit:
            subprocess.run(['systemctl','--user','stop',terminal_unit], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        elif pidfile.exists():
            try: os.kill(int(pidfile.read_text()), signal.SIGTERM)
            except ProcessLookupError: pass
