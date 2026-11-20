#!/usr/bin/env python3
"""Exercise the real AT-SPI helper against synthetic GTK controls on a private bus/display."""
import argparse
import json
import os
from pathlib import Path
import select
import struct
import subprocess
import sys
import tempfile
import time


def exercise(host):
    bus = subprocess.Popen(['dbus-daemon', '--config-file=' + os.environ['RAPP_TEST_BUS_CONFIG'], '--nofork', '--print-address=1'], stdout=subprocess.PIPE)
    assert select.select([bus.stdout], [], [], 3)[0]
    address = bus.stdout.readline().decode().strip()
    os.environ['AT_SPI_BUS_ADDRESS'] = address
    registry = subprocess.Popen(['/usr/lib/at-spi2-registryd'], env={**os.environ, 'DBUS_SESSION_BUS_ADDRESS': address}, stdout=subprocess.DEVNULL)
    helper = None
    try:
        time.sleep(0.3)
        import gi
        gi.require_version('Gtk', '3.0')
        from gi.repository import Gtk, Gdk, GLib
        window = Gtk.Window(title='Synthetic accessibility fixture')
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        window.add(box)
        bar = Gtk.MenuBar()
        file = Gtk.MenuItem(label='Fixture')
        submenu = Gtk.Menu()
        action = Gtk.MenuItem(label='Run synthetic action')
        activated = []
        action.connect('activate', lambda _: activated.append(True))
        accelerators = Gtk.AccelGroup()
        window.add_accel_group(accelerators)
        action.add_accelerator('activate', accelerators, Gdk.KEY_r, Gdk.ModifierType.CONTROL_MASK, Gtk.AccelFlags.VISIBLE)
        submenu.append(action)
        file.set_submenu(submenu)
        bar.append(file)
        box.pack_start(bar, False, False, 0)
        entry = Gtk.Entry()
        entry.set_text('synthetic public text')
        password = Gtk.Entry()
        password.set_visibility(False)
        password.set_text('synthetic secret never sent')
        box.pack_start(entry, False, False, 0)
        box.pack_start(password, False, False, 0)
        window.show_all()
        window.get_window().focus(Gdk.CURRENT_TIME)
        entry.grab_focus()
        def pump():
            while GLib.MainContext.default().pending():
                GLib.MainContext.default().iteration(False)
        end = time.monotonic() + 1
        while time.monotonic() < end:
            pump()
            time.sleep(0.01)
        assert entry.has_focus(), 'synthetic entry did not receive keyboard focus'
        helper = subprocess.Popen([host, '--internal-accessibility'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        target = {'pid': os.getpid(), 'window': 1, 'x': 0, 'y': 0}
        def send(value):
            data = json.dumps(value).encode()
            helper.stdin.write(struct.pack('<BI', 60, len(data)) + data)
            helper.stdin.flush()
        pending = bytearray()
        def wait_for(predicate):
            end = time.monotonic() + 6
            last = None
            while time.monotonic() < end:
                pump()
                if select.select([helper.stdout], [], [], 0.001)[0]:
                    data = os.read(helper.stdout.fileno(), 65536)
                    assert data, 'accessibility helper exited'
                    pending.extend(data)
                while len(pending) >= 5:
                    kind, n = struct.unpack('<BI', pending[:5])
                    assert kind == 60 and n <= 1024 * 1024
                    if len(pending) < n + 5:
                        break
                    raw = bytes(pending[5:n + 5])
                    del pending[:n + 5]
                    assert b'synthetic secret never sent' not in raw
                    last = json.loads(raw)
                    if predicate(last):
                        return last
            raise AssertionError(f'AT-SPI result missing; last={last}')
        send({'cmd': 'target', 'target': target})
        state = wait_for(lambda v: bool(v['rects']) and bool(v['menus']) and not v['secure'])
        def find(items, path=()):
            for i, item in enumerate(items):
                if item['title'] == 'Run synthetic action':
                    assert item['key'].lower() == 'r' and item['modifiers'] == 2, item
                    return [*path, i]
                found = find(item['children'], (*path, i))
                if found is not None:
                    return found
        path = find(state['menus'])
        assert path is not None, state
        send({'cmd': 'menu', 'target': target, 'path': path})
        end = time.monotonic() + 3
        while time.monotonic() < end and not activated:
            pump()
            time.sleep(0.01)
        assert activated, 'menu action did not reach fixture'
        window.get_window().focus(Gdk.CURRENT_TIME)
        password.grab_focus()
        wait_for(lambda v: v['secure'])
        entry.grab_focus()
        wait_for(lambda v: not v['secure'] and bool(v['rects']))
        send({'cmd': 'target', 'target': None})
        wait_for(lambda v: v['target'] is None and not v['secure'] and not v['rects'] and not v['menus'])
        helper.stdin.close()
        helper.wait(timeout=3)
        assert helper.returncode == 0
        print('PASS AT-SPI: focus bounds, caret, menus/actions, password role and target clearing')
        window.destroy()
    finally:
        for process in [helper, registry, bus]:
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xvfb', required=True)
    parser.add_argument('--host', default='rust/target/debug/rapp-host')
    parser.add_argument('--internal', action='store_true')
    args = parser.parse_args()
    if args.internal:
        exercise(str(Path(args.host).resolve()))
        return
    with tempfile.TemporaryDirectory(prefix='rapp-atspi-test-') as directory:
        root = Path(directory)
        runtime = root / 'runtime'
        runtime.mkdir(mode=0o700)
        bus = root / 'bus.conf'
        bus.write_text('<busconfig><type>session</type><listen>unix:tmpdir=' + directory + '</listen><auth>EXTERNAL</auth><policy context="default"><allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/></policy></busconfig>')
        env = dict(os.environ)
        for key in ['WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'AT_SPI_BUS_ADDRESS']:
            env.pop(key, None)
        env.update(RAPP_TEST_BUS_CONFIG=str(bus), XDG_RUNTIME_DIR=str(runtime), GTK_A11Y='atspi', NO_AT_BRIDGE='0', GIO_USE_VFS='local')
        for key in ['XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME']:
            path = root / key
            path.mkdir()
            env[key] = str(path)
        process = subprocess.Popen([args.xvfb, '-displayfd', '1', '-screen', '0', '800x600x24', '-nolisten', 'tcp'], stdout=subprocess.PIPE)
        try:
            assert select.select([process.stdout], [], [], 5)[0], 'Xvfb startup timed out'
            env['DISPLAY'] = ':' + process.stdout.readline().decode().strip()
            subprocess.run(['dbus-run-session', '--config-file', str(bus), '--', sys.executable, __file__, '--internal', '--xvfb', args.xvfb, '--host', args.host], env=env, check=True, timeout=30)
        finally:
            process.terminate()
            process.wait(timeout=5)

if __name__ == '__main__':
    main()
