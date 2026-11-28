#!/usr/bin/env python3
"""Health probes and rendererPID after a Back/Forward Cache restore.

Usage: bfcache_health_pid.py YABCORE_EXECUTABLE
Exit 0: rendererPID updated and scrolling after BFCache restore stays responsive.
Exit 1: reproduced stale rendererPID or false page.responsive: false.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run import wait_socket

PAGE = (
    b'<!doctype html><title>BFCache Health</title>'
    b'<body style="margin:0;height:4000px;background:#246">'
    b'<script>'
    b'window.__bfcacheRestored = false;'
    b'window.addEventListener("pageshow", function (e) {'
    b'  if (e.persisted) window.__bfcacheRestored = true;'
    b'});'
    b'</script></body>'
)


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'max-age=60')
        self.send_header('Content-Length', str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('helper', type=Path)
    args = parser.parse_args()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_port
    helper = peer = None
    seq = 0
    events = []
    report = {}
    code = 2
    try:
        with tempfile.TemporaryDirectory(prefix='ycb-', dir='/tmp') as temporary:
            directory = Path(temporary)
            os.chmod(directory, 0o700)
            endpoint = directory / 'core.sock'
            log_path = directory / 'helper.log'
            with log_path.open('w') as log:
                helper = subprocess.Popen(
                    [str(args.helper), f'--socket={endpoint}', f'--data-root={directory / "data"}',
                     '--no-sandbox', '--use-mock-keychain', '--no-default-browser-check'],
                    stdout=log, stderr=log, start_new_session=True)
                wait_socket(endpoint, helper)
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
                            raise ConnectionError('YabCore disconnected during ' + method)
                        message = json.loads(line)
                        if 'event' in message:
                            events.append(message)
                            continue
                        if message.get('id') != ident:
                            continue
                        if 'error' in message:
                            if allow_error:
                                return {'error': message['error']}
                            raise RuntimeError(method + ': ' + json.dumps(message['error']))
                        return message['result']

                def wait_ready(tab, prefix, require_pid=True, timeout=30):
                    end = time.monotonic() + timeout
                    state = None
                    while time.monotonic() < end:
                        state = request('tab.state', {'tab': tab})
                        if (state.get('devToolsReady') and state.get('hasDocument')
                                and not state.get('loading')
                                and state.get('url', '').startswith(prefix)
                                and (not require_pid or state.get('rendererPID', 0) > 0)):
                            return state
                        time.sleep(0.1)
                    raise RuntimeError('page not ready: ' + json.dumps(state)[:400])

                def wait_bfcache_back(tab, prefix, timeout=15):
                    end = time.monotonic() + timeout
                    while time.monotonic() < end:
                        state = request('tab.state', {'tab': tab})
                        if state.get('url', '').startswith(prefix) and not state.get('loading'):
                            val = request('script.document', {'tab': tab, 'expression': '!!window.__bfcacheRestored'}, allow_error=True)
                            if val is True:
                                return state, True
                        time.sleep(0.1)
                    state = request('tab.state', {'tab': tab})
                    val = request('script.document', {'tab': tab, 'expression': '!!window.__bfcacheRestored'}, allow_error=True)
                    return state, val is True

                request('hello')
                request('profile.open', {'profile': 'bfcache'})
                url_a = f'http://127.0.0.1:{port}/a'
                url_b = f'http://localhost:{port}/b'

                tab = request('tab.create', {'profile': 'bfcache', 'url': url_a})['tab']
                request('tab.resize', {'tab': tab, 'width': 800, 'height': 600, 'scale': 1}, allow_error=True)
                request('tab.visible', {'tab': tab, 'visible': True}, allow_error=True)
                state_a = wait_ready(tab, url_a)
                pid_a = state_a['rendererPID']
                report['pidA'] = pid_a

                request('tab.navigate', {'tab': tab, 'url': url_b})
                end = time.monotonic() + 20
                state_b = None
                while time.monotonic() < end:
                    state_b = wait_ready(tab, url_b)
                    if state_b['rendererPID'] != pid_a:
                        break
                    time.sleep(0.1)
                pid_b = state_b['rendererPID']
                report['pidB'] = pid_b
                if pid_b == pid_a:
                    raise RuntimeError(f'expected cross-origin navigation to change rendererPID ({pid_a} == {pid_b})')

                # Go Back to url_a (restored from Chromium BFCache in pid_a).
                mark_back = len(events)
                request('tab.back', {'tab': tab})
                state_back, restored_a = wait_bfcache_back(tab, url_a)
                time.sleep(0.3)
                state_back = request('tab.state', {'tab': tab})
                report['back'] = {
                    'bfcacheRestored': restored_a,
                    'pidBeforeScroll': state_back['rendererPID'],
                }

                # Scroll the restored page and wait past the 3s health probe deadline.
                request('input.send', {
                    'tab': tab, 'kind': 'wheel', 'x': 200, 'y': 200,
                    'deltaX': 0, 'deltaY': -120, 'phase': 1, 'momentumPhase': 0, 'modifiers': 0,
                })
                time.sleep(4.2)
                state_after_back = request('tab.state', {'tab': tab})
                media_after_back = request('media.read', {'tab': tab})
                js_back = request('script.document', {'tab': tab, 'expression': '1 + 1'}, allow_error=True)
                back_responsive = [e['params'] for e in events[mark_back:] if e['event'] == 'page.responsive']
                report['back'].update({
                    'pidAfterScroll': state_after_back['rendererPID'],
                    'healthPings': media_after_back.get('healthPings'),
                    'healthPongs': media_after_back.get('healthPongs'),
                    'healthUnresponsive': media_after_back.get('healthUnresponsive'),
                    'responsiveEvents': back_responsive,
                    'jsAlive': js_back == 2,
                })

                # Also check Forward BFCache restore back to url_b (pid_b).
                mark_fwd = len(events)
                request('tab.forward', {'tab': tab})
                state_fwd, restored_b = wait_bfcache_back(tab, url_b)
                time.sleep(0.3)
                state_fwd = request('tab.state', {'tab': tab})
                report['forward'] = {
                    'bfcacheRestored': restored_b,
                    'pidBeforeScroll': state_fwd['rendererPID'],
                }
                pings_before_fwd = media_after_back.get('healthPings', 0)
                pongs_before_fwd = media_after_back.get('healthPongs', 0)
                request('input.send', {
                    'tab': tab, 'kind': 'wheel', 'x': 200, 'y': 200,
                    'deltaX': 0, 'deltaY': -120, 'phase': 1, 'momentumPhase': 0, 'modifiers': 0,
                })
                time.sleep(4.2)
                state_after_fwd = request('tab.state', {'tab': tab})
                media_after_fwd = request('media.read', {'tab': tab})
                js_fwd = request('script.document', {'tab': tab, 'expression': '2 + 2'}, allow_error=True)
                fwd_responsive = [e['params'] for e in events[mark_fwd:] if e['event'] == 'page.responsive']
                report['forward'].update({
                    'pidAfterScroll': state_after_fwd['rendererPID'],
                    'healthPingsDelta': media_after_fwd.get('healthPings', 0) - pings_before_fwd,
                    'healthPongsDelta': media_after_fwd.get('healthPongs', 0) - pongs_before_fwd,
                    'healthUnresponsive': media_after_fwd.get('healthUnresponsive'),
                    'responsiveEvents': fwd_responsive,
                    'jsAlive': js_fwd == 4,
                })

                # Verify real main-thread hangs still report responsive: false
                # under the restored rendererPID and recover once unblocked.
                mark_hang = len(events)
                request('script.document', {
                    'tab': tab,
                    'expression': 'setTimeout(function(){var e=performance.now()+4200;while(performance.now()<e){}}, 50); true',
                })
                time.sleep(0.2)
                request('input.send', {
                    'tab': tab, 'kind': 'wheel', 'x': 200, 'y': 200,
                    'deltaX': 0, 'deltaY': -120, 'phase': 1, 'momentumPhase': 0, 'modifiers': 0,
                })
                time.sleep(5.5)
                media_after_hang = request('media.read', {'tab': tab})
                hang_responsive = [e['params'] for e in events[mark_hang:] if e['event'] == 'page.responsive']
                report['realHang'] = {
                    'responsiveEvents': hang_responsive,
                    'healthUnresponsiveAfterRecovery': media_after_hang.get('healthUnresponsive'),
                }

                request('shutdown', allow_error=True)
                helper.wait(timeout=20)

                back_ok = (
                    report['back']['bfcacheRestored']
                    and report['back']['pidBeforeScroll'] == pid_a
                    and report['back']['pidAfterScroll'] == pid_a
                    and report['back']['healthPings'] >= 1
                    and report['back']['healthPongs'] >= 1
                    and not report['back']['healthUnresponsive']
                    and not any(e.get('responsive') is False for e in back_responsive)
                    and report['back']['jsAlive']
                )
                fwd_ok = (
                    report['forward']['bfcacheRestored']
                    and report['forward']['pidBeforeScroll'] == pid_b
                    and report['forward']['pidAfterScroll'] == pid_b
                    and report['forward']['healthPingsDelta'] >= 1
                    and report['forward']['healthPongsDelta'] >= 1
                    and not report['forward']['healthUnresponsive']
                    and not any(e.get('responsive') is False for e in fwd_responsive)
                    and report['forward']['jsAlive']
                )
                hang_ok = (
                    any(e.get('responsive') is False and e.get('rendererPID') == pid_b for e in hang_responsive)
                    and any(e.get('responsive') is True and e.get('rendererPID') == pid_b for e in hang_responsive)
                    and not report['realHang']['healthUnresponsiveAfterRecovery']
                )
                report['passed'] = bool(back_ok and fwd_ok and hang_ok)
                code = 0 if report['passed'] else 1
    except Exception as error:
        report['error'] = repr(error) + '\n' + traceback.format_exc()[-1500:]
    finally:
        if peer:
            peer.close()
        if helper and helper.poll() is None:
            try:
                os.killpg(helper.pid, signal.SIGTERM)
                helper.wait(timeout=10)
            except Exception:
                pass
        server.shutdown()
        server.server_close()
        print(json.dumps(report, indent=2), flush=True)
    sys.exit(code)


if __name__ == '__main__':
    main()
