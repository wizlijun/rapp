#!/usr/bin/env python3
"""Real term/service/hub/CLI round trip in an isolated Linux network namespace.

Build the four workers, then run:
  unshare -Urn python3 scripts/test-linux-components.py [worker-directory]
Only the terminal window and systemd command adapters are fixtures. The separate
test-linux-terminal-service.py exercises real systemd cgroup lifetime handling.
No installed service, saved device, desktop window or relay is used.
"""
import base64
import json
import os
from pathlib import Path
import queue
import signal
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time


def until(check, seconds=15):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = check()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError('timed out waiting for component readiness')


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


class Lines:
    def __init__(self, stream):
        self.items = queue.Queue()
        def read():
            try:
                for line in stream:
                    self.items.put(json.loads(line))
            finally:
                self.items.put(None)
        self.thread = threading.Thread(target=read, daemon=True)
        self.thread.start()

    def matching(self, predicate, seconds=15):
        end = time.monotonic() + seconds
        while True:
            item = self.items.get(timeout=max(.001, end - time.monotonic()))
            assert item is not None, 'component stream ended unexpectedly'
            if predicate(item):
                return item
            assert time.monotonic() < end, 'expected event did not arrive'


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        try:
            while data := self.request.recv(65536):
                self.request.sendall(data)
        except OSError:
            pass


class EchoServer(socketserver.ThreadingTCPServer):
    daemon_threads = True


repo = Path(__file__).resolve().parents[1]
bins = Path(sys.argv[1] if len(sys.argv) > 1 else repo / 'rust/target/debug').resolve()
for name in ['rapp-term', 'rapp-service', 'rapp-hub', 'rapp-cli']:
    assert os.access(bins / name, os.X_OK), f'build {name} first'
# A namespace prevents collisions with the single-instance guard and share ports.
uid_map = Path('/proc/self/uid_map').read_text().split()
assert len(uid_map) == 3 and uid_map[0] == '0' and uid_map[1] != '0' and uid_map[2] == '1', 'run with unshare -Urn'
assert [name for _, name in socket.if_nameindex()] == ['lo'], 'use a private network namespace'
subprocess.run(['ip', 'link', 'set', 'lo', 'up'], check=True)

