#!/usr/bin/env python3
"""Exercise the web installer against local release assets, without GitHub access.
Usage: python3 scripts/release-smoke.py /path/to/dist
"""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
assets = Path(sys.argv[1]).resolve()
version = 'v0.1.0-beta.2'
platform = 'macos-arm64' if sys.platform == 'darwin' else 'linux-x86_64'
archive = assets / f'lowlight-{version}-{platform}.tar.gz'
assert archive.is_file()
with tempfile.TemporaryDirectory(prefix='lowlight release test ') as directory:
    test = Path(directory)
    home = test/'home with spaces'
    home.mkdir()
    (home/'.zshrc').write_text('# existing shell configuration\n')
    old_bin = home/'.midnight/bin'
    old_bin.mkdir(parents=True)
    runner = old_bin/'midnight'
    runner.write_text('# unrelated runner\n')
    data = home/'.lowlight/sessions/chat/keep.txt'
    data.parent.mkdir(parents=True)
    data.write_text('preserved session data')
    fixtures = test/'assets'
    fixtures.mkdir()
    shutil.copy2(archive, fixtures/archive.name)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (fixtures/'SHA256SUMS').write_text(f'{digest}  {archive.name}\n')
    fake_bin = test/'commands'
    fake_bin.mkdir()
    fake = fake_bin/'gh'
    fake.write_text('''#!/usr/bin/env python3
import os, pathlib, shutil, sys
if sys.argv[1:3] == ['auth','status']: sys.exit(0)
assert sys.argv[1:3] == ['release','download']
target = pathlib.Path(sys.argv[sys.argv.index('--dir')+1])
for path in pathlib.Path(os.environ['LOWLIGHT_TEST_ASSETS']).iterdir():
    shutil.copy2(path, target/path.name)
''')
    fake.chmod(0o755)
    env = dict(os.environ, HOME=str(home), SHELL='/bin/zsh', PATH=str(fake_bin)+':'+os.environ['PATH'], LOWLIGHT_TEST_ASSETS=str(fixtures))
    command = ['bash', str(root/'scripts/install-release.sh')]
    for _ in range(2):
        result = subprocess.run(command, env=env, check=True, capture_output=True, text=True)
        if not (home/'.lowlight/bin/lowlight').exists():
            raise AssertionError(result.stdout + result.stderr)
    launcher = home/'.lowlight/bin/lowlight'
    output = subprocess.check_output([str(launcher),'--version'], env=env, text=True).strip()
    assert output == version[1:]
    assert (home/'.zshrc').read_text().count('export PATH="$HOME/.lowlight/bin:$PATH"') == 1
    assert '# existing shell configuration' in (home/'.zshrc').read_text()
    assert data.read_text() == 'preserved session data'
    assert runner.read_text() == '# unrelated runner\n'
    installed = (home/'.lowlight/lib/lowlight').resolve()
    with (fixtures/archive.name).open('ab') as f:
        f.write(b'corruption')
    failure = subprocess.run(command, env=env, capture_output=True, text=True)
    assert failure.returncode != 0 and 'checksum mismatch' in failure.stderr
    assert (home/'.lowlight/lib/lowlight').resolve() == installed
    assert data.read_text() == 'preserved session data'
    print('PASS release install, upgrade, resources/runtime, PATH deduplication, data preservation, checksum failure')
