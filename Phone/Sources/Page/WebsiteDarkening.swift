import WebKit

/// The Mac's bundled Dark Reader, opt-in on iPhone. The engine lives outside
/// the page's world; images keep their colors and a site's own dark look wins.
@MainActor
enum WebsiteDarkening {
    static let styleID = "yab-website-darkening"
    static let world = WKContentWorld.world(name: "yab.phone.website-darkening")
    private static let message = "yabWebsiteDarkening"

    private static let engine = resource("darkreader")
    static let proxy = resource("darkreader-proxy")
    static var resourcesAvailable: Bool { !engine.isEmpty && !proxy.isEmpty }

    private static func resource(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Every new document and frame asks for the current setting. The handler
    /// keeps neither a web view nor WKFrameInfo, including after a tab closes.
    static func install(in controller: WKUserContentController, fixturesEnabled: Bool = false,
                        enabled: @escaping @MainActor () -> Bool = { SettingsStore.shared.darkenWebsites }) {
        controller.addScriptMessageHandler(Setting(enabled), contentWorld: world, name: message)
        controller.addUserScript(WKUserScript(source: proxy, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        controller.addUserScript(WKUserScript(source: "globalThis.__yabWebsiteDarkEngine = function () {\n" + engine + "\n};",
                                             injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        let bootstrap = source.replacingOccurrences(of: "__YAB_FIXTURES__", with: fixturesEnabled ? "true" : "false")
        controller.addUserScript(WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
    }

    /// Back on a controller whose scripts were all taken off, its handler
    /// still there (WebPool.adopt): WebKit refuses a second of one name.
    static func reinstall(in controller: WKUserContentController, fixturesEnabled: Bool = false) {
        controller.removeScriptMessageHandler(forName: message, contentWorld: world)
        install(in: controller, fixturesEnabled: fixturesEnabled)
    }

    static func update(enabled: Bool) -> String {
        "globalThis.__yabWebsiteDarkening?.setEnabled(\(enabled ? "true" : "false"));"
    }

    static let source = """
    (() => {
      if (globalThis.__yabWebsiteDarkening) return;
      const child = window !== window.top;
      if (!['http:', 'https:'].includes(location.protocol) && !(child && location.protocol === 'about:') && !(__YAB_FIXTURES__ && location.protocol === 'yab-page:')) return;
      if (!['text/html', 'application/xhtml+xml'].includes(document.contentType)) return;
      const handler = window.webkit?.messageHandlers?.yabWebsiteDarkening;
      if (!handler) return;
      const scheme = matchMedia('(prefers-color-scheme: dark)');
      const event = 'yab-website-darkening-setting';
      const theme = {mode: 1, brightness: 100, contrast: 100, sepia: 0,
        darkSchemeBackgroundColor: '#1c1c1c', darkSchemeTextColor: '#e8e6e3',
        scrollbarColor: '', selectionColor: 'auto', styleSystemControls: false};
      let enabled = false, running = false, pending = false, revision = 0;
      let ready = false;
      const own = node => node?.nodeType === 1 && (node.classList?.contains('darkreader') || node.closest?.('.darkreader'));

      const indicator = on => {
        let element = document.getElementById('yab-website-darkening');
        if (!on) { element?.remove(); return; }
        if (!element && document.documentElement) {
          element = document.createElement('style');
          element.id = 'yab-website-darkening';
          element.className = 'darkreader yab-website-darkening';
          (document.head || document.documentElement).append(element);
        }
      };
      const off = () => {
        if (running) globalThis.DarkReader?.disable();
        running = false;
        indicator(false);
      };
      const startEngine = () => {
        if (globalThis.DarkReader) return true;
        if (typeof globalThis.__yabWebsiteDarkEngine !== 'function') return false;
        // The preinstalled page-world proxy also works on a strict-CSP site.
        const insert = Node.prototype.insertBefore;
        Node.prototype.insertBefore = function (node, before) {
          if (node?.nodeName === 'SCRIPT' && node.classList?.contains('darkreader--proxy')) {
            const flags = /\\((true|false), (true|false)\\)\\s*$/.exec(node.textContent || '');
            document.dispatchEvent(new CustomEvent('__yabdark__proxy' + (flags?.[1] === 'true' ? 1 : 0) + (flags?.[2] === 'true' ? 1 : 0)));
            return node;
          }
          return insert.call(this, node, before);
        };
        globalThis.__yabWebsiteDarkEngine.call(globalThis);
        if (!globalThis.DarkReader) return false;
        // Styles and image analysis use only the page's resources, without
        // sending cookies or app credentials through a native fetch service.
        globalThis.DarkReader.setFetchMethod(url => {
          const target = new URL(url, location.href);
          if (!['http:', 'https:'].includes(target.protocol)) return Promise.reject(new Error('Unsupported darkening resource'));
          return fetch(target.href, {credentials: 'omit', cache: 'force-cache'});
        });
        return true;
      };
      const canvas = document.createElement('canvas');
      canvas.width = canvas.height = 1;
      const context = canvas.getContext('2d', {willReadFrequently: true});
      const ground = element => {
        if (!element || !context) return null;
        context.clearRect(0, 0, 1, 1);
        context.fillStyle = getComputedStyle(element).backgroundColor;
        context.fillRect(0, 0, 1, 1);
        const [r, g, b, a] = context.getImageData(0, 0, 1, 1).data;
        return a >= 128 ? (r * 0.2126 + g * 0.7152 + b * 0.0722) / 255 : null;
      };
      const siteIsDark = () => {
        const root = document.documentElement;
        if (!root) return false;
        if (document.querySelector('meta[name="darkreader-lock"]')) return true;
        if (!running && root.hasAttribute('data-darkreader-mode')) return true;
        // Read the site's colors with our sheets disabled in the same task.
        // Keeping the engine installed avoids rebuilding it on every mutation.
        const sheets = Array.from(document.querySelectorAll('style.darkreader')).map(style => [style, style.disabled]);
        for (const [style] of sheets) style.disabled = true;
        try {
          let value = ground(document.body) ?? ground(root);
          if (value != null && value < 0.5) return true;
          if (innerWidth > 0 && innerHeight > 0) {
            const votes = [];
            for (const [x, y] of [[0.5, 0.5], [0.25, 0.3], [0.75, 0.7]]) {
              for (const element of document.elementsFromPoint(innerWidth * x, innerHeight * y)) {
                const color = ground(element);
                if (color != null) { votes.push(color); break; }
              }
            }
            if (votes.length) {
              const visible = votes.sort((a, b) => a - b)[Math.floor(votes.length / 2)];
              if (visible < 0.5) return true;
              if (value == null) value = visible;
            }
          }
          if (value != null) return value < 0.5;
          const meta = document.querySelector('meta[name="color-scheme" i]');
          return /\\bdark\\b/.test(getComputedStyle(root).colorScheme + ' ' + (meta?.content || ''));
        } finally {
          for (const [style, disabled] of sheets) style.disabled = disabled;
        }
      };
      const apply = () => {
        pending = false;
        if (!ready || !document.documentElement) return;
        if (!enabled || !scheme.matches || siteIsDark()) { off(); return; }
        if (running || !startEngine()) return;
        try { globalThis.DarkReader.enable(theme); running = true; indicator(true); }
        catch (_) { globalThis.DarkReader?.disable(); running = false; indicator(false); }
      };
      const schedule = () => {
        if (pending) return;
        pending = true;
        requestAnimationFrame(apply);
      };
      const broadcast = value => {
        for (let index = 0; index < window.frames.length; index++) {
          try { window.frames[index].postMessage({kind: event, enabled: value}, '*'); } catch (_) {}
        }
      };
      const setEnabled = value => {
        revision++;
        enabled = value === true;
        if (!enabled) off();
        else schedule();
        broadcast(enabled);
      };
      globalThis.__yabWebsiteDarkening = {setEnabled};
      addEventListener('message', message => {
        if (child && message.source === window.parent && message.data?.kind === event) setEnabled(message.data.enabled);
      });
      const ask = () => {
        const requested = revision;
        handler.postMessage('setting').then(value => {
          if (revision === requested) setEnabled(value);
        }).catch(() => { if (revision === requested) setEnabled(false); });
      };
      scheme.addEventListener('change', schedule);
      addEventListener('pageshow', ask);
      addEventListener('load', schedule);
      document.addEventListener('load', schedule, true);
      document.addEventListener('visibilitychange', schedule);
      const siteStyle = text => (text || '').split(';').map(part => part.trim()).filter(part => part && !part.startsWith('--darkreader')).join(';');
      const attributes = new MutationObserver(records => {
        if (records.some(record => record.attributeName !== 'style' || siteStyle(record.oldValue) !== siteStyle(record.target.getAttribute('style')))) schedule();
      });
      const headChanges = new MutationObserver(records => {
        if (records.some(record => !own(record.target) && Array.from(record.addedNodes).concat(Array.from(record.removedNodes)).some(node => !own(node)))) schedule();
      });
      const watch = () => {
        if (!document.documentElement) return;
        attributes.observe(document.documentElement, {attributes: true, attributeOldValue: true, attributeFilter: ['class', 'style', 'data-theme', 'data-color-mode']});
        if (document.body) attributes.observe(document.body, {attributes: true, attributeOldValue: true, attributeFilter: ['class', 'style', 'data-theme', 'data-color-mode']});
        if (document.head) headChanges.observe(document.head, {childList: true, subtree: true});
      };
      const stylesReady = () => {
        watch();
        const links = Array.from(document.querySelectorAll('link[rel~="stylesheet" i]')).filter(link =>
          !link.sheet && !link.disabled && (!link.media || matchMedia(link.media).matches));
        const finish = () => { if (!ready) { ready = true; schedule(); } };
        if (!links.length) { finish(); return; }
        let left = links.length;
        const loaded = () => { if (--left <= 0) finish(); };
        for (const link of links) {
          link.addEventListener('load', loaded, {once: true});
          link.addEventListener('error', loaded, {once: true});
        }
        setTimeout(finish, 1500);
      };
      watch();
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', stylesReady, {once: true});
      else stylesReady();
      ask();
    })();
    """

    private final class Setting: NSObject, WKScriptMessageHandlerWithReply {
        private let enabled: @MainActor () -> Bool
        init(_ enabled: @escaping @MainActor () -> Bool) { self.enabled = enabled }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            MainActor.assumeIsolated { replyHandler(enabled(), nil) }
        }
    }
}