with tempfile.TemporaryDirectory(prefix='rlc-', dir='/tmp') as td, EchoServer(('127.0.0.1', 0), Echo) as echo:
    root = Path(td)
    home = root / 'a'
    local = home / 'local'
    local.mkdir(parents=True)
    visitor = root / 'b'
    (visitor / 'local').mkdir(parents=True)
    tools = root / 'tools'
    desktop = root / 'desktop'
    tools.mkdir()
    desktop.mkdir()
    key = 'rapp' + base64.b32encode(os.urandom(16)).decode().rstrip('=').lower()
    with socket.socket() as reserve:
        reserve.bind(('127.0.0.1', 0))
        ipc_port = reserve.getsockname()[1]
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reserve:
        reserve.bind(('127.0.0.1', 0))
        peer_port = reserve.getsockname()[1]
    config = {'id': '987654321', 'name': 'Linux parity', 'password': 'test-only',
              'port': peer_port, 'ipc_port': ipc_port, 'auto_lock': False, 'check_updates': False, 'key': key}
    (local / 'service.json').write_text(json.dumps(config))
    (visitor / 'local/service.json').write_text(json.dumps({'key': key}))

    def script(path, content):
        path.write_text('#!/usr/bin/python3\n' + content)
        path.chmod(0o700)

    # The service starts without the current display or the terminal's PATH.
    manager_env = {'WAYLAND_DISPLAY': 'rapp-test-display', 'PATH': f'{desktop}:/usr/bin:/bin'}
    script(tools / 'systemctl', f'import json\nprint(json.dumps({manager_env!r}))\n')
    pidfile = root / 'terminal.pid'
    output = root / 'terminal.out'
    script(tools / 'systemd-run', '''import os, subprocess, sys
args = sys.argv[1:]
env = dict(os.environ)
for arg in args[:args.index('--')]:
    if arg.startswith('--setenv='):
        key, value = arg[len('--setenv='):].split('=', 1)
        env[key] = value
subprocess.Popen(args[args.index('--') + 1:], env=env, start_new_session=True,
                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
''')
    script(desktop / 'foot', f'''import os, sys
from pathlib import Path
assert sys.argv[1] == '--'
assert os.environ['WAYLAND_DISPLAY'] == 'rapp-test-display'
pid, fd = os.forkpty()
if pid == 0:
    os.execv(sys.argv[2], sys.argv[2:])
Path({str(pidfile)!r}).write_text(str(os.getpid()))
try:
    with open({str(output)!r}, 'wb', buffering=0) as out:
        while data := os.read(fd, 8192):
            out.write(data)
except OSError:
    pass
finally:
    os.close(fd)
os.waitpid(pid, 0)
''')
    cm_log = root / 'cm.json'
    script(tools / 'cm', f'''import json, os, sys
from pathlib import Path
Path({str(cm_log)!r}).write_text(json.dumps({{'args': sys.argv[1:], 'display': os.environ.get('WAYLAND_DISPLAY')}}))
''')
    env = {**os.environ, 'HOME': str(root), 'RAPP_HOME': str(home), 'RAPP_LOCAL': str(local),
           'RAPP_BIN_DIR': str(bins), 'RAPP_LOG_DIR': str(root / 'logs'),
           'RAPP_GUI': str(tools / 'cm'), 'XDG_CONFIG_HOME': str(root / 'config'),
           'XDG_STATE_HOME': str(root / 'state'),
           'PATH': str(tools), 'WAYLAND_DISPLAY': 'old-display'}
    processes = []
    echo_thread = threading.Thread(target=echo.serve_forever, kwargs={'poll_interval': .05}, daemon=True)
    echo_thread.start()
    with (root / 'stderr.log').open('w+') as log:
        def start_service():
            p = subprocess.Popen([bins / 'rapp-service'], env=env, stdout=log, stderr=log)
            processes.append(p)
            return p

        def ipc(cmd):
            with socket.create_connection(('127.0.0.1', ipc_port), timeout=5) as conn:
                conn.sendall((json.dumps({'token': (local / 'ipc.token').read_text().strip()}) + '\n' + json.dumps(cmd) + '\n').encode())
                with conn.makefile('rb') as lines:
                    return json.loads(lines.readline())

        def ready():
            assert service.poll() is None, 'service exited'
            try:
                return ipc({'cmd': 'status'})
            except (OSError, ValueError):
                return None

        def cli(*args, data=None):
            p = subprocess.run([bins / 'rapp-cli', *args], env=env, input=data,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
            assert p.returncode == 0, p.stderr.decode()
            return p.stdout

        try:
            service = start_service()
            status = until(ready)
            assert status['capabilities'] == {'graphical': False, 'terminal': True, 'ports': True}
            assert status['permissions'] is None
            assert ipc({'cmd': 'set_term', 'allow': True})['ok']
            hub = subprocess.Popen([bins / 'rapp-hub'], env={**env, 'RAPP_HOME': str(visitor)},
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
            processes.append(hub)
            events = Lines(hub.stdout)
            def ask(cmd):
                cmd = {**cmd, 'req': time.monotonic_ns()}
                hub.stdin.write(json.dumps(cmd) + '\n')
                hub.stdin.flush()
                result = events.matching(lambda e: e.get('req') == cmd['req'])
                assert result['event'] != 'error', result
                return result

            host = status['id']
            added = ask({'cmd': 'add_host', 'id': f'{host}@127.0.0.1:{status["port"]}', 'password': 'test-only'})
            assert added['event'] == 'host_added', added
            terms = ask({'cmd': 'terms', 'id': host})
            assert 'foot' in terms['hosts'][0]['launchers'], terms
            opened = ask({'cmd': 'open_term', 'id': host, 'app': 'foot', 'shell': '/bin/sh'})
            term = opened['term']
            assert term.startswith('term:pty:'), opened
            renamed = ask({'cmd': 'rename_term', 'id': host, 'term': term, 'name': 'Linux 中文'})
            assert renamed['event'] == 'term_renamed'
            terms = ask({'cmd': 'terms', 'id': host})
            assert any(t['id'] == term and t['name'] == 'Linux 中文' for t in terms['terms'])
            opened = ask({'cmd': 'open', 'id': host, 'app': term, 'embed': True})
            with socket.create_connection(('127.0.0.1', opened['port']), timeout=10) as view:
                def send(message):
                    view.sendall((json.dumps(message) + '\n').encode())
                view.sendall((opened['token'] + '\n').encode())
                with view.makefile('rb') as stream:
                    assert json.loads(stream.readline()) == {'t': 'hello', 'v': 2, 'backend': 'pty'}
                    assert json.loads(stream.readline())['t'] == 'panes'
                    send({'t': 'view', 'pane': '%0', 'cols': 80, 'rows': 24, 'fit': True})
                    send({'t': 'text', 'pane': '%0', 'data': "printf 'LINUX_%s\\n' ROUNDTRIP", 'enter': True})
                    end = time.monotonic() + 10
                    while True:
                        frame = json.loads(stream.readline())
                        assert frame['t'] != 'error', frame
                        if frame['t'] == 'screen':
                            send({'t': 'ack', 'rev': frame['rev']})
                            if 'LINUX_ROUNDTRIP' in ''.join(row[1] for row in frame['lines']):
                                break
                        assert time.monotonic() < end, 'remote input did not reach the screen'
            until(lambda: cm_log.exists())
            assert json.loads(cm_log.read_text()) == {'args': ['--cm'], 'display': 'rapp-test-display'}
            until(lambda: output.exists() and b'LINUX_ROUNDTRIP' in output.read_bytes())
            assert b'\x1b[8;24;80t' in output.read_bytes(), 'fit resize was not forwarded'
            print('PASS hub → service → real terminal: discover, open, rename, view, input, fit, current desktop environment')

            # Use the device's real LAN identity for CLI hosts/pipe, without a relay.
            (local / 'hosts.json').write_bytes((visitor / 'local/hosts.json').read_bytes())
            port = str(echo.server_address[1])
            cli('share', port, '--proto', 'tcp', '--note', 'Linux parity')
            assert port.encode() in cli('share')
            assert host.encode() in cli('hosts')
            assert ipc({'cmd': 'shares'})['shares'][0]['note'] == 'Linux parity'
            payload = b'Linux CLI binary pipe\x00\xff\n' * 1024
            assert cli('pipe', host, port, data=payload) == payload
            cli('unshare', port)
            assert not ipc({'cmd': 'shares'})['shares']
            print('PASS CLI → service: share, list, hosts, authenticated binary pipe with half-close, unshare')

            stop(service)
            assert service.returncode == 0
            service = start_service()
            until(ready)
            # A new hub forces a fresh connection after the service restart.
            hub.stdin.close()
            hub.wait(timeout=10)
            hub = subprocess.Popen([bins / 'rapp-hub'], env={**env, 'RAPP_HOME': str(visitor)},
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
            processes.append(hub)
            events = Lines(hub.stdout)
            terms = ask({'cmd': 'terms', 'id': host})
            assert any(t['id'] == term and t['name'] == 'Linux 中文' for t in terms['terms']), terms
            print('PASS service/hub restart rediscovers the same live terminal and persistent name')
        except BaseException:
            log.flush()
            log.seek(0)
            print(log.read(), file=sys.stderr)
            raise
        finally:
            for process in reversed(processes):
                stop(process)
            if pidfile.exists():
                try:
                    os.killpg(int(pidfile.read_text()), signal.SIGTERM)
                except ProcessLookupError:
                    pass
            echo.shutdown()
            echo_thread.join(timeout=2)
