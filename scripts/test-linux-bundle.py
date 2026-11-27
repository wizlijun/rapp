#!/usr/bin/env python3
"""Smoke-test assembled Linux workers, global share numbers and the CLI in isolation.

Does not launch the GUI, install a service, contact a relay or use saved devices.
"""
import http.client
import json
import os
import queue
from pathlib import Path
import re
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time
import tomllib
import zlib

repo = Path(__file__).resolve().parents[1]
bundle = Path(sys.argv[1] if len(sys.argv) > 1 else repo / 'gui/build/linux/x64/release/bundle').resolve()
version = tomllib.loads((repo / 'rust/Cargo.toml').read_text())['workspace']['package']['version']
protocol_source = (repo / 'rust/client-core/src/protocol.rs').read_text()
protocol = re.search(r'^pub const VERSION: u8 = (\d+);$', protocol_source, re.MULTILINE)
assert protocol, 'client protocol version declaration not found'
for name in ['rapp', 'rapp-gui', 'rapp-cli', 'rapp-client', 'rapp-session', 'rapp-host', 'rapp-service', 'rapp-hub', 'rapp-term', 'rapp-center', 'rapp-speech']:
    assert (bundle / name).is_file() and os.access(bundle / name, os.X_OK), name
assert subprocess.check_output([bundle / 'rapp', '--version'], text=True).strip() == f'rapp {version}'
assert json.loads(subprocess.check_output([bundle / 'rapp-client', 'version', '--json'], text=True)) == {
    'version': version, 'protocol': int(protocol[1]),
}


