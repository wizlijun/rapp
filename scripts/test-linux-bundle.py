#!/usr/bin/env python3
"""Smoke-test assembled Linux workers, global share numbers and the CLI in isolation.

Does not launch the GUI, install a service, contact a relay or use saved devices.
"""
import json
import os
from pathlib import Path
import re
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import tomllib

repo = Path(__file__).resolve().parents[1]
bundle = Path(sys.argv[1] if len(sys.argv) > 1 else repo / 'gui/build/linux/x64/release/bundle').resolve()
version = tomllib.loads((repo / 'rust/Cargo.toml').read_text())['workspace']['package']['version']
protocol_source = (repo / 'rust/client-core/src/protocol.rs').read_text()
protocol = re.search(r'^pub const VERSION: u8 = (\d+);$', protocol_source, re.MULTILINE)
assert protocol, 'client protocol version declaration not found'
for name in ['rapp', 'rapp-gui', 'rapp-cli', 'rapp-client', 'rapp-session', 'rapp-service', 'rapp-hub', 'rapp-term']:
    assert (bundle / name).is_file() and os.access(bundle / name, os.X_OK), name
assert subprocess.check_output([bundle / 'rapp', '--version'], text=True).strip() == f'rapp {version}'
assert json.loads(subprocess.check_output([bundle / 'rapp-client', 'version', '--json'], text=True)) == {
    'version': version, 'protocol': int(protocol[1]),
}


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(3)
        try:
            while data := self.request.recv(65536):
                self.request.sendall(data)
        except OSError:
            pass  # Protocol probes may close without reading the echoed handshake.


class EchoServer(socketserver.ThreadingTCPServer):
    daemon_threads = True


def sockets_of(pid):
    """Only this test's service sockets; never infer listeners from other processes."""
    inodes = set()
    for fd in Path(f'/proc/{pid}/fd').iterdir():
        try:
            target = os.readlink(fd)
        except OSError:
            continue
        if target.startswith('socket:['):
            inodes.add(target[8:-1])
    rows = []
    for kind in ['tcp', 'tcp6', 'udp', 'udp6']:
        table = Path(f'/proc/{pid}/net/{kind}')
        if not table.exists() and kind.endswith('6'):
            continue  # A kernel without IPv6 has no tcp6/udp6 table.
        for line in table.read_text().splitlines()[1:]:
            fields = line.split()
            if fields[9] in inodes:
                address, port = fields[1].split(':')
                rows.append((kind, address, int(port, 16), fields[3]))
    return rows


with tempfile.TemporaryDirectory(prefix='rapp-bundle-') as td, EchoServer(('127.0.0.1', 0), Echo) as shared:
    root = Path(td)
    local = root / 'local'
    local.mkdir(mode=0o700)
    # The OS picks a non-default port. A bind race fails the test; it never falls
    # back to the user's service port.
    with socket.socket() as reserve:
        reserve.bind(('127.0.0.1', 0))
        ipc_port = reserve.getsockname()[1]
    (local / 'service.json').write_text(json.dumps({
        'id': '987654321', 'name': 'Linux bundle test', 'password': 'test-only',
        'port': 0, 'ipc_port': ipc_port, 'auto_lock': False, 'check_updates': False,
    }))
    env = {**os.environ, 'RAPP_HOME': str(root), 'RAPP_LOCAL': str(local),
           'RAPP_BIN_DIR': str(bundle), 'RAPP_LOG_DIR': str(root / 'logs'), 'PATH': '/usr/bin:/bin'}
    port = shared.server_address[1]
    echo_thread = threading.Thread(target=shared.serve_forever, kwargs={'poll_interval': .05}, daemon=True)
    echo_thread.start()

    def cli(*args):
        return subprocess.check_output([bundle / 'rapp', *args], env=env, text=True, stderr=subprocess.STDOUT, timeout=15)

    def ipc(command):
        with socket.create_connection(('127.0.0.1', ipc_port), timeout=2) as connection:
            connection.sendall((json.dumps({'token': (local / 'ipc.token').read_text().strip()}) + '\n' +
                                json.dumps(command) + '\n').encode())
            with connection.makefile('rb') as lines:
                return json.loads(lines.readline())

    def row():
        reply = ipc({'cmd': 'shares'})
        assert reply['ok'], reply
        return next(s for s in reply['shares'] if s['port'] == port)

    try:
        with (root / 'stderr.log').open('w') as log:
            process = subprocess.Popen([bundle / 'rapp-service'], env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            try:
                status = None
                end = time.monotonic() + 15
                while time.monotonic() < end:
                    assert process.poll() is None, 'bundled service exited before readiness'
                    try:
                        status = ipc({'cmd': 'status'})
                        if status.get('ok'):
                            break
                    except (OSError, ValueError):
                        pass
                    time.sleep(.1)
                assert status and status.get('ok'), 'bundled service did not become ready'
                assert status['capabilities'] == {'graphical': False, 'terminal': True, 'ports': True}, status['capabilities']
                assert status['permissions'] is None, status['permissions']
                cli('hosts')
                cli('share', str(port), '--note', 'bundle smoke')
                item = row()
                number = item['local']
                assert 28000 <= number <= 28999, item
                assert item['proto'] == 'tcp' and item['proto_auto'] is True, item
                assert item['addr'] == f'tcp://localhost:{number}', item
                assert item['addr'] in cli('share'), 'CLI omitted the shared address'
                sockets = sockets_of(process.pid)
                listeners = [s for s in sockets if s[0].startswith('tcp') and s[3] == '0A']
                loopbacks = {'0100007F', '00000000000000000000000001000000'}
                assert listeners and all(s[1] in loopbacks for s in listeners), listeners
                assert not any(s[0].startswith('udp') and s[2] == number for s in sockets), sockets
                addresses = ['127.0.0.1']
                if any(s[0] == 'tcp6' and s[2] == number for s in listeners):
                    addresses.append('::1')
                for address in addresses:
                    with socket.create_connection((address, number), timeout=3) as connection:
                        payload = b'Linux share-number loopback\n'
                        connection.sendall(payload)
                        connection.shutdown(socket.SHUT_WR)
                        with connection.makefile('rb') as stream:
                            assert stream.read() == payload, address
                cli('share', str(port), '--proto', 'ssh')
                item = row()
                assert item['local'] == number and item['proto_auto'] is False, item
                assert item['addr'] == f'ssh -p {number} localhost', item
                cli('share', str(port), '--proto', 'tcp')
                assert row()['local'] == number, 'changing the protocol renumbered the share'
                unsupported = subprocess.run([bundle / 'rapp', 'share', str(port), '--proto', 'udp'],
                    env=env, text=True, capture_output=True, timeout=15)
                assert unsupported.returncode == 2, unsupported
                assert row()['proto'] == 'tcp', 'unsupported UDP changed the share'
                cli('unshare', str(port))
                assert not ipc({'cmd': 'shares'})['shares'], 'CLI unshare did not persist'
                assert f'localhost:{number}' not in cli('share'), 'CLI retained the removed address'
                end = time.monotonic() + 3
                while any(s[0].startswith('tcp') and s[2] == number and s[3] == '0A' for s in sockets_of(process.pid)):
                    assert time.monotonic() < end, 'unshare did not close the share-number listeners'
                    time.sleep(.02)
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            assert process.returncode == 0, f'bundled service shutdown: {process.returncode}'
    finally:
        shared.shutdown()
        echo_thread.join(timeout=2)
print('PASS bundle versions/protocol, private service capabilities, CLI protocols, TCP loopback share numbers and listener cleanup')
