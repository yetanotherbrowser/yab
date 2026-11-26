#!/usr/bin/env python3
"""Extension action popup hosting (patches 0006, 0011, 0137); farm display job only.

Opt-in normal-window path (YAB_CEF_EXTENSION_WINDOWS=1): load the test
extension with a popup action, press its toolbar button, and check that
Chromium names the owner tab, extension and token in popup.layer, that the popup's
own compositor context carries pixels (ScreenCaptureKit through the layer host),
that popup.input reaches that exact popup, that a file the popup saves opens on
its owner tab (download.open), and that closing reports popup.closed.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tests'))
from run import stop, wait_socket

PAGE = b'<!doctype html><title>Popup owner</title><body style="background:#bc3543;margin:0;height:600px">owner'


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--host', type=Path, required=True)
    args = parser.parse_args()
    out = Path(os.environ['YAB_FARM_OUT'])
    out.mkdir(parents=True, exist_ok=True)
    report = {'checks': []}
    events = []
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    process = host = peer = None
    seq = 0
    try:
        with tempfile.TemporaryDirectory(prefix='yp-', dir='/tmp') as temporary, (out / 'helper.log').open('w') as log:
            directory = Path(temporary)
            os.chmod(directory, 0o700)
            endpoint = directory / 'core.sock'
            env = dict(os.environ, YAB_CEF_EXTENSION_WINDOWS='1')
            process = subprocess.Popen([str(args.app / 'Contents/MacOS/YabCore'), f'--socket={endpoint}',
                f'--data-root={directory / "data"}', '--no-sandbox', '--use-mock-keychain',
                '--no-default-browser-check'], stdout=log, stderr=log, start_new_session=True, env=env)
            wait_socket(endpoint, process)
            host = subprocess.Popen([str(args.host), str(out)], stdout=log, stderr=log, start_new_session=True)
            peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            peer.settimeout(30)
            peer.connect(str(endpoint))
            reader = peer.makefile('rb')

            def request(method, params=None, allow_error=False):
                nonlocal seq
                seq += 1
                ident = str(seq)
                peer.sendall((json.dumps({'v': 1, 'id': ident, 'method': method, 'params': params or {}}) + '\n').encode())
                while True:
                    line = reader.readline()
                    if not line:
                        raise RuntimeError('Helper disconnected')
                    message = json.loads(line)
                    if 'event' in message:
                        events.append(message)
                        continue
                    if 'error' in message:
                        if allow_error:
                            return {'error': message['error']}
                        raise RuntimeError(method + ': ' + json.dumps(message['error']))
                    return message['result']

            def eventually(label, action, timeout=30, pump=None):
                end = time.monotonic() + timeout
                while True:
                    if pump:
                        request('tab.state', {'tab': pump}, allow_error=True)
                    value = action()
                    if value:
                        return value
                    if time.monotonic() > end:
                        raise RuntimeError('Timed out: ' + label)
                    time.sleep(.1)

            def check(name, value, detail=None):
                report['checks'].append({'check': name, 'passed': bool(value), 'detail': detail})
                assert value, (name, detail)

            request('hello')
            request('profile.open', {'profile': 'popup'})
            manage = request('extension.open', {'profile': 'popup'})['tab']
            eventually('management tab', lambda: request('tab.state', {'tab': manage})['url'] == 'chrome://extensions/' and
                       request('tab.state', {'tab': manage})['devToolsReady'])
            source = Path(__file__).resolve().parents[1] / 'tests/extension'
            request('extension.load', {'tab': manage, 'path': str(source)})
            rows = eventually('extension installed', lambda: [r for r in request('extension.list', {'tab': manage})
                              if r['name'] == 'YabCore Test'])
            extension = rows[0]['id']
            report['extension'] = extension
            owner = request('tab.create', {'profile': 'popup', 'url': base + '/'})['tab']
            eventually('owner ready', lambda: (lambda s: s['hasDocument'] and not s['loading'] and
                       s['url'].startswith(base))(request('tab.state', {'tab': owner})), pump=owner)
            state = request('extension.actions', {'tab': owner})
            report['buttons'] = state.get('buttons')
            report['nativeWindow'] = state.get('nativeWindow')
            names = [b.get('label') or b.get('title') for b in state['buttons']]
            wanted = next((n for n in names if n and 'YabCore Test' in n), None)
            check('toolbar lists the extension action', wanted, names)
            mark = len(events)
            request('extension.pressAction', {'tab': owner, 'name': wanted})
            shown = eventually('popup.layer shown', lambda: next((e['params'] for e in events[mark:]
                               if e['event'] == 'popup.layer' and e['params'].get('contextId')), None), 20, pump=owner)
            report['popup'] = shown
            check('popup names its owner tab', shown.get('tab') == owner, shown)
            check('popup names its extension', shown.get('extensionId') == extension or extension in json.dumps(shown), shown)
            check('popup has a token and a compositor context', shown.get('token') and shown.get('contextId'), shown)
            scale = max(float(shown.get('scale') or 1), 1.0)
            width = max(int(float(shown.get('pixelWidth') or 0) / scale), 240)
            height = max(int(float(shown.get('pixelHeight') or 0) / scale), 120)
            pending = out / 'host-state.pending'
            pending.write_text(json.dumps({'contextId': shown['contextId'], 'width': width, 'height': height, 'token': 'popup'}))
            pending.replace(out / 'host-state.json')
            image = eventually('popup capture', lambda: json.loads((out / 'popup.json').read_text())
                               if (out / 'popup.json').exists() else None, pump=owner)
            report['popupPixels'] = image
            check('popup pixels are the popup page', image['own'] == 'ScreenCaptureKit' and image['green'] > image['total'] * .3, image)
            click = request('popup.input', {'tab': owner, 'token': shown['token'], 'kind': 'mouseMove', 'x': 20, 'y': 20}, allow_error=True)
            check('popup input reaches the popup', 'error' not in click, click)
            other = request('popup.input', {'tab': manage, 'token': shown['token'], 'kind': 'mouseMove', 'x': 20, 'y': 20}, allow_error=True)
            check('another tab cannot drive the popup', 'error' in other, other)
            saved = len(events)
            for kind in ('mouseDown', 'mouseUp'):
                request('popup.input', {'tab': owner, 'token': shown['token'], 'kind': kind, 'x': 20, 'y': 20})
            opened = eventually('popup download', lambda: next((e['params'] for e in events[saved:]
                                if e['event'] == 'download.open'), None), 15, pump=owner)
            report['popupDownload'] = opened
            check('popup download belongs to its owner tab', opened.get('tab') == owner and
                  opened.get('url', '').startswith(f'blob:chrome-extension://{extension}/') and
                  opened.get('name') == 'popup-save.md', opened)
            request('download.cancel', {'tab': owner, 'download': opened['download']})
            request('popup.close', {'tab': owner, 'token': shown['token']})
            eventually('popup closed', lambda: any(e['event'] == 'popup.layer' and e['params'].get('state') == 'closed'
                       for e in events[mark:]) or any(e['event'] == 'popup.closed' for e in events[mark:]), 15, pump=owner)
            check('close reported', True)
            request('shutdown')
            process.wait(timeout=20)
            report['passed'] = True
    except Exception as error:
        report['error'] = repr(error) + ' ' + traceback.format_exc()[-1500:]
        raise
    finally:
        stop(host)
        if peer:
            peer.close()
        stop(process)
        server.shutdown()
        report['events'] = [e for e in events if e['event'].startswith('popup.') or e['event'] == 'tab.created']
        (out / 'popup-proof.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
