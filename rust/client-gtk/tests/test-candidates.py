#!/usr/bin/env python3
"""Private GTK4 + DBus candidate regression. Never uses the desktop display/bus.

Requires gtk4-broadwayd, chromium and dbus-run-session. The headless browser is
necessary for Broadway to give the test window real focus and render frames.
With --client-fixture, RAPP_TEST_CLIENT_BIN selects a packaged client to verify.
"""
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parents[3]
if sys.argv[1:] not in ([], ['--client-fixture']):
    raise SystemExit('Usage: test-candidates.py [--client-fixture]')
command = (['python3', 'scripts/test-linux-client.py',
            os.environ.get('RAPP_TEST_CLIENT_BIN', 'rust/target/debug/rapp-client')]
           if sys.argv[1:] else ['cargo', 'test', '--manifest-path', 'rust/Cargo.toml',
           '-p', 'rapp-client-gtk', '--offline', 'isolated_candidates', '--', '--ignored', '--nocapture'])
for tool in ['gtk4-broadwayd', 'chromium', 'dbus-run-session', 'cargo']:
    if shutil.which(tool) is None:
        raise SystemExit(f'Missing test tool: {tool}')

with tempfile.TemporaryDirectory(prefix='rapp-candidates-') as temporary:
    runtime = Path(temporary) / 'runtime'
    runtime.mkdir(mode=0o700)
    # No service directories: the mock bus cannot autostart desktop portals,
    # keyrings, or an installed fcitx instance during a client fixture.
    bus_config = Path(temporary) / 'bus.conf'
    bus_config.write_text('<busconfig><type>session</type>'
        '<listen>unix:tmpdir=/tmp</listen><auth>EXTERNAL</auth>'
        '<policy context="default"><allow send_destination="*"/>'
        '<allow receive_sender="*"/><allow own="*"/></policy></busconfig>')
    env = {**os.environ, 'XDG_RUNTIME_DIR': str(runtime), 'GIO_USE_VFS': 'local',
           'DBUS_SESSION_BUS_ADDRESS': 'unix:path=/nonexistent-rapp-test-bus'}
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    daemon = subprocess.Popen(['gtk4-broadwayd', '--address=127.0.0.1', f'--port={port}', ':1'],
                              env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    browser = None
    try:
        for _ in range(100):
            if daemon.poll() is not None:
                raise RuntimeError(daemon.stderr.read().decode())
            if (runtime / 'broadway2.socket').exists():
                break
            time.sleep(.05)
        else:
            raise TimeoutError('Private Broadway did not start')
        browser = subprocess.Popen(['chromium', '--headless', '--no-sandbox', '--disable-gpu',
            '--disable-dev-shm-usage', f'--user-data-dir={temporary}/browser',
            '--remote-debugging-port=0', f'http://127.0.0.1:{port}'], env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        time.sleep(1)
        result = subprocess.run(['dbus-run-session', f'--config-file={bus_config}', '--', 'env', 'GDK_BACKEND=broadway',
            'BROADWAY_DISPLAY=:1', 'GTK_A11Y=none', 'RAPP_CANDIDATE_TEST_PRIVATE_BUS=1',
            *command],
            cwd=root, env=env, timeout=60)
    finally:
        if browser is not None:
            try:
                os.killpg(browser.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            browser.wait(timeout=5)
        daemon.terminate()
        daemon.wait(timeout=5)
        time.sleep(.2)
    raise SystemExit(result.returncode)
