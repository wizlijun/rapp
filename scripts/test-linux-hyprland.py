#!/usr/bin/env python3
"""Real Hyprland host regression in a nested compositor with no access to input/DRM-master devices.

Requires Hyprland, labwc, bubblewrap, PyGObject/GTK3 and a DRM render node. The
read-only sandbox exposes only that render node, a private runtime directory,
and a private D-Bus with service activation disabled. Never uses the real desktop.
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


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def nested(root, render):
    env = dict(os.environ)
    for key in ['HYPRLAND_INSTANCE_SIGNATURE', 'DISPLAY']:
        env.pop(key, None)
    env.update(HYPRLAND_NO_SD_VARS='1', HYPRLAND_NO_SD_NOTIFY='1',
               HYPRLAND_NO_CRASHREPORTER='1', AQ_DRM_DEVICES='/dev/dri/nonexistent')
    command = ['bwrap', '--ro-bind', '/', '/', '--tmpfs', '/tmp', '--bind', str(root), str(root),
               '--dev', '/dev', '--proc', '/proc', '--dev-bind', render, render,
               '--unshare-pid', '--die-with-parent', 'Hyprland', '--config', str(root / 'hypr.conf')]
    with (root / 'hypr.log').open('w') as log:
        process = subprocess.Popen(command, env=env, stdout=log, stderr=log)
        try:
            process.wait(timeout=45)
        finally:
            stop(process)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--labwc', default=shutil.which('labwc'))
    parser.add_argument('--render-node', default='/dev/dri/renderD128')
    parser.add_argument('--nested')
    args = parser.parse_args()
    if args.nested:
        nested(Path(args.nested), args.render_node)
        return
    assert args.labwc and shutil.which('Hyprland') and shutil.which('bwrap')
    assert Path(args.render_node).name.startswith('renderD') and Path(args.render_node).is_char_device()
    build = subprocess.check_output(['cargo', 'test', '--manifest-path', str(repo / 'rust/Cargo.toml'),
        '-p', 'rapp-host-linux', '--test', 'desktop', '--no-run', '--message-format=json'], text=True)
    binary = next(item['executable'] for line in build.splitlines()
        if (item := json.loads(line)).get('reason') == 'compiler-artifact'
        and item['target']['name'] == 'desktop' and item.get('executable'))
    # Short runtime paths also leave room for Hyprland's long instance signature.
    with tempfile.TemporaryDirectory(prefix='rh-') as directory:
        root = Path(directory)
        runtime = root / 'r'
        runtime.mkdir(mode=0o700)
        config = root / 'labwc'
        config.mkdir()
        for name in ['autostart', 'environment']:
            (config / name).write_text('')
        env = dict(os.environ)
        for key in ['DISPLAY', 'WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'AT_SPI_BUS_ADDRESS']:
            env.pop(key, None)
        env.update(XDG_RUNTIME_DIR=str(runtime), WLR_BACKENDS='headless', WLR_RENDERER='gles2',
                   WLR_RENDER_DRM_DEVICE=args.render_node, WLR_HEADLESS_OUTPUTS='1', GTK_A11Y='none',
                   NO_AT_BRIDGE='1', GSK_RENDERER='cairo', GIO_USE_VFS='local', GSETTINGS_BACKEND='memory')
        for key in ['XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME']:
            path = root / key
            path.mkdir()
            env[key] = str(path)
        env['LD_LIBRARY_PATH'] = str(Path(args.labwc).resolve().parent.parent / 'lib') + ':' + env.get('LD_LIBRARY_PATH', '')
        bus = root / 'bus.conf'
        bus.write_text('<busconfig><type>session</type><listen>unix:tmpdir=' + directory + '</listen><auth>EXTERNAL</auth><policy context="default"><allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/></policy></busconfig>')
        startup = root / 'test.py'
        startup.write_text('''import os, pathlib, subprocess, time
os.environ['RAPP_TEST_ISOLATED_DESKTOP'] = '1'
subprocess.run(['hyprctl', 'output', 'create', 'headless', 'RAPP-TEST'], check=True)
subprocess.run(['hyprctl', 'output', 'create', 'headless', 'RAPP-TEST2'], check=True)
time.sleep(1)
with open(%r, 'w') as log:
    result = subprocess.run([%r, '--ignored', '--nocapture', '--test-threads=1'], stdout=log, stderr=log, timeout=35)
pathlib.Path(%r).write_text(str(result.returncode))
subprocess.run(['hyprctl', 'dispatch', 'exit'])
''' % (str(root / 'test.log'), binary, str(root / 'result')))
        (root / 'hypr.conf').write_text('monitor = ,800x600@60,auto,1\nmonitor = RAPP-TEST,800x600@60,0x0,1\nmonitor = RAPP-TEST2,800x600@60,800x0,1\nmisc {\n disable_hyprland_logo = true\n disable_splash_rendering = true\n}\nanimations {\n enabled = false\n}\nexec-once = ' + shlex.join([sys.executable, str(startup)]) + '\n')
        with (root / 'labwc.log').open('w') as log:
            process = subprocess.Popen(['dbus-run-session', '--config-file', str(bus), '--', args.labwc,
                '-C', str(config), '-S', shlex.join([sys.executable, __file__, '--nested', directory, '--render-node', args.render_node])], env=env, stdout=log, stderr=log)
            try:
                process.wait(timeout=52)
            finally:
                stop(process)
        logs = repo / '.build-logs'
        logs.mkdir(exist_ok=True)
        for name in ['labwc.log', 'hypr.log', 'test.log']:
            if (root / name).exists():
                shutil.copyfile(root / name, logs / ('native-hyprland-' + name))
        result = root / 'result'
        assert result.exists() and result.read_text() == '0', 'nested Hyprland regression failed; see .build-logs/native-hyprland-*.log'
        print('PASS isolated Hyprland: application pixels, window control, covers, clipboard, input and transport')


if __name__ == '__main__':
    main()