assert json.loads(subprocess.check_output([bundle / 'rapp-speech', '--version'], text=True)) == {
    'version': version, 'backend': 'whisper.cpp', 'local': True,
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
           'RAPP_BIN_DIR': str(bundle), 'RAPP_LOG_DIR': str(root / 'logs'),
           'RAPP_GUI': str(root / 'no-gui'), 'PATH': '/usr/bin:/bin'}
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
                assert status['capabilities'] == {'graphical': True, 'desktop': True, 'applications': status['permissions'].get('applications') is True, 'terminal': True, 'ports': True}, status['capabilities']
                assert status['permissions']['platform'] == 'linux', status['permissions']
                # Exercise the real hub -> QUIC service -> Linux desktop worker path.
                # Only capture is requested: no input, clipboard operation or screen lock.
                if status['permissions']['screen_recording']:
                    visitor = root / 'visitor'
                    hub_env = {**env, 'RAPP_HOME': str(visitor), 'RAPP_LOCAL': str(visitor / 'local')}
                    hub = subprocess.Popen([bundle / 'rapp-hub'], env=hub_env, stdin=subprocess.PIPE,
                                           stdout=subprocess.PIPE, stderr=log, text=True)
                    events = queue.Queue()
                    def read_events():
                        for line in hub.stdout:
                            events.put(json.loads(line))
                    threading.Thread(target=read_events, daemon=True).start()
                    def ask(command):
                        req = time.monotonic_ns()
                        hub.stdin.write(json.dumps({**command, 'req': req}) + '\n')
                        hub.stdin.flush()
                        deadline = time.monotonic() + 15
                        while True:
                            event = events.get(timeout=max(.001, deadline - time.monotonic()))
                            if event.get('req') == req:
                                assert event['event'] != 'error', event
                                return event
                    try:
                        host = status['id']
                        ask({'cmd': 'add_host', 'id': f'{host}@127.0.0.1:{status["port"]}', 'password': 'test-only'})
                        apps = ask({'cmd': 'apps', 'id': host})
                        expected_os = 'omarchy' if Path('/usr/share/omarchy/shell').exists() else 'linux'
                        assert apps.get('os') == expected_os, apps
                        assert apps['capabilities']['applications'] is (status['permissions'].get('applications') is True), apps
                        assert any(a['app'] == 'desktop:' and a['displays'] for a in apps['apps']), apps
                        opened = ask({'cmd': 'open', 'id': host, 'app': 'desktop:', 'embed': True})
                        with socket.create_connection(('127.0.0.1', opened['port']), timeout=10) as view:
                            def string(value):
                                value = value.encode()
                                return struct.pack('<H', len(value)) + value
                            # Embedded Swift and Rust clients leave the app empty:
                            # the authenticated tunnel is already bound to desktop:.
                            hello = bytes([int(protocol[1])]) + string(opened['token']) + string('') + struct.pack('<BBf', 2, 5, 1.)
                            view.sendall(bytes([1]) + struct.pack('<I', len(hello)) + hello)
                            stream = view.makefile('rb')
                            for _ in range(20):
                                header = stream.read(5)
                                assert len(header) == 5, 'desktop worker disconnected'
                                kind, size = header[0], struct.unpack('<I', header[1:])[0]
                                assert size <= 64 * 1024 * 1024
                                payload = stream.read(size)
                                assert len(payload) == size
                                assert kind != 3, payload
                                if kind == 4:
                                    assert payload[21] & 7 == 7, 'first picture must be a full frame'
                                    tiles = zlib.decompressobj().decompress(payload[22:])
                                    assert struct.unpack('<H', tiles[:2])[0] > 0
                                    break
                            else:
                                raise AssertionError('no desktop frame through the hub/service')
                        print('PASS bundled hub -> service -> desktop capture over QUIC')
                    finally:
                        hub.stdin.close()
                        try:
                            hub.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            hub.kill()
                            hub.wait(timeout=5)
                cli('hosts')
                upd_status = json.loads(cli('update', 'status', '--json'))
                assert upd_status['ok'] is True and upd_status['state'] == 'off' and upd_status['current'] == version, upd_status
                upd_apply = subprocess.run([bundle / 'rapp', 'update', '--json'],
                    env=env, text=True, capture_output=True, timeout=15)
                assert upd_apply.returncode == 7, upd_apply
                upd_err = json.loads(upd_apply.stdout)
                assert upd_err['ok'] is False and upd_err['error'] == 'not_launchd', upd_err
                assert upd_err['page'] == 'https://github.com/wizlijun/rapp/releases', upd_err
                lbl0 = ipc({'cmd': 'labels'})
                assert lbl0 == {'ok': True, 'rev': 0, 'labels': {}}, lbl0
                lbl_set = ipc({'cmd': 'set_label', 'app': 'term:pty:linux1', 'title': 'Linux 后端', 'note': '仅存本机加密表'})
                assert lbl_set == {'ok': True, 'rev': 1}, lbl_set
                assert (local / 'labels.json').stat().st_mode & 0o777 == 0o600
                lbl1 = ipc({'cmd': 'labels'})
                assert lbl1['rev'] == 1 and lbl1['labels']['term:pty:linux1']['title'] == 'Linux 后端', lbl1
                lbl_rst = ipc({'cmd': 'reset_label', 'app': 'term:pty:linux1'})
                assert lbl_rst == {'ok': True, 'rev': 2}, lbl_rst
                assert ipc({'cmd': 'labels'})['labels'] == {}
                assert cli('term', 'restore', '--list') == '没有可以恢复的终端\n'
                assert cli('term', 'restore') == '没有可以恢复的终端\n'
                assert cli('term', 'restore', '--forget') == '已清掉 0 个\n'
                saved_dir = local / 'term' / 'saved'
                saved_dir.mkdir(parents=True, mode=0o700, exist_ok=True)
                btime = next(int(l.split()[1]) for l in Path('/proc/stat').read_text().splitlines() if l.startswith('btime '))
                now_ts = int(time.time())
                saved_ts = btime - 60 if now_ts - (btime - 60) <= 29 * 86400 else now_ts - 3600
                snap_key = '00000000000000a1'
                snap_file = saved_dir / f'{snap_key}.json'
                snap_file.write_text(json.dumps({
                    'v': 1, 'key': snap_key, 'name': 'linux-snap', 'named': True,
                    'shell': '/bin/sh', 'cwd': str(root), 'prog': 'claude', 'cmd': 'claude -c',
                    'started': saved_ts - 10, 'saved': saved_ts,
                }))
                snap_file.chmod(0o600)
                term_saved = ipc({'cmd': 'term_saved'})
                assert term_saved['ok'] is True and len(term_saved['saved']) == 1, term_saved
                assert term_saved['saved'][0]['key'] == snap_key and term_saved['saved'][0]['boot'] is (saved_ts < btime), term_saved
                assert term_saved['saved'][0]['cwd'] == str(root) and term_saved['saved'][0]['prog'] == 'claude', term_saved
                listed = cli('term', 'restore', '--list')
                assert 'linux-snap' in listed and 'claude' in listed and str(root) in listed, listed
                assert cli('term', 'restore', '--forget') == '已清掉 1 个\n'
                assert not snap_file.exists()
                assert cli('term', 'restore', '--list') == '没有可以恢复的终端\n'
                state0 = cli('state')
                assert '状态服务：没开' in state0, state0
                assert ipc({'cmd': 'state'})['url'] is None
                state_on = cli('state', 'on')
                assert '已打开状态服务' in state_on, state_on
                st_ipc = ipc({'cmd': 'state'})
                assert st_ipc['running'] is True and st_ipc['url'] == 'http://127.0.0.1:8102', st_ipc
                sse = http.client.HTTPConnection('127.0.0.1', 8102, timeout=3)
                try:
                    sse.request('GET', '/v1/watch', headers={'Accept': 'text/event-stream'})
                    resp = sse.getresponse()
                    assert resp.status == 200, resp.status
                    hello_line = resp.readline().decode('utf-8').strip()
                    assert hello_line.startswith('data:') and json.loads(hello_line[5:].strip()) == {'what': 'hello'}, hello_line
                finally:
                    sse.close()
                desk_http = http.client.HTTPConnection('127.0.0.1', 8102, timeout=3)
                try:
                    desk_body = json.dumps({
                        'device': 'linux-box',
                        'sessions': [{'id': '123456789', 'app': 'term:pty:t1', 'name': 'claude'}],
                    })
                    desk_http.request('PUT', '/v1/desk/linuxfp1', body=desk_body, headers={'Content-Type': 'application/json'})
                    desk_resp = desk_http.getresponse()
                    desk_resp.read()
                    assert desk_resp.status == 204, desk_resp.status
                    desk_http.request('GET', '/v1/state')
                    state_resp = desk_http.getresponse()
                    state_snap = json.loads(state_resp.read().decode('utf-8'))
                    assert state_resp.status == 200, state_resp.status
                    assert any(
                        d.get('fp') == 'linuxfp1'
                        and d.get('device') == 'linux-box'
                        and d.get('sessions') == [{'id': '123456789', 'app': 'term:pty:t1', 'name': 'claude'}]
                        for d in state_snap.get('desks', [])
                    ), state_snap
                finally:
                    desk_http.close()
                st_off_ipc = ipc({'cmd': 'state', 'on': False})
                assert st_off_ipc.get('on') is False and st_off_ipc.get('running') is False, st_off_ipc
                st_on_ipc = ipc({'cmd': 'state', 'on': True})
                assert st_on_ipc.get('on') is True and st_on_ipc.get('running') is True, st_on_ipc
                state_off = cli('state', 'off')
                assert '已关掉状态服务' in state_off, state_off
                assert ipc({'cmd': 'state'})['url'] is None
                assert not ipc({'cmd': 'shares'})['shares'], 'state off left a share behind'
                load_end = time.monotonic() + 8
                load_json = None
                while time.monotonic() < load_end:
                    load_json = json.loads(cli('load', '--json'))
                    assert load_json['ok'] is True, load_json
                    if 'load' in load_json['devices'][0]:
                        break
                    time.sleep(.2)
                assert load_json and 'load' in load_json['devices'][0], load_json
                local_load = load_json['devices'][0]['load']
                assert local_load['term'] is True and local_load['items']['mem']['total'] > 0, local_load
                assert len(local_load['disks']) >= 1, local_load
                picked = json.loads(cli('load', 'pick', '--json'))
                assert picked['ok'] is True and picked['id'] == status['id'], picked
                svc_log = (root / 'logs' / 'service.log').read_text()
                assert 'Linux 后端' not in svc_log and '仅存本机加密表' not in svc_log, svc_log
                assert 'linux-snap' not in svc_log and snap_key not in svc_log and str(root) not in svc_log, svc_log
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
