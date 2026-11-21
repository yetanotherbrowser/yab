#!/usr/bin/env python3
"""Farm-only YabCore bridge diagnostic. It is not WebKit/app acceptance."""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'chromium-extensions'))
from prepared_lifetime import PreparedHelperLifetime


def main(app, out):
    out.mkdir(parents=True, exist_ok=True)
    report = {'checks': {}, 'scope': 'Native helper only. No WebKit page or app acceptance.'}
    sequence = 0
    with tempfile.TemporaryDirectory(prefix='drm-core-', dir='/tmp') as temporary:
        root = Path(temporary)
        endpoint = root / 'core.sock'
        with (out / 'helper.log').open('w') as log:
            process = subprocess.Popen([str(app / 'Contents/MacOS/YabCore'), '--socket=' + str(endpoint),
                                        '--data-root=' + str(root / 'data'), '--use-mock-keychain', '--yab-test-bridge'], stdout=log, stderr=log)
            lifetime = PreparedHelperLifetime(app, process, root / 'data', out)
            peer = reader = None
            try:
                until = time.monotonic() + 30
                while not endpoint.exists():
                    if process.poll() is not None or time.monotonic() > until:
                        raise RuntimeError('Native helper did not start')
                    time.sleep(.05)
                peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                peer.settimeout(25)
                peer.connect(str(endpoint))
                reader = peer.makefile('rb')

                def ask(method, **params):
                    nonlocal sequence
                    sequence += 1
                    request_id = str(sequence)
                    peer.sendall((json.dumps({'v': 1, 'id': request_id, 'method': method, 'params': params}) + '\n').encode())
                    while True:
                        row = reader.readline()
                        if not row:
                            raise RuntimeError('YabCore disconnected')
                        result = json.loads(row)
                        if result.get('id') == request_id:
                            if 'error' in result:
                                raise RuntimeError(result['error']['message'])
                            return result.get('result')

                lifetime.shutdown = lambda: ask('shutdown')
                ask('hello')
                ask('profile.open', profile='diagnostic')
                tab = ask('tab.create', profile='diagnostic', url='chrome://extensions/')['tab']
                ask('drm.cookies.get', tab=tab, urls=['https://example.com/'])
                report['checks']['initial_cookie_transport'] = True
                # Do not wait for DevTools here: first navigation must queue its
                # DRM hook safely while the new browser is still attaching.
                ask('tab.navigate', tab=tab, url='chrome://extensions/')
                report['checks']['initial_navigation_hook'] = True
                ask('tab.visible', tab=tab, visible=False)
                def ready(tab, url, label):
                    until = time.monotonic() + 30
                    while True:
                        proof = ask('tab.readiness', tab=tab, profile='diagnostic', url=url)
                        report.setdefault('readiness', {})[label] = proof
                        if (proof.get('ready') and proof.get('proof') == 'mainFrameDocument'
                                and proof.get('url') == url and proof.get('frame') and proof.get('context')):
                            return proof
                        if time.monotonic() > until:
                            raise RuntimeError(label + ' not ready: ' + json.dumps(proof))
                        time.sleep(.1)

                management = ready(tab, 'chrome://extensions/', 'management')
                report['checks']['management_document_proof'] = True
                document = ask('script.document', tab=tab, document=management,
                               expression="typeof chrome.developerPrivate?.getExtensionsInfo === 'function'")
                report['checks']['management_api_ready'] = document is True
                assert report['checks']['management_api_ready'], document
                # CEF's empty URL is an unnavigated bootstrap with no DevTools
                # agent until the first document: its first navigation must not
                # wait for the DRM hook (a deadlock found on the real app).
                bootstrap = ask('tab.create', profile='diagnostic', url='')['tab']
                ask('tab.navigate', tab=bootstrap, url='chrome://version/')
                ready(bootstrap, 'chrome://version/', 'bootstrap')
                report['checks']['bootstrap_first_navigation'] = True
                ask('tab.close', tab=bootstrap)
                extension_path = root / 'extension'
                shutil.copytree(Path(__file__).resolve().parent / 'extension', extension_path)
                ask('extension.load', tab=tab, path=str(extension_path))
                catalog = ask('ext.bridge.catalog', tab=tab)['extensions']
                report['catalog'] = catalog
                assert len(catalog) == 1, catalog
                extension = catalog[0]['id']
                report['checks']['native_catalog_grant'] = 'http://127.0.0.1/*' in catalog[0]['grants']
                ask('ext.bridge.register', tab=tab, virtual='native-diagnostic', document='document-one', frame=0, url='http://127.0.0.1/eme')

                def invoke(op, args):
                    return ask('ext.bridge.invoke', tab=tab, virtual='native-diagnostic', document='document-one',
                               frame=0, extension=extension, op=op, args=args)

                snapshot = invoke('dnr.snapshot', [])
                report['dnr'] = snapshot
                report['checks']['worker_dnr'] = snapshot['enabled'] == ['acceptance']
                report['checks']['storage_default'] = invoke('storage.local.get', [None]) == {}
                report['checks']['worker_listener'] = invoke('runtime.sendMessage', [{'kind': 'storage-access', 'allow': False}]) is True
                notification = {'kind': 'notification', 'nonce': 'synthetic-native-notification'}
                report['checks']['worker_notification_without_reply'] = (
                    invoke('runtime.sendMessage', [notification]) is None
                    and invoke('runtime.sendMessage', [{'kind': 'last-notification'}]) == notification['nonce']
                )
                try:
                    invoke('storage.local.get', [None])
                    report['checks']['storage_trusted_denied'] = False
                except RuntimeError as error:
                    report['checks']['storage_trusted_denied'] = 'unavailable to content scripts' in str(error)
                invoke('runtime.sendMessage', [{'kind': 'storage-access', 'allow': True}])
                invoke('storage.local.set', [{'witness': 'synthetic-native'}])
                report['checks']['storage_allowed'] = invoke('storage.local.get', ['witness']) == {'witness': 'synthetic-native'}
                report['checks']['worker_stopped'] = ask('ext.bridge.testingSleep', tab=tab, extension=extension)['stopped'] is True
                report['checks']['cold_worker_wake'] = invoke('runtime.sendMessage', [{'kind': 'storage-access', 'allow': True}]) is True
                report['ok'] = all(report['checks'].values())
                assert report['ok'], report
            except BaseException as error:
                report['error'] = str(error)
                raise
            finally:
                try:
                    lifetime.finish(report)
                finally:
                    if reader is not None: reader.close()
                    if peer is not None: peer.close()
    if not report.get('ok'):
        raise RuntimeError('Native DRM helper assertions or owned shutdown failed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    main(args.app, args.out)
