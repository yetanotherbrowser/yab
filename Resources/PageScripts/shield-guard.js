// Shield's click guard: ad code lays a clear link or box over the whole
// page so any click opens another site. A real page never does, so that
// click is stopped and the cover taken away. Setup is two listeners;
// nothing is measured until a click.
//
// Served inside shield-scriptlets.js, at its marker (Filters.Scriptlets.library),
// which calls it in the top frame of a site the lists name for a scriptlet,
// where Shield is on: never on a site no list names.
function guardClicks(host) {
    var SECOND_LEVEL = ' co com net org gov edu ac or ne go gob nic mil ';
    // Share of the viewport a cover hides: whole-page, never a card in a list.
    var COVER_SHARE = 0.6;
    var GESTURE_MS = 1000;
    var MEDIA = /^(img|svg|video|canvas|picture|iframe|object|embed)$/;

    function siteOf(host) {
        host = String(host || '').toLowerCase();
        if (/^[\d.]+$/.test(host) || host.indexOf(':') >= 0 || host.charAt(0) === '[') return host;
        var parts = host.split('.');
        if (parts.length < 3) return host;
        var keep = SECOND_LEVEL.indexOf(' ' + parts[parts.length - 2] + ' ') >= 0 ? 3 : 2;
        return parts.slice(-keep).join('.');
    }

    function setUp(win, here) {
        var apply = Reflect.apply;
        var defineProperty = Object.defineProperty;
        var getOwnDescriptor = Object.getOwnPropertyDescriptor;
        var ProxyType = Proxy, URLType = URL, now = Date.now;
        var listen = EventTarget.prototype.addEventListener;
        var getAttribute = Element.prototype.getAttribute;
        var removeAttribute = Element.prototype.removeAttribute;
        var closest = Element.prototype.closest;
        var querySelectorAll = Element.prototype.querySelectorAll;
        var rectOf = Element.prototype.getBoundingClientRect;
        var styleOf = win.getComputedStyle;
        var removeChild = Node.prototype.removeChild;
        var parentNode = getOwnDescriptor(Node.prototype, 'parentNode').get;
        var baseURI = getOwnDescriptor(Node.prototype, 'baseURI').get;
        var textContent = getOwnDescriptor(Node.prototype, 'textContent').get;
        var eventTarget = getOwnDescriptor(Event.prototype, 'target').get;
        var localName = getOwnDescriptor(Element.prototype, 'localName').get;
        var eventType = getOwnDescriptor(Event.prototype, 'type').get;
        var eventDetail = getOwnDescriptor(UIEvent.prototype, 'detail').get;
        var preventDefault = Event.prototype.preventDefault;
        var stopImmediate = Event.prototype.stopImmediatePropagation;
        // The person's click, and whether it was found to be on a cover:
        // then nothing it sets off opens anything, however many times.
        var gesture = null, gestureAt = 0, stopped = false, hooked = false;

        function element(node) {
            return node && node.nodeType === 1 ? node : null;
        }

        function offSite(href, base) {
            if (href === null || href === undefined) return false;
            var url = new URLType(String(href), base);
            if (url.protocol !== 'http:' && url.protocol !== 'https:') return false;
            return siteOf(url.hostname) !== here;
        }

        function linkOf(node) {
            var el = element(node);
            var link = el ? apply(closest, el, ['a[href], area[href]']) : null;
            return link && offSite(apply(getAttribute, link, ['href']), apply(baseURI, link, [])) ? link : null;
        }

        function coversPage(el) {
            var r = apply(rectOf, el, []);
            var w = win.innerWidth, h = win.innerHeight;
            var seen = Math.max(0, Math.min(r.right, w) - Math.max(r.left, 0)) * Math.max(0, Math.min(r.bottom, h) - Math.max(r.top, 0));
            return w > 0 && h > 0 && seen >= COVER_SHARE * w * h;
        }

        // Only its alpha: rgb(204, 0, 0) ends in a 0 too, its blue.
        function clearColor(color) {
            if (color === 'transparent') return true;
            var alpha = /^rgba\([^,]*,[^,]*,[^,]*,\s*([\d.]+%?)\)$/.exec(color) || /\/\s*([\d.]+%?)\)$/.exec(color);
            return !!alpha && parseFloat(alpha[1]) === 0;
        }

        function fills(style) {
            return !clearColor(style.backgroundColor) || style.backgroundImage !== 'none';
        }

        // ::before and ::after draw words or a picture textContent can't see.
        function drawsBeside(el, which) {
            var style = apply(styleOf, win, [el, which]);
            var content = style.content;
            if (!content || content === 'none' || content === 'normal' || style.display === 'none') return false;
            return (content !== '""' && content !== "''") || fills(style);
        }

        function drawsNothing(el) {
            if (fills(apply(styleOf, win, [el]))) return false;
            if (drawsBeside(el, '::before') || drawsBeside(el, '::after')) return false;
            var name = apply(localName, el, []);
            if (!MEDIA.test(name)) return true;
            var r = apply(rectOf, el, []);
            return r.width <= 48 || r.height <= 48;
        }

        // Drawn as nothing: faded out, or no words, fill or picture in it
        // at all. Anything with much inside is taken as the page's own.
        function clear(el) {
            var fade = 1;
            for (var node = el, depth = 0; element(node) && depth < 16; node = apply(parentNode, node, []), depth++) {
                fade *= parseFloat(apply(styleOf, win, [node]).opacity) || 0;
            }
            if (fade < 0.1) return true;
            if (/\S/.test(apply(textContent, el, []) || '') || !drawsNothing(el)) return false;
            var inside = apply(querySelectorAll, el, ['*']);
            if (inside.length > 24) return false;
            for (var i = 0; i < inside.length; i++) {
                if (!drawsNothing(inside[i])) return false;
            }
            return true;
        }

        function isCover(el) {
            return !!el && coversPage(el) && clear(el);
        }

        function takeAway(el) {
            try {
                var parent = apply(parentNode, el, []);
                if (parent) apply(removeChild, parent, [el]);
            } catch (e) {}
        }

        function begin(target) {
            gesture = element(target);
            gestureAt = now();
            stopped = false;
        }

        // The click the user made is on a cover, by its own link or by
        // whatever the page does with it. Once it is, it stays so: taking
        // the cover away doesn't stop the handler that is running.
        function inCoverGesture() {
            if (now() - gestureAt > GESTURE_MS) return false;
            if (stopped) return true;
            if (!gesture) return false;
            var cover = gesture;
            gesture = null;
            if (!isCover(cover)) return false;
            stopped = true;
            takeAway(cover);
            return true;
        }

        // Without its href the link goes nowhere, even when the click
        // cannot be cancelled or the link is not in the page.
        function stopLink(link, event) {
            stopped = true;
            apply(removeAttribute, link, ['href']);
            if (event) {
                apply(preventDefault, event, []);
                apply(stopImmediate, event, []);
            }
            takeAway(link);
        }

        function scriptOpensLink(node) {
            var link = linkOf(node);
            if (!link) return false;
            if (!isCover(link) && !inCoverGesture()) return false;
            stopLink(link, null);
            return true;
        }

        function wrap(owner, key, handler) {
            var descriptor = getOwnDescriptor(owner, key);
            if (!descriptor || typeof descriptor.value !== 'function' || !descriptor.writable) return;
            defineProperty(owner, key, {
                value: new ProxyType(descriptor.value, { apply: handler }),
                writable: true, enumerable: descriptor.enumerable, configurable: descriptor.configurable
            });
        }

        // Only from the first touch on, so a page that is never clicked
        // keeps every native as it was.
        function hook() {
            hooked = true;
            wrap(win, 'open', function (target, self, call) {
                var blocked = false;
                try {
                    var url = call.length ? call[0] : '';
                    blocked = (url === undefined || url === null || String(url) === '' || offSite(url, win.location.href)) && inCoverGesture();
                } catch (e) {}
                return blocked ? null : apply(target, self, call);
            });
            wrap(win.HTMLElement.prototype, 'click', function (target, self, call) {
                var blocked = false;
                try { blocked = scriptOpensLink(self); } catch (e) {}
                return blocked ? undefined : apply(target, self, call);
            });
            wrap(win.EventTarget.prototype, 'dispatchEvent', function (target, self, call) {
                var blocked = false;
                try { blocked = apply(eventType, call[0], []) === 'click' && !call[0].isTrusted && scriptOpensLink(self); } catch (e) {}
                return blocked ? false : apply(target, self, call);
            });
        }

        apply(listen, win, ['pointerdown', function (event) {
            if (!event.isTrusted) return;
            begin(apply(eventTarget, event, []));
            if (!hooked) {
                try { hook(); } catch (e) {}
            }
        }, { capture: true, passive: true }]);

        apply(listen, win, ['click', function (event) {
            try {
                var target = apply(eventTarget, event, []);
                // A pointer's click ends the gesture its pointerdown began;
                // a key's (detail 0) begins its own.
                var same = stopped && apply(eventDetail, event, []) > 0 && now() - gestureAt <= GESTURE_MS;
                if (event.isTrusted && !same) begin(target);
                var link = linkOf(target);
                if (!link) return;
                if (isCover(link) || (!event.isTrusted && inCoverGesture())) stopLink(link, event);
            } catch (e) {}
        }, true]);
    }

    setUp(window, siteOf(host));
}
