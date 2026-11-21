#!/usr/bin/env python3
"""Filesystem contracts used by CEF loading and native-messaging caller validation."""
import importlib.util
from pathlib import Path
import platform
import plistlib
import tempfile
import os
import subprocess
import unittest

spec = importlib.util.spec_from_file_location('package_core', Path(__file__).with_name('package_core.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CoreBundleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.app = Path(self.tmp.name) / 'Yab.app'
        self.contents = self.app / 'Contents'
        (self.contents / 'MacOS').mkdir(parents=True)
        self.legacy = self.contents / 'MacOS/YabCore'
        self.legacy.write_bytes(b'first executable')
        self.parent = dict(CFBundleIdentifier='dev.serafim.fast', CFBundleVersion='202611091715',
                           CFBundleShortVersionString='0.47.6', LSMinimumSystemVersion='15.4',
                           NSAppleScriptEnabled=True, OSAScriptingDefinition='Yab.sdef',
                           NSSupportsAutomaticTermination=True, NSSupportsSuddenTermination=True)
        (self.contents / 'Info.plist').write_bytes(plistlib.dumps(self.parent))
        self.framework = self.contents / 'Frameworks/Chromium Embedded Framework.framework'
        self.framework.mkdir(parents=True)
        (self.framework / 'payload').write_bytes(b'untouched framework')
        self.renderer = self.contents / 'Frameworks/YabCore Helper (Renderer).app'
        for name in module.PAYLOADS[1:]:
            (self.contents / 'Frameworks' / name).mkdir()

    def test_own_identity_before_appkit_registration(self):
        bundle = module.package(self.app)
        info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleIdentifier'], 'dev.serafim.fast.core')
        self.assertTrue(info['LSUIElement'])
        self.assertEqual(info['CFBundleExecutable'], 'YabCore')
        self.assertNotIn('NSAppleScriptEnabled', info)
        self.assertNotIn('OSAScriptingDefinition', info)
        self.assertEqual(plistlib.loads((self.contents / 'Info.plist').read_bytes()), self.parent)

    def test_engine_is_not_a_disposable_background_application(self):
        # Yab owns this process even when Chromium has no visible native window.
        bundle = module.package(self.app)
        info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        self.assertIs(info.get('NSSupportsAutomaticTermination'), False)
        self.assertIs(info.get('NSSupportsSuddenTermination'), False)
        self.assertEqual(plistlib.loads((self.contents / 'Info.plist').read_bytes()), self.parent)

    def test_standalone_engine_has_the_same_termination_policy(self):
        template = Path(__file__).resolve().parents[2] / 'YabCore/src/Info.plist.in'
        info = plistlib.loads(template.read_bytes())
        self.assertIs(info.get('NSSupportsAutomaticTermination'), False)
        self.assertIs(info.get('NSSupportsSuddenTermination'), False)

    def test_cef_and_native_host_paths_survive_app_relocation(self):
        module.package(self.app)
        moved = self.app.with_name('Yab.app.old')
        self.app.rename(moved)
        legacy = moved / 'Contents/MacOS/YabCore'
        binary = moved / 'Contents/Frameworks/YabCore.app/Contents/MacOS/YabCore'
        self.assertEqual(legacy.resolve(strict=True), binary.resolve(strict=True))
        self.assertEqual(binary.read_bytes(), b'first executable')
        framework = binary.parent.parent / 'Frameworks/Chromium Embedded Framework.framework/payload'
        self.assertEqual(framework.read_bytes(), b'untouched framework')
        self.assertFalse(framework.parent.is_symlink())
        self.assertFalse(framework.parent.parent.is_symlink())
        self.assertTrue((binary.parent.parent / 'Frameworks/YabCore Helper (Renderer).app').is_dir())

    def test_reembedding_replaces_only_owned_bundle(self):
        module.package(self.app)
        self.legacy.unlink()
        self.legacy.write_bytes(b'new executable')
        for name in module.PAYLOADS:
            source = self.contents / 'Frameworks' / name
            source.unlink()
            source.mkdir()
            if name == module.PAYLOADS[0]:
                (source / 'payload').write_bytes(b'untouched framework')
        module.package(self.app)
        self.assertEqual(self.legacy.read_bytes(), b'new executable')
        self.assertEqual((self.framework / 'payload').read_bytes(), b'untouched framework')
        self.assertTrue(self.renderer.is_dir())

    def test_obsolete_flat_receipt_refuses_before_changing_app(self):
        self.legacy.chmod(0o700)
        before = self.legacy.read_bytes()
        embed = Path(__file__).with_name('embed.sh')
        result = subprocess.run(['bash', str(embed), str(self.app), '/missing-sdk',
                                 str(self.legacy), '-'], capture_output=True, text=True,
                                env=dict(os.environ, YABCORE_PREPARED_HELPER_INPUT='/old/receipt.json'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('receipts must be regenerated', result.stderr)
        self.assertEqual(self.legacy.read_bytes(), before)
        self.assertFalse((self.contents / 'Frameworks/YabCore.app').exists())

    def test_refuses_to_move_an_existing_alias(self):
        module.package(self.app)
        with self.assertRaises(RuntimeError):
            module.package(self.app)
        self.assertEqual(self.legacy.read_bytes(), b'first executable')


@unittest.skipUnless(platform.machine() == 'arm64', 'the CEF payload is arm64-only')
class AdHocEmbedTests(unittest.TestCase):
    """A contributor without a certificate: build.sh hands embed.sh `-`."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.cef = root / 'cef'
        framework = self.cef / 'Release/Chromium Embedded Framework.framework'
        (framework / 'Resources').mkdir(parents=True)
        (framework / 'Resources/Info.plist').write_bytes(plistlib.dumps(dict(
            CFBundleExecutable='Chromium Embedded Framework', CFBundleIdentifier='org.cef.framework',
            CFBundlePackageType='FMWK', CFBundleInfoDictionaryVersion='6.0')))
        (self.cef / 'include').mkdir()
        (self.cef / 'include/cef_version.h').write_text('#define CEF_VERSION_MAJOR 156\n')
        (self.cef / 'LICENSE.txt').write_text('license\n')
        self.compile(root, 'int cef_version_info(int entry) { return entry == 0 ? 156 : 0; }\n',
                     framework / 'Chromium Embedded Framework', '-dynamiclib')
        self.app = root / 'Yab.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
            CFBundleIdentifier='dev.serafim.fast.dev', CFBundleExecutable='yab', CFBundlePackageType='APPL',
            CFBundleVersion='202611151200', CFBundleShortVersionString='0.47.19', LSMinimumSystemVersion='15.4')))
        self.compile(root, 'int main(void) { return 0; }\n', self.app / 'Contents/MacOS/yab')
        self.stub = root / 'stub'
        subprocess.run(['xcrun', 'clang', '-arch', 'arm64', str(Path(__file__).with_name('helper-stub.c')),
                        '-o', str(self.stub)], check=True)

    @staticmethod
    def compile(root, source, output, *flags):
        path = root / (output.name + '.c')
        path.write_text(source)
        subprocess.run(['xcrun', 'clang', '-arch', 'arm64', *flags, str(path), '-o', str(output)], check=True)

    def test_every_helper_loads_the_framework(self):
        embed = Path(__file__).with_name('embed.sh')
        subprocess.run(['bash', str(embed), str(self.app), str(self.cef), str(self.stub), '-'],
                       check=True, capture_output=True)
        helpers = sorted((self.app / 'Contents/Frameworks').glob('YabCore Helper*.app'))
        self.assertEqual(len(helpers), 5)
        for helper in helpers:
            run = subprocess.run([str(helper / 'Contents/MacOS' / helper.stem)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, f'{helper.stem}: {run.stderr}')
            self.assertIn('CEF 156 loaded', run.stdout)


if __name__ == '__main__':
    unittest.main()
