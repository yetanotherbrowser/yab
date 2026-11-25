#!/usr/bin/env python3
"""Farm-only packaging acceptance, with the final signed app left unchanged."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'evals'))
sys.path.insert(0, str(ROOT / 'evals/perf'))
from sweep import Bench


def run(args, *, env=None, capture=False, check=True, timeout=None):
    return subprocess.run(args, env=env, check=check, text=True, timeout=timeout,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.STDOUT if capture else None)


def package(out, result):
    os.chdir(ROOT)
    env = {**os.environ, 'YAB_CEF': '0'}
    app = ROOT / 'build/yab Dev.app'

    def build(label, values):
        started = time.monotonic()
        run(['bash', 'build.sh'], env=values)
        result[label] = round(time.monotonic() - started, 3)

    # First build warms the shared app cache. The two following builds use
    # identical Swift inputs, measuring the added packaging work rather than compilation.
    build('initial_dev_build_seconds', env)
    assert not (app / 'Contents/Frameworks/Chromium Embedded Framework.framework').exists()
    build('warm_plain_build_seconds', env)
    def size(path):
        logical = sum(p.stat().st_size for p in path.rglob('*') if p.is_file() and not p.is_symlink())
        disk = int(run(['du', '-sk', str(path)], capture=True).stdout.split()[0]) * 1024
        return {'logical_bytes': logical, 'allocated_bytes': disk}
    result['before'] = size(app)
    started = time.monotonic()
    cef = run(['bash', 'scripts/cef/fetch.sh'], capture=True)
    print(cef.stdout, flush=True)
    folder = cef.stdout.strip().splitlines()[-1]
    result['fetch_verify_extract_seconds'] = round(time.monotonic() - started, 3)
    result['distribution'] = folder
    result['sha1'] = (Path(folder) / '.verified').read_text().strip()
    build('warm_cef_build_seconds', {**env, 'YAB_CEF': '1', 'YAB_CEF_DIR': folder})
    result['warm_added_seconds'] = round(result['warm_cef_build_seconds'] - result['warm_plain_build_seconds'], 3)
    result['after'] = size(app)
    assert (app / 'Contents/Resources/CEF-LICENSE.txt').read_bytes() == (Path(folder) / 'LICENSE.txt').read_bytes()
    run(['codesign', '--verify', '--deep', '--strict', str(app)])
    app_info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert app_info['CFBundleName'] == app_info['CFBundleDisplayName'] == result['task']
    result['helpers'] = []
    for helper in sorted((app / 'Contents/Frameworks').glob('YabCore Helper*.app')):
        info = plistlib.loads((helper / 'Contents/Info.plist').read_bytes())
        assert info['CFBundleIdentifier'].startswith(app_info['CFBundleIdentifier'] + '.helper')
        assert info['LSUIElement'] is True
        assert info['LSBackgroundOnly'] is True
        if helper.stem.endswith('(Alerts)'):
            assert info['NSUserNotificationAlertStyle'] == 'alert'
        sign = run(['codesign', '-dvv', '--entitlements', ':-', str(helper)], capture=True).stdout
        assert 'runtime' in sign
        wants_jit = helper.stem.endswith(('(GPU)', '(Renderer)'))
        assert ('com.apple.security.cs.allow-jit' in sign) == wants_jit
        # Only an ad hoc helper may load the ad hoc framework without a Team ID.
        assert ('disable-library-validation' in sign) == ('Signature=adhoc' in sign)
        log = run([str(helper / 'Contents/MacOS' / info['CFBundleExecutable'])], capture=True).stdout
        assert 'started inside bundle; CEF 156 loaded' in log
        print(log, end='', flush=True)
        result['helpers'].append({'name': helper.stem, 'id': info['CFBundleIdentifier'], 'signature': sign, 'log': log})
    assert len(result['helpers']) == 5
    for label, args in [('signature', ['codesign', '-dvv', str(app)]),
                        ('gatekeeper', ['spctl', '--assess', '--type', 'execute', '--verbose=4', str(app)]),
                        ('notarization', ['codesign', '--verify', '--deep', '--strict', '--check-notarization', str(app)])]:
        assessed = run(args, capture=True, check=False)
        result[label] = {'exit': assessed.returncode, 'output': assessed.stdout}
        print(label, assessed.returncode, assessed.stdout, flush=True)
    assert result['signature']['exit'] == 0
    assert 'runtime' in result['signature']['output']

    return app


def launch(app, out, result):
    app_info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    # Launch this exact Developer ID signed app through LaunchServices.
    # Do not use probe_app.launch: it changes bundle ids and signs ad hoc.
    world = 'cefpack-' + uuid.uuid4().hex[:10]
    bundle = out / (result['task'] + '.app')
    if app.resolve() != bundle.resolve():
        run(['ditto', str(app), str(bundle)])
    run(['codesign', '--verify', '--deep', '--strict', str(bundle)])
    binary = str(bundle / 'Contents/MacOS' / app_info['CFBundleExecutable'])
    browser_log = str(out / 'browser.log')
    run(['defaults', 'write', 'dev.serafim.fast.test.' + world, 'bench', '-bool', 'true'])
    run(['defaults', 'write', 'dev.serafim.fast.test.' + world, 'welcomed', '-bool', 'true'])
    pid = None
    bench = Bench(Path.home() / ('Library/Application Support/Yab (' + world + ')/bench.sock'))
    try:
        run(['open', '-g', '-n', '-a', str(bundle), '--stdout', browser_log, '--stderr', browser_log,
             '--env', 'YAB_PROBE=' + world, '--env', 'YAB_MEASURE=1'], timeout=30)
        until = time.monotonic() + 90
        while time.monotonic() < until:
            rows = run(['ps', '-axo', 'pid=,comm='], capture=True).stdout.splitlines()
            for row in rows:
                fields = row.strip().split(None, 1)
                if len(fields) == 2 and fields[1] == binary:
                    pid = int(fields[0])
            if pid:
                try:
                    tabs = bench.ask(timeout=3, do='tabs')
                    if 'error' not in tabs:
                        result['launch'] = {'pid': pid, 'world': world, 'tabs': tabs, 'startup': bench.ask(do='startup')}
                        break
                except (OSError, ValueError):
                    pass
            time.sleep(0.5)
        else:
            raise RuntimeError('signed YAB_CEF app did not answer its isolated bench')
        run(['codesign', '--verify', '--deep', '--strict', str(bundle)])
    finally:
        if pid:
            try:
                os.kill(pid, signal.SIGTERM)
                for _ in range(50):
                    alive = run(['ps', '-p', str(pid), '-o', 'comm='], capture=True, check=False).stdout.strip()
                    if alive != binary:
                        break
                    time.sleep(0.1)
                else:
                    os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        (out / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--package-only', action='store_true')
    mode.add_argument('--launch-app', type=Path)
    args = parser.parse_args()
    if os.environ.get('YAB_FARM_WORKER') != '1':
        sys.exit('Run through ./farm exec; add --display for launch')
    out = Path(os.environ['YAB_FARM_OUT']).resolve()
    result = {'host': os.environ.get('WHERE'), 'task': os.environ['YAB_TASK_NAME']}
    try:
        if args.launch_app:
            app = args.launch_app.resolve()
            result['packaged_app'] = str(app)
            result['packaging'] = json.loads((app.parent / 'summary.json').read_text())
        else:
            app = package(out, result)
        if args.package_only:
            bundle = out / (result['task'] + '.app')
            run(['ditto', str(app), str(bundle)])
            run(['codesign', '--verify', '--deep', '--strict', str(bundle)])
            result['artifact'] = str(bundle)
        else:
            launch(app, out, result)
    finally:
        (out / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ('helpers', 'launch')}, indent=2), flush=True)


if __name__ == '__main__':
    main()
