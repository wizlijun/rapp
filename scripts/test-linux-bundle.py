#!/usr/bin/env python3
"""Smoke-test assembled Linux workers and launcher with private data and ephemeral ports.

Does not launch the GUI, install a service, contact a relay or use saved devices.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import tomllib

repo = Path(__file__).resolve().parents[1]
bundle = Path(sys.argv[1] if len(sys.argv) > 1 else repo / 'gui/build/linux/x64/release/bundle').resolve()
version = tomllib.loads((repo / 'rust/Cargo.toml').read_text())['workspace']['package']['version']
for name in ['rapp', 'rapp-gui', 'rapp-cli', 'rapp-client', 'rapp-session', 'rapp-service', 'rapp-hub', 'rapp-term']:
    assert (bundle / name).is_file() and os.access(bundle / name, os.X_OK), name
assert subprocess.check_output([bundle / 'rapp', '--version'], text=True).strip() == f'rapp {version}'
assert json.loads(subprocess.check_output([bundle / 'rapp-client', 'version', '--json'], text=True)) == {
    'version': version, 'protocol': 12,
}

with tempfile.TemporaryDirectory(prefix='rapp-bundle-') as td, socket.socket() as shared:
    root = Path(td)
    local = root / 'local'
    local.mkdir(mode=0o700)
    # The OS picks a non-default port. If another process wins the bind race, fail
    # the smoke test; never fall back to the user's service port.
    with socket.socket() as reserve:
        reserve.bind(('127.0.0.1', 0))
        ipc_port = reserve.getsockname()[1]
    (local / 'service.json').write_text(json.dumps({
        'id': '987654321', 'name': 'Linux bundle test', 'password': 'test-only',
        'port': 0, 'ipc_port': ipc_port, 'auto_lock': False, 'check_updates': False,
    }))
    env = {**os.environ, 'RAPP_HOME': str(root), 'RAPP_LOCAL': str(local),
           'RAPP_BIN_DIR': str(bundle), 'RAPP_LOG_DIR': str(root / 'logs'), 'PATH': '/usr/bin:/bin'}
    shared.bind(('127.0.0.1', 0))
    shared.listen(16)
    port = shared.getsockname()[1]
    def cli(*args):
        return subprocess.check_output([bundle / 'rapp', *args], env=env, text=True, stderr=subprocess.STDOUT, timeout=15)
    with (root / 'stderr.log').open('w') as log:
        process = subprocess.Popen([bundle / 'rapp-service'], env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        try:
            status = None
            end = time.monotonic() + 15
            while time.monotonic() < end:
                assert process.poll() is None, 'bundled service exited before readiness'
                token = local / 'ipc.token'
                try:
                    if token.exists():
                        with socket.create_connection(('127.0.0.1', ipc_port), timeout=1) as connection:
                            connection.sendall((json.dumps({'token': token.read_text().strip()}) + '\n' +
                                                json.dumps({'cmd': 'status'}) + '\n').encode())
                            with connection.makefile('rb') as lines:
                                status = json.loads(lines.readline())
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
            assert str(port) in cli('share'), 'CLI did not reach bundled service share table'
            cli('unshare', str(port))
            assert str(port) not in cli('share'), 'CLI unshare did not persist'
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        assert process.returncode == 0, f'bundled service shutdown: {process.returncode}'
print('PASS bundle inventory, protocol, private service capabilities and real CLI port sharing')
