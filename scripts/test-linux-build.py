#!/usr/bin/env python3
"""Check worker staging with default/custom Cargo targets; no real build runs."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

source = Path(__file__).resolve().parent / 'build-linux.sh'
workers = ['rapp-client', 'rapp-session', 'rapp-host', 'rapp-hub', 'rapp-service', 'rapp-term', 'rapp-center', 'rapp-cli', 'rapp-speech']
with tempfile.TemporaryDirectory(prefix='rapp-build-paths-') as temporary:
    root = Path(temporary)
    (root / 'scripts').mkdir()
    (root / 'rust/target/release').mkdir(parents=True)
    (root / 'gui').mkdir()
    (root / 'tools').mkdir()
    shutil.copy2(source, root / 'scripts/build-linux.sh')
    (root / 'scripts/linux').mkdir()
    shutil.copy2(source.parent / 'linux/rapp', root / 'scripts/linux/rapp')
    (root / 'rust/Cargo.toml').write_text('[workspace.package]\nversion="0.13.0"\n')
    cargo = root / 'tools/cargo'
    cargo.write_text('''#!/usr/bin/env python3
import json, os
from pathlib import Path
import sys
root = Path.cwd()
target = Path(os.environ.get('CARGO_TARGET_DIR', root / 'rust/target')).resolve()
assert '--locked' in sys.argv
if sys.argv[1] == 'metadata':
    print(json.dumps({'target_directory': str(target)}))
else:
    assert sys.argv[1] == 'build' and '--release' in sys.argv
    (target / 'release').mkdir(parents=True, exist_ok=True)
    for name in ['rapp-client','rapp-session', 'rapp-host','rapp-hub','rapp-service','rapp-term','rapp-center','rapp-cli','rapp-speech']:
        path = target / 'release' / name
        path.write_text('fresh ' + name + '\\n')
        path.chmod(0o755)
''')
    cargo.chmod(0o755)
    flutter = root / 'tools/flutter fixture'
    flutter.write_text('''#!/usr/bin/env python3
import json, os
from pathlib import Path
import sys
if sys.argv[1:] == ['--version','--machine']:
    print(json.dumps({'frameworkVersion': os.environ.get('TEST_FLUTTER_VERSION', '3.50.0')}))
    sys.exit(0)
assert sys.argv[1:] == ['build','linux','--release','--dart-define=RAPP_VERSION=0.13.0']
bundle = Path('build/linux/x64/release/bundle')
bundle.mkdir(parents=True, exist_ok=True)
path = bundle / 'rapp'
path.write_text('fresh gui\\n')
path.chmod(0o755)
''')
    flutter.chmod(0o755)
    env = {**os.environ, 'PATH': str(root / 'tools') + os.pathsep + os.environ['PATH'], 'FLUTTER': str(flutter)}
    env.pop('CARGO_TARGET_DIR', None)
    for target in [None, str(root / 'shared target'), 'relative target']:
        for name in workers:
            (root / 'rust/target/release' / name).write_text('stale worker\n')
        current = dict(env)
        if target is not None:
            current['CARGO_TARGET_DIR'] = target
        subprocess.run(['bash', 'scripts/build-linux.sh'], cwd=root, env=current, check=True, capture_output=True, text=True)
        bundle = root / 'gui/build/linux/x64/release/bundle'
        assert (bundle / 'rapp').read_bytes() == (root / 'scripts/linux/rapp').read_bytes()
        assert (bundle / 'rapp-gui').read_text() == 'fresh gui\n'
        assert (bundle / 'FLUTTER-INFO.json').is_file()
        for name in workers:
            assert (bundle / name).read_text() == 'fresh ' + name + '\n', (target, name)
            assert os.access(bundle / name, os.X_OK)
    for version in ['3.47.9', '3.50.0-0.1.pre', 'unknown']:
        result = subprocess.run(['bash', 'scripts/build-linux.sh'], cwd=root,
                                env={**env, 'TEST_FLUTTER_VERSION': version},
                                capture_output=True, text=True)
        assert result.returncode != 0 and 'require stable Flutter >= 3.50.0' in result.stderr
print('PASS Linux staging uses the default, absolute and relative Cargo target directories; Flutter override preserves spaces')
print('PASS old and prerelease Flutter engines are rejected before building')
