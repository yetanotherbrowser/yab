#!/usr/bin/env python3
"""Run the Foundation service tests with macOS Command Line Tools.

Usage: python3 scripts/check-background-downloads/run.py [repository]
This does not test the iOS background daemon, UIKit, or WebKit integration.
"""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
helpers = Path(__file__).resolve().parent
root = Path.home() / "tmp"
root.mkdir(mode=0o700, exist_ok=True)
root.chmod(0o700)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
with tempfile.TemporaryDirectory(prefix="pi-yab-background-", dir=root) as name:
    work = Path(name)
    env = dict(os.environ, TMPDIR=name, TMP=name, TEMP=name)
    for source in ["BackgroundTransfer.swift", "BackgroundDownloads.swift"]:
        shutil.copyfile(repo / "Phone/Sources/Page" / source, work / source)
    tests = (repo / "Phone/Tests/BackgroundDownloadsTests.swift").read_text()
    tests = tests.replace("import XCTest\n", "").replace("@testable import YabPhone\n", "")
    (work / "BackgroundDownloadsTests.swift").write_text(tests)
    for source in ["XCTestShim.swift", "main.swift"]:
        shutil.copyfile(helpers / source, work / source)
    subprocess.run([
        "swiftc", "-swift-version", "5", "-Xfrontend", "-disable-availability-checking",
        "BackgroundTransfer.swift", "BackgroundDownloads.swift", "BackgroundDownloadsTests.swift",
        "XCTestShim.swift", "main.swift", "-o", "harness",
    ], cwd=work, env=env, check=True)
    subprocess.run([str(work / "harness")], cwd=work, env=env, check=True)
