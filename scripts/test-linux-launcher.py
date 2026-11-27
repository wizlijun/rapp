#!/usr/bin/env python3
"""The packaged entry point preserves arguments and chooses GUI vs CLI, even via symlinks."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile

launcher = Path(__file__).resolve().parent / 'linux' / 'rapp'
with tempfile.TemporaryDirectory(prefix='rapp launcher ') as root:
    root = Path(root)
    bundle = root / "bundle ' with spaces"
    bundle.mkdir()
    shutil.copy2(launcher, bundle / 'rapp')
    for name in ('rapp-cli', 'rapp-gui'):
        target = bundle / name
        target.write_text('#!/usr/bin/env python3\nimport json, sys\nprint(json.dumps([sys.argv[0], *sys.argv[1:]]))\n')
        target.chmod(0o755)
    entry = root / 'rapp'
    entry.symlink_to(bundle / 'rapp')
    for args, binary in [([], 'rapp-gui'), (['--cm'], 'rapp-gui'), (['--help'], 'rapp-cli'), (['--version'], 'rapp-cli'),
                         (['share', '8000', '--note', "a ' $HOME ; $(false)"], 'rapp-cli'),
                         (['unshare', '8000'], 'rapp-cli'), (['hosts'], 'rapp-cli'),
                         (['pipe', 'device', '22'], 'rapp-cli'),
                         (['term', 'restore'], 'rapp-cli'),
                         (['term', 'restore', '--list'], 'rapp-cli'),
                         (['term', 'restore', '--forget'], 'rapp-cli'),
                         (['term', 'restore', '1', 'rapp'], 'rapp-cli'),
                         (['update'], 'rapp-cli'),
                         (['update', 'status', '--json'], 'rapp-cli'),
                         (['update', 'check', '--timeout', '5', '--json'], 'rapp-cli'),
                         (['update', 'rollback', '--json'], 'rapp-cli'),
                         (['center'], 'rapp-cli'),
                         (['center', 'on'], 'rapp-cli'),
                         (['center', 'off'], 'rapp-cli'),
                         (['state'], 'rapp-cli'),
                         (['state', 'on'], 'rapp-cli'),
                         (['state', 'off'], 'rapp-cli'),
                         (['load'], 'rapp-cli'),
                         (['load', '--top', '--json'], 'rapp-cli'),
                         (['load', 'pick', '--json'], 'rapp-cli')]:
        out = json.loads(subprocess.check_output([entry, *args], text=True))
        assert out == [str(bundle / binary), *args], out
print('PASS packaged GUI/CLI dispatch and literal argument preservation')
