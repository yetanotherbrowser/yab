#!/usr/bin/env python3
"""Print a `swift test --filter` pattern for the suites that cover changed files.

A changed test file brings its own suites. A changed source file `Foo.swift`
(or `Foo+Bar.swift`) brings the suite named `FooTests` when one exists.
Prints nothing when no suite matches, and `.*` (every test) when the package itself
changed.

  swift test --filter "$(scripts/runs/tests_for.py)"
  scripts/runs/tests_for.py --since BASE_SHA
"""
import argparse
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SUITE = re.compile(r'^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:final|public|private|fileprivate|internal)\s+)*(?:struct|class)\s+(\w+Tests)\b', re.M)
PACKAGE = {'Package.swift', 'Package.resolved'}


def git(*args):
    return subprocess.run(['git', *args], cwd=ROOT, check=True, text=True, capture_output=True).stdout


def base():
    for ref in ('origin/main', 'main'):
        try:
            return git('merge-base', 'HEAD', ref).strip()
        except subprocess.CalledProcessError:
            continue
    sys.exit('tests_for: no main branch to compare with; pass --since')


def changed(since):
    # Against the working tree, so uncommitted and untracked work counts too.
    files = git('diff', '--name-only', since).splitlines()
    files += git('ls-files', '--others', '--exclude-standard').splitlines()
    return sorted(set(files))


def suites_in(path):
    try:
        return SUITE.findall(path.read_text(errors='replace'))
    except OSError:
        return []


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--since', help='revision to compare with (default: where HEAD left main)')
    files = changed(parser.parse_args().since or base())
    if PACKAGE.intersection(files):
        print('.*')
        return
    tests = sorted(ROOT.glob('Tests/**/*.swift'))
    known = {name for path in tests for name in suites_in(path)}
    picked = set()
    for name in files:
        path = Path(name)
        if path.suffix != '.swift':
            continue
        if path.parts[0] == 'Tests':
            picked.update(suites_in(ROOT / path))
        elif path.parts[0] == 'Sources':
            suite = path.stem.split('+')[0] + 'Tests'
            if suite in known:
                picked.add(suite)
    if picked:
        print('|'.join(sorted(picked)))


if __name__ == '__main__':
    main()
