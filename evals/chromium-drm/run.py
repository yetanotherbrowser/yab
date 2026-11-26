#!/usr/bin/env python3
"""Real mixed-engine tab acceptance with a local EME/media stand-in. Farm only."""
import argparse
import http.server
import io
import json
import math
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import threading
import time
import uuid
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'chromium-tabs'))
from run import launch_exact, wait_for
from probe_capture import picture
import yab_socket

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'chromium-extensions'))
from prepared_lifetime import PreparedAppLifetime


class Pages(http.server.BaseHTTPRequestHandler):
    referrers = {}

    def do_GET(self):
        self.referrers[self.path] = self.headers.get('Referer')
        if self.path == '/blocked-by-extension.js':
            body, mime = b'globalThis.blockedScriptLoaded = true;', 'text/javascript'
        elif self.path.startswith('/extension-embedder?'):
            body = b'''<!doctype html><meta name="referrer" content="no-referrer">
<script>
const frame = document.createElement('iframe');
frame.src = new URLSearchParams(location.search).get('resource');
let loaded = false;
addEventListener('message', event => {
    if (event.source === frame.contentWindow && event.data === 'extension-resource') loaded = true;
});
setTimeout(() => parent.postMessage({extensionResourceLoaded: loaded}, '*'), 1500);
document.documentElement.append(frame);
</script>'''
            mime = 'text/html; charset=utf-8'
        elif self.path == '/tone.wav':
            stream = io.BytesIO()
            with wave.open(stream, 'wb') as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(8000)
                wav.writeframes(b''.join(struct.pack('<h', int(100 * math.sin(i * .2))) for i in range(80000)))
            body, mime = stream.getvalue(), 'audio/wav'
        else:
            body = b'''<!doctype html><meta charset="utf-8"><title>DRM fixture</title>
<style>body{margin:40px;background:#164b38;color:white;font:24px system-ui}button{font:inherit;padding:12px}</style>
<h1 id="engine"></h1><p>Local EME failure and clear-media stand-in. No service login.</p>
<button onclick="requestProtected()">Request protected playback</button><audio id="audio" controls src="/tone.wav"></audio>
<script>
const chromium=navigator.userAgent.includes('Chrome/');
document.querySelector('#engine').textContent=chromium?'Chromium before EME failure':'WebKit after EME failure';
function requestProtected(){setTimeout(()=>navigator.requestMediaKeySystemAccess('com.widevine.alpha',
[{initDataTypes:['cenc'],audioCapabilities:[{contentType:'audio/mp4; codecs="mp4a.40.2"'}]}]).catch(()=>{}),500)}
function askCapabilities(){setTimeout(()=>navigator.mediaCapabilities.decodingInfo({type:'media-source',
audio:{contentType:'audio/mp4; codecs="mp4a.40.2"',channels:'2',bitrate:96000,samplerate:44100},
keySystemConfiguration:{keySystem:'com.widevine.alpha'}}),500)}
</script>'''
            mime = 'text/html; charset=utf-8'
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def resource_probe(site, extension_id):
    return f'''const resource = {json.dumps(f'chrome-extension://{extension_id}/resource.html')};
    const allowed = {json.dumps(site)};
    const probe = origin => new Promise(resolve => {{
        const frame = document.createElement('iframe');
        const timer = setTimeout(() => finish(null), 5000);
        const finish = value => {{ clearTimeout(timer); removeEventListener('message', receive); frame.remove(); resolve(value); }};
        const receive = event => {{
            if (event.source === frame.contentWindow && event.origin === origin &&
                typeof event.data?.extensionResourceLoaded === 'boolean') finish(event.data.extensionResourceLoaded);
        }};
        addEventListener('message', receive);
        frame.src = origin + '/extension-embedder?resource=' + encodeURIComponent(resource);
        document.body.append(frame);
    }});
    return Promise.all([probe(allowed), probe(allowed.replace('127.0.0.1', 'localhost'))]);'''


def resource_bridge_probe(extension_id):
    origin = f'chrome-extension://{extension_id}'
    return f'''const origin = {json.dumps(origin)};
    const frame = document.createElement('iframe');
    return new Promise(resolve => {{
        const timer = setTimeout(() => finish(null), 12000);
        const finish = value => {{ clearTimeout(timer); removeEventListener('message', receive); frame.remove(); resolve(value); }};
        const receive = event => {{
            if (event.source === frame.contentWindow && event.origin === origin && event.data?.resourceBridge)
                finish(event.data.resourceBridge);
        }};
        addEventListener('message', receive);
        frame.src = origin + '/resource.html#bridge';
        document.body.append(frame);
    }});'''


