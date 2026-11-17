#!/usr/bin/env python3
"""Measure benchmark-only bundles on a private GPU-backed Wayland display.

Build gui/benchmark/linux_compositor.dart in each compared worktree, then pass
their bundle directories here. Never pass the production app: the fixture exits
by itself and does not start services. Requires Weston (installed or extracted),
dbus-run-session and access to the render node. Does not touch the user display.
CPU percentages use one core = 100%; these are compositor costs, not remote FPS.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def ticks(pid, main=False):
    stat = Path(f'/proc/{pid}/task/{pid}/stat' if main else f'/proc/{pid}/stat')
    fields = stat.read_text().rsplit(')', 1)[1].split()
    return int(fields[11]) + int(fields[12])


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def measure(bundle, args, env, config, output, label):
    if b'COMPOSITOR_BENCH fps=' not in (bundle / 'lib/libapp.so').read_bytes():
        raise RuntimeError(f'{bundle}: not a compositor benchmark bundle')
    # The private bus has no service directories: no portal, keyring, or user
    # session services can be activated by the fixture's GTK plugins.
    command = ['dbus-run-session', f'--config-file={config}', '--',
               str(bundle / 'rapp'), str(args.fps)]
    # dbus-run-session is the parent, so get the app PID from /proc children.
    with (output / f'{label}.log').open('w') as log:
        process = subprocess.Popen(command, cwd=bundle, env=env, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 5
            pid = None
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(f'{label}: failed to start; see {log.name}')
                children = Path(f'/proc/{process.pid}/task/{process.pid}/children').read_text().split()
                for child in children:
                    try:
                        if Path(f'/proc/{child}/exe').resolve() == bundle / 'rapp':
                            pid = int(child)
                            break
                    except FileNotFoundError:
                        pass
                if pid is not None:
                    break
                time.sleep(.05)
            if pid is None:
                raise RuntimeError(f'{label}: benchmark PID not found')
            time.sleep(3)
            if args.capture:
                capture = output / label
                capture.mkdir()
                subprocess.run([str(args.weston.parent / 'weston-screenshooter')],
                               env=env, cwd=capture, check=True, timeout=5)
            main, total, start = ticks(pid, True), ticks(pid), time.monotonic()
            time.sleep(10)
            elapsed = time.monotonic() - start
            hz = os.sysconf('SC_CLK_TCK')
            result = dict(label=label, bundle=str(bundle), seconds=round(elapsed, 3),
                          main_cpu_percent=round((ticks(pid, True) - main) / hz / elapsed * 100, 2),
                          total_cpu_percent=round((ticks(pid) - total) / hz / elapsed * 100, 2))
            if process.wait(timeout=10) != 0:
                raise RuntimeError(f'{label}: benchmark failed; see {log.name}')
        finally:
            # Only terminate the child we launched, never a production rapp PID.
            if pid is not None and process.poll() is None:
                try:
                    if Path(f'/proc/{pid}/exe').resolve() == bundle / 'rapp':
                        os.kill(pid, 15)
                except (ProcessLookupError, FileNotFoundError):
                    pass
            stop(process)
    if 'COMPOSITOR_BENCH' not in (output / f'{label}.log').read_text():
        raise RuntimeError('Bundle is not the compositor fixture')
    print(json.dumps(result), flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundles', type=Path, nargs='+')
    parser.add_argument('--weston', type=Path, default=shutil.which('weston'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--fps', type=int, choices=[15, 30, 60], default=30)
    parser.add_argument('--capture', action='store_true')
    args = parser.parse_args()
    if args.weston is None:
        parser.error('Weston required; use --weston for an extracted package')
    args.weston = args.weston.resolve()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    root = args.weston.parent.parent
    with tempfile.TemporaryDirectory(prefix='rapp-compositor-') as temp:
        runtime = Path(temp)
        env = dict(os.environ, XDG_RUNTIME_DIR=temp, WAYLAND_DISPLAY='rapp-bench',
                   GDK_BACKEND='wayland', GTK_IM_MODULE='gtk-im-context-simple',
                   NO_AT_BRIDGE='1', GIO_USE_VFS='local',
                   LD_LIBRARY_PATH=f'{root}/lib:{root}/lib/weston',
                   WESTON_MODULE_MAP=';'.join(f'{p.name}={p}' for directory in
                       [root / 'lib/weston', *sorted((root / 'lib').glob('libweston-*'))]
                       for p in directory.glob('*.so')))
        env.pop('DISPLAY', None)
        env.pop('DBUS_SESSION_BUS_ADDRESS', None)
        env.pop('HYPRLAND_INSTANCE_SIGNATURE', None)
        config = runtime / 'dbus.conf'
        config.write_text('<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen>'
                          '<policy context="default"><allow send_destination="*"/>'
                          '<allow receive_sender="*"/><allow own="*"/></policy></busconfig>')
        command = [str(args.weston), '--backend=headless', '--renderer=gl',
                   '--shell=kiosk-shell.so', '--no-config', '--socket=rapp-bench',
                   '--width=1280', '--height=800', '--scale=3', '--fake-seat',
                   '--idle-time=0', f'--log={args.output / "weston.log"}']
        if args.capture:
            command.append('--debug')
        with (args.output / 'weston-stderr.log').open('w') as log:
            compositor = subprocess.Popen(command, env=env, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 10
                while not (runtime / 'rapp-bench').exists():
                    if compositor.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError('Weston failed; see output logs')
                    time.sleep(.05)
                renderer_log = (args.output / 'weston.log').read_text()
                if 'llvmpipe' in renderer_log or 'softpipe' in renderer_log:
                    raise RuntimeError('Weston uses software rendering; GPU comparison requires a render node')
                results = []
                for run in range(args.runs):
                    for index, bundle in enumerate(args.bundles):
                        label = f'{index}-{bundle.name}-{run + 1}'
                        results.append(measure(bundle.resolve(), args, env, config, args.output, label))
                (args.output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
            finally:
                stop(compositor)


if __name__ == '__main__':
    main()
