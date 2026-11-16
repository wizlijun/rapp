#!/usr/bin/env python3
"""Compile and exercise GTK3 candidates on a private display and D-Bus session."""
import os
from pathlib import Path
import shlex
import shutil
import signal
import socket
import subprocess
import tempfile
import time

source = Path(__file__).resolve().parents[1]
root = source.parents[2]
headers = Path(os.environ.get('FLUTTER_ENGINE_HEADERS', root / 'gui/linux/flutter/ephemeral'))
if not (headers / 'flutter_linux/flutter_linux.h').exists():
    flutter = os.environ.get('FLUTTER') or shutil.which('flutter')
    if flutter:
        headers = Path(flutter).resolve().parents[1] / 'bin/cache/artifacts/engine/linux-x64'
if not (headers / 'flutter_linux/flutter_linux.h').exists():
    raise SystemExit('Set FLUTTER_ENGINE_HEADERS to the directory containing flutter_linux/.')
for tool in ['broadwayd', 'chromium', 'dbus-run-session', 'pkg-config', 'c++']:
    if not shutil.which(tool):
        raise SystemExit(f'Missing test tool: {tool}')
artifacts = Path(tempfile.mkdtemp(prefix='rapp-candidates-gtk-'))
print(f'Private GTK3 test artifacts: {artifacts}', flush=True)
flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'gtk+-3.0'], text=True))
binary = artifacts / 'test'
subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-Wall', '-Wextra', '-Werror', '-g',
    f'-I{source}', f'-I{headers}', str(source / 'rapp_candidates.cc'),
    str(source / 'rapp_candidates_gtk.cc'), str(source / 'tests/candidates_gtk_test.cc'),
    '-o', str(binary), *flags], check=True)
with tempfile.TemporaryDirectory(prefix='rapp-gtk3-display-') as temporary:
    runtime = Path(temporary) / 'runtime'
    runtime.mkdir(mode=0o700)
    env = {**os.environ, 'XDG_RUNTIME_DIR': str(runtime), 'GIO_USE_VFS': 'local',
        'DBUS_SESSION_BUS_ADDRESS': 'unix:path=/nonexistent-rapp-test-bus'}
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    daemon = subprocess.Popen(['broadwayd', '--address=127.0.0.1', f'--port={port}', ':1'],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    browser = None
    try:
        for _ in range(100):
            if daemon.poll() is not None:
                raise RuntimeError(daemon.stderr.read().decode())
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.1):
                    break
            except OSError:
                pass
            time.sleep(.05)
        else:
            raise TimeoutError('Private GTK3 Broadway did not start')
        browser = subprocess.Popen(['chromium', '--headless', '--no-sandbox', '--disable-gpu',
            '--disable-dev-shm-usage', f'--user-data-dir={temporary}/browser',
            '--remote-debugging-port=0', f'http://127.0.0.1:{port}'], env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        time.sleep(1)
        result = subprocess.run(['dbus-run-session', '--', 'env', 'GDK_BACKEND=broadway',
            'BROADWAY_DISPLAY=:1', 'NO_AT_BRIDGE=1', 'G_DEBUG=fatal-warnings',
            'RAPP_CANDIDATES_ISOLATED_TEST=1', f'RAPP_CANDIDATE_PNG={artifacts}/candidates.png',
            str(binary)], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        (artifacts / 'test.log').write_text(result.stdout)
        print(result.stdout, end='')
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
