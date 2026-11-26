#!/usr/bin/env python3
"""Prepare an isolated iOS project to test the share action on any git ref.

Usage: python3 Phone/SyncCheck/share-extension-regression.py REF OUTPUT
Use REF=working for the current working tree. Then run the printed xcodebuild
command, or open the generated project and run ShareExtensionRegressionTests.
Only test access and dependency injection are adapted in the controller.
The action body is otherwise the source from REF.
"""
import pathlib
import shutil
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[2]
ref, destination = sys.argv[1:]
out = pathlib.Path(destination).resolve()
out.mkdir(parents=True, exist_ok=False)
if ref == "working":
    files = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
    for name in filter(None, files):
        target = out / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / name, target)
else:
    archive = subprocess.Popen(["git", "archive", ref], cwd=root, stdout=subprocess.PIPE)
    subprocess.run(["tar", "-xf", "-", "-C", str(out)], stdin=archive.stdout, check=True)
    archive.stdout.close()
    assert archive.wait() == 0

tests = out / "Phone/Tests"
shutil.rmtree(tests)
tests.mkdir()
for name in ["ShareExtensionRegressionTests.swift", "SyncMemoryServer.swift"]:
    shutil.copy2(root / "Phone/Tests" / name, tests / name)

controller = (out / "Phone/Share/ShareViewController.swift").read_text()
replacements = {
    "private let model = Model()": "let model = Model()",
    "private let queue = SharedLinkQueue.shared": "private var queue: SharedLinkQueue { ShareExtensionFixture.queue }",
    "private func choose(": "func choose(",
}
for old, new in replacements.items():
    assert controller.count(old) == 1, old
    controller = controller.replace(old, new)
has_sync = (out / "Phone/Sources/Entrances/Shared/SharedLinkSync.swift").exists()
has_access = "private let syncAccess = SharedLinkSyncAccess.standard" in controller
if has_access:
    controller = controller.replace("private let syncAccess = SharedLinkSyncAccess.standard",
                                    "private var syncAccess: SharedLinkSyncAccess { ShareExtensionFixture.syncAccess! }")
    upload = "SharedLinkUpload(record: payload.record, access: syncAccess, session: session)"
    assert controller.count(upload) == 1
    controller = controller.replace(upload, upload[:-1] + ", transport: ShareExtensionFixture.transport)")
elif has_sync:
    assert controller.count("SyncKeychain.standard()") == 1
    assert controller.count("SharedLinkUpload(record: payload.record, seal: seal)") == 1
controller = controller.replace("SyncKeychain.standard()", "ShareExtensionFixture.keys")
controller = controller.replace("SharedLinkUpload(record: payload.record, seal: seal)",
                                "SharedLinkUpload(record: payload.record, seal: seal, transport: ShareExtensionFixture.transport)")
(tests / "ShareViewController.swift").write_text("@testable import YabPhone\n" + controller)

project = out / "Phone/project.yml"
text = project.read_text()
defines = "$(inherited) SHARE_EXTENSION_REGRESSION"
if has_sync:
    defines += " SHARE_SYNC_CONTEXT"
if has_access:
    defines += " SHARE_SYNC_ACCESS"
marker = "        PRODUCT_BUNDLE_IDENTIFIER: dev.serafim.fast.iphone.tests"
assert text.count(marker) == 1
text = text.replace(marker, marker + '\n        SWIFT_ACTIVE_COMPILATION_CONDITIONS: "' + defines + '"')
project.write_text(text)
subprocess.run(["xcodegen", "generate", "--spec", str(project)], check=True)
print(f"Prepared {ref}: {out / 'Phone/YabPhone.xcodeproj'}")
print(f"xcodebuild test -project {out / 'Phone/YabPhone.xcodeproj'} -scheme YabPhone "
      "-destination 'platform=iOS Simulator,name=iPhone 18 Pro' "
      "-only-testing:YabPhoneTests/ShareExtensionRegressionTests")
