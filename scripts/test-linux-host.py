#!/usr/bin/env python3
"""Native desktop host tests, without changing the user's desktop or service.

Requires Xvfb and labwc (with Xwayland). Optional --current also exercises the
current desktop's capture/transport, without injecting input or locking it.
Custom executable paths allow testing with packages extracted into /tmp.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--xvfb', default=shutil.which('Xvfb'))
parser.add_argument('--labwc', default=shutil.which('labwc'))
parser.add_argument('--current', action='store_true')
args = parser.parse_args()
if not args.xvfb or not args.labwc:
    parser.error('Xvfb and labwc are required; provide --xvfb and --labwc paths if not installed')

build = subprocess.check_output(['cargo', 'test', '--manifest-path', str(repo / 'rust/Cargo.toml'),
    '-p', 'rapp-host-linux', '--test', 'desktop', '--no-run', '--message-format=json'], text=True)
binary = next(item['executable'] for line in build.splitlines()
    if (item := json.loads(line)).get('reason') == 'compiler-artifact'
    and item['target']['name'] == 'desktop' and item.get('executable'))


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


base = dict(os.environ)
base.pop('WAYLAND_DEBUG', None)
with tempfile.TemporaryDirectory(prefix='rapp-host-native-') as td:
    root = Path(td)
    with (root / 'xvfb.log').open('w') as log:
        process = subprocess.Popen([args.xvfb, '-displayfd', '1', '-screen', '0', '800x600x24',
            '-nolisten', 'tcp'], stdout=subprocess.PIPE, stderr=log, text=True)
        try:
            import select
            assert select.select([process.stdout], [], [], 5)[0], 'Xvfb did not start'
            display = process.stdout.readline().strip()
            assert display.isdigit(), (root / 'xvfb.log').read_text()
            env = {**base, 'DISPLAY': ':' + display, 'RAPP_TEST_ISOLATED_DESKTOP': '1'}
            env.pop('WAYLAND_DISPLAY', None)
            subprocess.run([binary, '--ignored', '--nocapture', '--test-threads=1'], env=env, check=True, timeout=45)
        finally:
            stop(process)

    runtime = root / 'runtime'
    runtime.mkdir(mode=0o700)
    config = root / 'config'
    config.mkdir()
    (config / 'autostart').write_text('')
    (config / 'environment').write_text('')
    startup = root / 'test.py'
    startup.write_text('''import os, subprocess, sys
from pathlib import Path
os.environ['RAPP_TEST_ISOLATED_DESKTOP'] = '1'
result = subprocess.run([sys.argv[1], '--ignored', '--nocapture', '--test-threads=1'], timeout=40)
Path(os.environ['XDG_RUNTIME_DIR'], 'result').write_text(str(result.returncode))
''')
    env = {**base, 'XDG_RUNTIME_DIR': str(runtime), 'XDG_CONFIG_DIRS': str(config),
           'WLR_BACKENDS': 'headless', 'WLR_RENDERER': 'pixman', 'WLR_HEADLESS_OUTPUTS': '1'}
    for key in ['DISPLAY', 'WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE']:
        env.pop(key, None)
    lib = Path(args.labwc).resolve().parent.parent / 'lib'
    env['LD_LIBRARY_PATH'] = str(lib) + ':' + env.get('LD_LIBRARY_PATH', '')
    with (root / 'wayland.log').open('w') as log:
        process = subprocess.Popen([args.labwc, '-C', str(config), '-S',
            shlex.join([sys.executable, str(startup), binary])], env=env, stdout=log, stderr=log)
        try:
            process.wait(timeout=50)
        finally:
            stop(process)
        output = (root / 'wayland.log').read_text()
        result = runtime / 'result'
        assert result.exists() and result.read_text() == '0', output
        print('PASS isolated Wayland: capture, input, Unicode, modifiers, auth, takeover, kick and EOF')

if args.current:
    subprocess.run([binary, '--ignored', '--exact', 'native_desktop_stream_auth_takeover_ping_kick_and_eof',
        '--nocapture'], env=base, check=True, timeout=30)
print('PASS Linux host native backends')
