#!/bin/bash
# Download only the pinned official macOS arm64 minimal distribution.
set -euo pipefail
exec /usr/bin/python3 -I - "$@" <<'PY'
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

VERSION = '156.0.30+g6028375+chromium-156.0.8078.96'
BASE = 'https://cef-builds.spotifycdn.com/'
root = Path(os.environ.get('YAB_CEF_CACHE', str(Path.home() / '.local/state/yab-spike-cef')))
root.mkdir(parents=True, exist_ok=True)
with (root / '.cefpack.lock').open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    with urllib.request.urlopen(BASE + 'index.json', timeout=60) as response:
        index = json.load(response)
    files = [f for v in index['macosarm64']['versions']
             if v['cef_version'] == VERSION and v['channel'] == 'stable'
             for f in v['files'] if f['type'] == 'minimal']
    if len(files) != 1:
        sys.exit('CEF: pinned minimal distribution missing from official index')
    name, sha = files[0]['name'], files[0]['sha1']
    if Path(name).name != name or not name.endswith('_macosarm64_minimal.tar.bz2'):
        sys.exit('CEF: unexpected archive name')
    archive = root / name
    folder = root / name[:-8]
    def checksum(path):
        value = hashlib.sha1()
        with path.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                value.update(block)
        return value.hexdigest()
    with tempfile.TemporaryDirectory(prefix='cefpack-', dir=root) as tmp:
        if not archive.is_file():
            downloaded = Path(tmp) / name
            print('CEF: downloading ' + name, file=sys.stderr)
            with urllib.request.urlopen(BASE + urllib.parse.quote(name), timeout=120) as response, downloaded.open('wb') as out:
                shutil.copyfileobj(response, out)
            if checksum(downloaded) != sha:
                sys.exit('CEF: published SHA-1 mismatch')
            downloaded.replace(archive)
        if checksum(archive) != sha:
            sys.exit('CEF: cached archive SHA-1 mismatch; remove the archive and retry')
        print('CEF: SHA-1 verified ' + sha, file=sys.stderr)
        stamp = folder / '.verified'
        expected = sha + '  ' + name + '\n'
        if not stamp.is_file() or stamp.read_text() != expected:
            if folder.exists():
                sys.exit('CEF: unverified extraction already exists: ' + str(folder))
            subprocess.run(['tar', '-xjf', str(archive), '-C', tmp], check=True)
            extracted = Path(tmp) / folder.name
            if not (extracted / 'Release/Chromium Embedded Framework.framework').is_dir():
                sys.exit('CEF: framework missing from archive')
            (extracted / '.verified').write_text(expected)
            extracted.replace(folder)
    print(folder)
PY