def sandbox_probe(extension_id):
    return f'''const frame = document.createElement('iframe');
    frame.src = {json.dumps(f'chrome-extension://{extension_id}/sandbox.html')};
    return new Promise(resolve => {{
        const timer = setTimeout(() => finish(null), 8000);
        const finish = value => {{ clearTimeout(timer); removeEventListener('message', receive); frame.remove(); resolve(value); }};
        const receive = event => {{
            if (event.source === frame.contentWindow && event.data?.sandboxAssets)
                finish({{origin: event.origin, ...event.data.sandboxAssets}});
        }};
        addEventListener('message', receive);
        document.body.append(frame);
    }});'''


def run(app, out, site, cookies=True, extensions=True):
    out.mkdir(parents=True, exist_ok=True)
    world = 'chromium-drm-' + uuid.uuid4().hex[:8]
    domain = 'dev.serafim.fast.test.' + world
    sock = Path.home() / 'Library/Application Support' / f'Yab ({world})' / 'bench.sock'
    defaults = out / 'defaults.plist'
    defaults.write_bytes(plistlib.dumps({'bench': True, 'welcomed': True, 'mail': False,
                                        'hints.noticing': False, 'searchSuggest': False}))
    subprocess.run(['defaults', 'import', domain, str(defaults)], check=True)
    proc = launch_exact(app, dict(os.environ, YAB_PROBE=world, YAB_HISTORY='own', YAB_ENGINE='chromium',
                                 YAB_AGENT_CLAUDE='/usr/bin/true', YAB_AGENT_CODEX='/nonexistent/chromium'), out)
    ask = yab_socket.kwasker(sock, timeout=45, strict=True, takes_timeout=True,
                            fail=lambda req, reply: RuntimeError(f'{req}: {reply}'))
    lifetime = PreparedAppLifetime(app, proc, sock.parent, ask, out)
    report = {'app': str(app), 'pid': proc.pid, 'checks': {}, 'states': {}, 'pictures': [],
              'scope': 'Local EME rejection and clear WAV playback. Spotify/FairPlay accounts unverified.'}
    checks = report['checks']

    def state(tab):
        return ask(do='chromium-drm', id=tab)

    def script(tab, body):
        return ask(do='chromium-drm', id=tab, op='script', body=body)['value']

    def capture(tab, name):
        path = out / (name + '.png')
        ask(do='usage-background', hide=False)
        selection = ask(do='select', id=tab)
        report['states'][name + '_selection'] = selection
        def attached():
            current = state(tab)
            report['states']['last_capture'] = current
            return current if current['window'] > 0 and not current['loading'] else None
        try:
            visible = wait_for(attached, 'Selected DRM tab did not attach to its window')
        except Exception:
            # This is diagnostic evidence only, never a target-tab pass.
            diagnostic = out / ('DIAGNOSTIC-unattached-' + name + '.png')
            try:
                metadata = picture(proc.pid, diagnostic)
                report.setdefault('diagnostic_pictures', []).append({'file': diagnostic.name, 'capture': metadata})
            except Exception as error:
                report['diagnostic_capture_error'] = str(error)
            raise
        metadata = picture(proc.pid, path, window_id=visible['window'])
        report['pictures'].append({'file': path.name, 'capture': metadata})
        checks[name + '_sck'] = metadata.get('capture') == 'ScreenCaptureKit'

    try:
        wait_for(lambda: sock.exists() if proc.poll() is None else False, 'Missing bench socket', 60)
        ask(do='ui', welcome=False, sidebar=True)
        ask(do='usage-background', hide=False)
        tab = ask(do='usage-open', url=site + '/eme')['id']
        def chromium_ready():
            s = state(tab)
            report['states']['last_chromium'] = s
            if s.get('failure'):
                raise RuntimeError('Chromium helper/page failed: ' + str(s))
            return s if s['title'] == 'DRM fixture' and s['context'] > 0 and not s['loading'] else None
        before = wait_for(chromium_ready, 'Chromium fixture not ready')
        report['states']['before'] = before
        checks['started_chromium'] = before['engine'] == 'chromium'
        capture(tab, '01-chromium-before')
        script(tab, 'requestProtected(); return true')
        def fallback_ready():
            s = state(tab)
            report['states']['last_fallback'] = s
            return s if s['engine'] == 'webKit' and s['title'] == 'DRM fixture' and not s['loading'] else None
        after = wait_for(fallback_ready, 'EME fallback did not load WebKit')
        report['states']['after'] = after
        checks['same_tab'] = before['tab'] == after['tab'] and after['tab'].lower().startswith(tab.lower())
        checks['same_url'] = before['url'] == after['url'] == site + '/eme'
        checks['webkit_document'] = script(tab, 'return document.querySelector("#engine").textContent') == 'WebKit after EME failure'
        script(tab, 'await document.querySelector("audio").play(); return true')
        t0 = script(tab, 'return document.querySelector("audio").currentTime')
        time.sleep(1)
        media = script(tab, 'const a=document.querySelector("audio"); return {time:a.currentTime,paused:a.paused,error:a.error?.code??null}')
        report['states']['media'] = media
        checks['clear_media_playing'] = not media['paused'] and media['error'] is None and media['time'] > t0 + .2
        capture(tab, '02-webkit-playing')
        # Shaka asks MediaCapabilities, which answers rather than refuses.
        asking = ask(do='usage-open', url=site + '/capabilities')['id']
        wait_for(lambda: (lambda s: s if s['title'] == 'DRM fixture' and not s['loading'] else None)(state(asking)), 'Capabilities fixture not ready')
        checks['capabilities_page_starts_on_chromium'] = state(asking)['engine'] == 'chromium'
        script(asking, 'askCapabilities(); return true')
        moved = wait_for(lambda: (lambda s: s if s['engine'] == 'webKit' and not s['loading'] else None)(state(asking)), 'MediaCapabilities refusal did not load WebKit')
        checks['capabilities_refusal_moves_the_tab'] = moved['url'] == site + '/capabilities'
        ask(do='usage-close', id=asking)
        ask(do='select', id=tab)
        if cookies:
            cookie_checks = ask(do='chromium-drm', id=tab, op='cookies')['checks']
            checks.update(cookie_checks)
        if extensions:
            fixture = Path(__file__).resolve().parent
            folder = out / 'extension'
            shutil.copytree(fixture / 'extension', folder, dirs_exist_ok=True)
            shutil.copyfile(fixture.parents[1] / 'Resources' / 'Caveat.ttf', folder / 'sandbox.ttf')
            installed = ask(do='chromium-drm', id=tab, op='extension-install', path=str(folder))['extensions']
            report['extension_catalog'] = installed
            if len(installed) != 1:
                raise RuntimeError('Expected exactly one controlled installed extension: ' + str(installed))
            extension_id = installed[0]['id']
            script(tab, 'location.reload(); return true')
            def bridge_state():
                reply = ask(do='chromium-drm', id=tab, op='extension-script', extension=extension_id,
                            body='return globalThis.bridgeResult ?? null')
                report['states']['extension_poll'] = reply
                return reply.get('value')
            result = wait_for(bridge_state, 'WebKit extension did not reply', 90)
            report['states']['extension'] = result
            if 'error' in result or 'error' in result.get('background', {}):
                raise RuntimeError('Extension bridge error: ' + str(result))
            background = result['background']
            sender = background['sender']
            checks['extension_identity'] = result['id'] == sender['id'] == extension_id
            checks['virtual_sender'] = sender['tab']['id'] >= 1000000 and sender['url'] == site + '/eme' and sender['frameId'] == 0 and bool(sender['documentId'])
            checks['background_reply'] = background['reverse']['nonce'] == result['nonce'] and background['reverse']['url'] == site + '/eme'
            checks['extension_storage'] = result['storage']['witness'] == result['nonce']
            checks['extension_storage_access'] = result['trustedStorageDenied'] is True and result['allowedStorage']['witness'] == result['nonce']
            checks['extension_ports'] = result['portReply']['echo']['nonce'] == result['nonce'] and result['portReply']['document'] == sender['documentId']
            checks['extension_scripting'] = background['scripted'][0]['result'] == 'executed-in-webkit' and script(tab, 'return document.documentElement.dataset.bridgeScript') == 'yes'
            checks['extension_i18n'] = result['i18n'] == 'Hello WebKit'
            checks['extension_tabs_get'] = background['queried']['id'] == sender['tab']['id'] and background['queried']['url'] == sender['url']
            spa = ask(do='chromium-drm', id=tab, op='extension-script', extension=extension_id, body="history.pushState({},'', '#bridge-spa'); const changed=await chrome.runtime.sendMessage({kind:'sender'}); history.replaceState({},'',location.pathname+location.search); await chrome.runtime.sendMessage({kind:'sender'}); return changed")['value']
            checks['extension_same_document_url'] = spa['documentId'] == sender['documentId'] and spa['tab']['id'] == sender['tab']['id'] and spa['url'] == site + '/eme#bridge-spa' and spa['tab']['url'] == spa['url']
            checks['extension_isolated'] = script(tab, 'return typeof globalThis.bridgeResult') == 'undefined'
            checks['extension_handler_isolated'] = script(tab, 'return typeof window.webkit?.messageHandlers?.yabChromiumExtension') == 'undefined'
            events = ask(do='chromium-drm', id=tab, op='extension-script', extension=extension_id, body='return globalThis.bridgeEvents')['value']
            checks['extension_storage_event'] = any(e.get('area') == 'local' and e.get('changes', {}).get('witness', {}).get('newValue') == result['nonce'] for e in events)
            blocked = script(tab, "return await new Promise(resolve=>{const s=document.createElement('script');s.src='/blocked-by-extension.js';s.onload=()=>resolve(false);s.onerror=()=>resolve(true);document.head.append(s)})")
            checks['extension_dnr_blocked'] = blocked is True
            script(tab, "const f=document.createElement('iframe');f.src='/frame';f.style.cssText='width:90%;height:180px;border:1px solid #8df6b8';document.body.append(f);return true")
            def frame_result():
                return ask(do='chromium-drm', id=tab, op='extension-script', extension=extension_id, frame=1, body='return globalThis.bridgeResult ?? null').get('value')
            child = wait_for(frame_result, 'Child-frame extension did not reply', 60)
            report['states']['extension_child'] = child
            if 'error' in child or 'error' in child.get('background', {}):
                raise RuntimeError('Child bridge error: ' + str(child))
            child_sender = child['background']['sender']
            checks['extension_child_identity'] = child_sender['frameId'] == 1 and child_sender['tab']['id'] == sender['tab']['id'] and child_sender['tab']['url'] == site + '/eme' and child_sender['url'] == site + '/frame' and child_sender['documentId'] != sender['documentId']
            checks['extension_child_ports'] = child['portReply']['echo']['nonce'] == child['nonce'] and child['portReply']['document'] == child_sender['documentId']
            checks['extension_child_scripting'] = child['background']['scripted'][0]['frameId'] == 1 and child['background']['scripted'][0]['result'] == 'executed-in-webkit'
            capture(tab, '03-webkit-chromium-extension')
            allowed, excluded = script(tab, resource_probe(site, extension_id))
            checks['extension_resource_with_no_referrer'] = allowed is True
            checks['extension_resource_excluded_embedder'] = excluded is False
            page_bridge = script(tab, resource_bridge_probe(extension_id))
            report['states']['extension_page_bridge'] = page_bridge
            page_sender = (page_bridge or {}).get('sender', {})
            page_origin = f'chrome-extension://{extension_id}'
            checks['extension_page_sender'] = (page_sender.get('url') == page_origin + '/resource.html#bridge'
                                               and page_sender.get('origin') == page_origin
                                               and page_sender.get('tab', {}).get('url') == site + '/eme')
            checks['extension_template_fetch'] = (page_bridge or {}).get('template') == '<span>extension-template</span>\n'
            checks['extension_page_reply'] = (page_bridge or {}).get('reverse') == 'extension-page-reply'
            sandbox = script(tab, sandbox_probe(extension_id))
            report['states']['extension_sandbox'] = sandbox
            checks['extension_sandbox_displays_own_assets'] = bool(sandbox and sandbox['image'] and sandbox['font'])
            checks['extension_sandbox_stays_opaque'] = bool(sandbox and sandbox['origin'] == 'null' and not sandbox['runtime'])
        # Per-site choices use the public model through the isolated bench.
        # Keep the original local acceptance above intact, including its media,
        # cookies and extension witness on the Recommended fallback path.
        def choice(tab, value):
            return ask(do='chromium-drm', id=tab, op='site-engine', choice=value)

        def engine_ready(tab, engine, path, needs_surface=True):
            def ready():
                current = state(tab)
                report['states']['last_site_choice'] = current
                return current if (current['engine'] == engine and current['url'] == site + path
                                   and current['title'] == 'DRM fixture' and not current['loading']
                                   and (not needs_surface or engine != 'chromium' or current['context'] > 0)) else None
            return wait_for(ready, 'Site engine did not load ' + engine)

        chosen = choice(tab, 'chromium')
        forced = engine_ready(tab, 'chromium', '/eme')
        checks['choice_same_tab'] = chosen['tab'] == before['tab'] == forced['tab']
        script(tab, 'requestProtected(); return true')
        time.sleep(2)
        checks['forced_chromium_suppresses_eme'] = state(tab)['engine'] == 'chromium'
        checks['choice_persisted'] = ask(do='chromium-drm', id=tab, op='site-engine')['choice'] == 'chromium'
        capture(tab, '04-forced-chromium')
        choice(tab, 'webKit')
        webkit = engine_ready(tab, 'webKit', '/eme')
        checks['forced_webkit_same_tab'] = webkit['tab'] == before['tab']
        capture(tab, '05-forced-webkit')
        second = ask(do='usage-open', url=site + '/second')['id']
        checks['new_tab_obeys_host_choice'] = engine_ready(second, 'webKit', '/second')['engine'] == 'webKit'
        choice(second, 'chromium')
        engine_ready(second, 'chromium', '/second')
        # An already-open WebKit page follows another tab's explicit host choice
        # at its next allowed main-frame navigation, retaining its own UUID.
        script(tab, "location.href='/route-chromium'; return true")
        routed = engine_ready(tab, 'chromium', '/route-chromium', needs_surface=False)
        checks['webkit_navigation_obeys_override'] = routed['tab'] == before['tab']
        report['states']['webkit_to_chromium'] = routed
        checks['webkit_navigation_referrer_header'] = Pages.referrers.get('/route-chromium') == site + '/eme'
        checks['webkit_navigation_document_referrer'] = script(tab, 'return document.referrer') == site + '/eme'
        # The first tab navigated in the background. Require its document above,
        # then select it before asking for a compositor or taking its picture.
        # An unselected page can legitimately have no window/context yet.
        ask(do='select', id=tab)
        engine_ready(tab, 'chromium', '/route-chromium')
        capture(tab, '06-webkit-to-chromium-navigation')
        choice(second, 'webKit')
        engine_ready(second, 'webKit', '/second')
        script(tab, "location.href='/route-webkit'; return true")
        routed_back = engine_ready(tab, 'webKit', '/route-webkit')
        checks['chromium_navigation_obeys_override'] = routed_back['tab'] == before['tab']
        report['states']['chromium_to_webkit'] = routed_back
        capture(tab, '07-chromium-to-webkit-navigation')
        choice(tab, 'recommended')
        reset = engine_ready(tab, 'chromium', '/route-webkit')
        checks['recommended_restores_automatic_default'] = reset['tab'] == before['tab'] and ask(do='chromium-drm', id=tab, op='site-engine')['choice'] == 'recommended'
        script(tab, 'requestProtected(); return true')
        fallback_again = engine_ready(tab, 'webKit', '/route-webkit')
        checks['recommended_restores_eme_fallback'] = fallback_again['tab'] == before['tab']
        report['states']['site_choice_final'] = fallback_again
        report['ok'] = all(checks.values())
        if not report['ok']:
            raise RuntimeError('Acceptance failed: ' + str(checks))
    finally:
        # Reference only, never a check: today's Site Controls panel drawn by
        # the app itself, for pixel-true "Opens in" mockups.
        if proc.poll() is None:
            for dark in (False, True):
                path = out / ('reference-site-controls-' + ('dark' if dark else 'light') + '.png')
                try:
                    ask(do='site-shot', path=str(path), dark=dark)
                    report.setdefault('reference_pictures', []).append(path.name)
                except Exception as error:
                    report.setdefault('reference_errors', []).append(str(error))
        lifetime.finish(report, result_key='ok')
        subprocess.run(['defaults', 'delete', domain], capture_output=True)
    if not report.get('ok'):
        raise RuntimeError('DRM routing acceptance or natural owned cleanup failed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--skip-cookies', action='store_true')
    parser.add_argument('--skip-extensions', action='store_true')
    args = parser.parse_args()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Pages)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        run(args.app, args.out, f'http://127.0.0.1:{server.server_port}', cookies=not args.skip_cookies, extensions=not args.skip_extensions)
    finally:
        server.shutdown()
