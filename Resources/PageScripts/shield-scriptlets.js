(function () {
    'use strict';
    var TABLE = __YAB_TABLE__;
    var OFF = __YAB_OFF__;

    var SECOND_LEVEL = ' co com net org gov edu ac or ne go gob nic mil ';

    // MARK: - which calls run in this frame

    // Every frame runs this part, so it captures nothing and builds nothing
    // until the table names this frame's host.

    function originHost(origin) {
        var at = origin ? origin.indexOf('://') : -1;
        if (at < 0) return '';
        var host = origin.slice(at + 3);
        var colon = host.lastIndexOf(':');
        if (colon > host.lastIndexOf(']')) host = host.slice(0, colon);
        return host;
    }

    // about:blank, srcdoc and blob frames have no hostname of their own but
    // run with their creator's origin.
    function frameHost() {
        var host = '';
        try { host = location.hostname; } catch (e) {}
        if (!host) {
            try { host = originHost(self.origin); } catch (e) {}
        }
        host = host.toLowerCase();
        if (host.charAt(host.length - 1) === '.') host = host.slice(0, -1);
        return host;
    }

    function candidates(host) {
        var keys = [], last = host.lastIndexOf('.');
        var second = last > 0 ? host.lastIndexOf('.', last - 1) : -1;
        var twoPart = second >= 0 && SECOND_LEVEL.indexOf(' ' + host.slice(second + 1, last) + ' ') >= 0;
        for (var at = 0; ;) {
            keys.push(at ? host.slice(at) : host);
            if (at < last) keys.push(host.slice(at, last) + '.*');
            if (twoPart && at < second) keys.push(host.slice(at, second) + '.*');
            var dot = host.indexOf('.', at);
            if (dot < 0) return keys;
            at = dot + 1;
        }
    }

    // Keys are sorted by code unit, so a binary search finds one without
    // scanning the whole string, which a frame would pay for every key.
    function listFor(hosts, key) {
        var lo = 1, hi = hosts.length;
        while (lo < hi) {
            var mid = (lo + hi) >>> 1;
            var start = hosts.lastIndexOf(' ', mid - 1) + 1;
            var equals = hosts.indexOf('=', start), end = hosts.indexOf(' ', start);
            if (equals < 0 || end < equals) return null;
            var found = hosts.slice(start, equals);
            if (found === key) return hosts.slice(equals + 1, end);
            if (found < key) lo = end + 1;
            else hi = start;
        }
        return null;
    }

    function pick(hosts, keys) {
        var on = [], cancelled = {}, seen = {};
        for (var i = 0; i < keys.length; i++) {
            var list = listFor(hosts, keys[i]);
            if (list === null) continue;
            if (list === '*off') return [];
            var parts = list.split(',');
            for (var j = 0; j < parts.length; j++) {
                var n = parseInt(parts[j], 10);
                if (n !== n) continue;
                if (n < 0) cancelled[-n - 1] = true;
                else if (!seen[n]) { seen[n] = true; on.push(n); }
            }
        }
        return on.filter(function (n) { return !cancelled[n]; }).sort(function (a, b) { return a - b; });
    }

    // One pass over the lines, so only the picked calls are ever cut out.
    // A call can be at two indexes (a line that spares sites has its own):
    // it runs once.
    function decode(calls, picked) {
        var out = [], line = 0, at = 0, seen = Object.create(null);
        for (var i = 0; i < picked.length; i++) {
            for (; line < picked[i]; line++) {
                at = calls.indexOf('\n', at) + 1;
                if (!at) return out;
            }
            var end = calls.indexOf('\n', at);
            var text = calls.slice(at, end < 0 ? calls.length : end);
            if (seen[text]) continue;
            seen[text] = true;
            out.push(text.split('\t'));
        }
        return out;
    }

    function bareHost(host) {
        return host.indexOf('www.') === 0 ? host.slice(4) : host;
    }

    function topHost(own) {
        if (window === window.top) return own;
        try {
            var ancestors = location.ancestorOrigins;
            if (ancestors && ancestors.length) return originHost(ancestors[ancestors.length - 1]).toLowerCase();
        } catch (e) {}
        try { return window.top.location.hostname.toLowerCase(); } catch (e) {}
        return '';
    }

    // WebKit gates the whole script in Swift; Chromium registers it always
    // and carries Shield's state in the data instead.
    function allowed(own) {
        if (!OFF) return true;
        if (OFF.enabled === false) return false;
        var off = OFF.off || [];
        var top = topHost(own);
        return off.indexOf(top) < 0 && off.indexOf(bareHost(top)) < 0;
    }

    try {
        if (!TABLE || TABLE.v !== 2) return;
        var hosts = TABLE.hosts, calls = TABLE.calls;
        if (typeof hosts !== 'string' || typeof calls !== 'string' || hosts.charAt(0) !== ' ') return;
        var host = frameHost();
        if (!host) return;
        var picked = pick(hosts, candidates(host));
        if (!picked.length || !allowed(host)) return;
        try { start(decode(calls, picked)); } catch (e) {}
        // The click guard (shield-guard.js) only where the lists name the
        // page's own site: a table naming others leaves it as it was.
        if (window === window.top) guardClicks(host);
    } catch (e) {}

    // MARK: - the scriptlets, set up only in a frame that runs some

    // Still the same synchronous run at document start, so every native
    // below is taken before any page script can replace it.
    function start(calls) {
        var win = window;
        var apply = Reflect.apply;
        var defineProperty = Object.defineProperty;
        var getOwnDescriptor = Object.getOwnPropertyDescriptor;
        var hasOwn = Object.prototype.hasOwnProperty;
        var ProxyType = Proxy, WeakMapType = WeakMap, WeakSetType = WeakSet, RegExpType = RegExp;
        var ReferenceErrorType = ReferenceError;
        var fnToString = Function.prototype.toString;
        var mapGet = WeakMap.prototype.get, mapHas = WeakMap.prototype.has, mapSet = WeakMap.prototype.set;
        var setHas = WeakSet.prototype.has, setAdd = WeakSet.prototype.add;
        var regTest = RegExp.prototype.test;
        var indexOf = String.prototype.indexOf;
        var later = win.setTimeout;
        var listen = EventTarget.prototype.addEventListener;
        var currentScript = getOwnDescriptor(Document.prototype, 'currentScript').get;
        var textContent = getOwnDescriptor(Node.prototype, 'textContent').get;
        var eventTarget = getOwnDescriptor(Event.prototype, 'target').get;
        var localName = getOwnDescriptor(Element.prototype, 'localName').get;
        var defaultView = getOwnDescriptor(Document.prototype, 'defaultView').get;
        var iframeDocument = getOwnDescriptor(HTMLIFrameElement.prototype, 'contentDocument').get;
        var frameDocument = win.HTMLFrameElement ? getOwnDescriptor(HTMLFrameElement.prototype, 'contentDocument').get : null;
        var createElement = Document.prototype.createElement;
        var appendChild = Node.prototype.appendChild;
        var removeChild = Node.prototype.removeChild;
        var setAttribute = Element.prototype.setAttribute;
        var getAttribute = Element.prototype.getAttribute;
        var parentNode = getOwnDescriptor(Node.prototype, 'parentNode').get;
        var baseURI = getOwnDescriptor(Node.prototype, 'baseURI').get;
        var eventType = getOwnDescriptor(Event.prototype, 'type').get;
        var preventDefault = Event.prototype.preventDefault;
        var URLType = URL;
        var MAGIC = 'yab' + Math.random().toString(36).slice(2);

        // MARK: - shared pieces

        var disguised = null;
        var nativeShape = apply(fnToString, hasOwn, []);

        // Ad code tells a wrapped function by its source text.
        function disguise(fn, original, name) {
            if (!disguised) {
                disguised = new WeakMapType();
                var toString = new ProxyType(fnToString, {
                    apply: function (target, self, args) {
                        if (apply(mapHas, disguised, [self])) return apply(mapGet, disguised, [self]);
                        return apply(target, self, args);
                    }
                });
                apply(mapSet, disguised, [toString, nativeShape.replace('hasOwnProperty', 'toString')]);
                defineProperty(Function.prototype, 'toString', { value: toString, writable: true, enumerable: false, configurable: true });
            }
            var text = original ? apply(fnToString, original, []) : nativeShape.replace('hasOwnProperty', name || '');
            apply(mapSet, disguised, [fn, text]);
            return fn;
        }

        function wrap(owner, key, handler) {
            var original = owner[key];
            if (typeof original !== 'function') return false;
            var descriptor = getOwnDescriptor(owner, key);
            if (descriptor && !descriptor.configurable && !descriptor.writable) return false;
            var proxy = new ProxyType(original, { apply: handler });
            disguise(proxy, original);
            defineProperty(owner, key, {
                value: proxy,
                writable: descriptor ? descriptor.writable : true,
                enumerable: descriptor ? descriptor.enumerable : false,
                configurable: descriptor ? descriptor.configurable : true
            });
            return proxy;
        }

        function contains(text, part) {
            return apply(indexOf, text, [part]) >= 0;
        }

        // A bad regex gives null so the call does nothing rather than everything.
        function matcher(arg, negatable) {
            var pattern = arg === undefined || arg === null ? '' : String(arg), negated = false;
            if (negatable && pattern.charAt(0) === '!') { negated = true; pattern = pattern.slice(1); }
            if (pattern === "''" || pattern === '""') pattern = '';
            var test;
            var regex = /^\/(.+)\/([dgimsuvy]*)$/.exec(pattern);
            if (pattern === '') {
                test = function () { return true; };
            } else if (regex) {
                var expression;
                try { expression = new RegExpType(regex[1], regex[2].replace(/[gy]/g, '')); } catch (e) { return null; }
                test = function (text) { return apply(regTest, expression, [text]); };
            } else {
                test = function (text) { return contains(text, pattern); };
            }
            return negated ? function (text) { return !test(text); } : test;
        }

        function sourceOf(value) {
            try {
                if (typeof value === 'function') return apply(fnToString, value, []);
                if (value && typeof value.handleEvent === 'function') return apply(fnToString, value.handleEvent, []);
                return String(value);
            } catch (e) {
                return '';
            }
        }

        function isObject(value) {
            return value !== null && (typeof value === 'object' || typeof value === 'function');
        }

        // Which rules' source pattern a callback matches, worked out once per
        // function: pages pass the same handlers again and again.
        function hitsFor(cache, rules, value) {
            var keyed = isObject(value);
            if (keyed) {
                var known = apply(mapGet, cache, [value]);
                if (known !== undefined) return known;
            }
            var text = sourceOf(value), hits = false;
            for (var i = 0; i < rules.length; i++) {
                if (rules[i].source(text)) (hits || (hits = []))[i] = true;
            }
            if (keyed) apply(mapSet, cache, [value, hits]);
            return hits;
        }

        var quieted = false;
        function abort() {
            if (!quieted) {
                quieted = true;
                apply(listen, win, ['error', function (event) {
                    var message = event && event.message;
                    if (typeof message === 'string' && contains(message, MAGIC)) {
                        event.preventDefault();
                        event.stopImmediatePropagation();
                    }
                }, true]);
            }
            return new ReferenceErrorType(MAGIC);
        }

        // MARK: - property chains

        // Not configurable: a page's own defineProperty (an inline ad library, aclib) throws,
        // which stops its script as an abort would. Rules that share a link
        // (a.b and a.c) share its trap: each adds its rest of the path to it.
        var chained = null;
        function trapChain(owner, path, last) {
            var dot = path.indexOf('.');
            if (dot < 0) {
                try { last(owner, path); } catch (e) {}
                return;
            }
            var key = path.slice(0, dot), rest = path.slice(dot + 1);
            var links = chained && apply(mapGet, chained, [owner]);
            var shared = links && links['k:' + key];
            if (shared) {
                shared[shared.length] = [rest, last];
                var now = current(owner, key);
                if (isObject(now)) trapChain(now, rest, last);
                return;
            }
            var descriptor = getOwnDescriptor(owner, key), value;
            try { value = owner[key]; } catch (e) { return; }
            var native = owner === win && isObject(value);
            var replaceable = !descriptor || (descriptor.configurable && 'value' in descriptor);
            if (native || !replaceable) {
                if (isObject(value)) trapChain(value, rest, last);
                return;
            }
            var hooks = [[rest, last]];
            var seen = new WeakSetType();
            var into = function (next) {
                if (!isObject(next) || apply(setHas, seen, [next])) return;
                apply(setAdd, seen, [next]);
                for (var i = 0; i < hooks.length; i++) trapChain(next, hooks[i][0], hooks[i][1]);
            };
            try {
                defineProperty(owner, key, {
                    configurable: false,
                    enumerable: descriptor ? descriptor.enumerable : true,
                    get: disguise(function () { return value; }, null, 'get'),
                    set: disguise(function (next) { value = next; into(next); }, null, 'set')
                });
                if (!chained) chained = new WeakMapType();
                if (!links) { links = {}; apply(mapSet, chained, [owner, links]); }
                links['k:' + key] = hooks;
            } catch (e) {}
            into(value);
        }

        function current(owner, key) {
            try { return owner[key]; } catch (e) { return undefined; }
        }

        function aopr(args) {
            if (!args[0]) return;
            trapChain(win, args[0], function (owner, key) {
                defineProperty(owner, key, {
                    configurable: false,
                    get: disguise(function () { throw abort(); }, null, 'get'),
                    set: disguise(function () {}, null, 'set')
                });
            });
        }

        function aopw(args) {
            if (!args[0]) return;
            trapChain(win, args[0], function (owner, key) {
                var value = current(owner, key);
                defineProperty(owner, key, {
                    configurable: false,
                    get: disguise(function () { return value; }, null, 'get'),
                    set: disguise(function () { throw abort(); }, null, 'set')
                });
            });
        }

        function acs(args) {
            if (!args[0]) return;
            var test = args[1] ? matcher(args[1], false) : null;
            if (args[1] && !test) return;
            var verdicts = new WeakMapType();
            var check = function () {
                var script = apply(currentScript, document, []);
                if (!script) return;
                if (!test) throw abort();
                var hit = apply(mapGet, verdicts, [script]);
                if (hit === undefined) {
                    hit = !!test(apply(textContent, script, []) || '');
                    apply(mapSet, verdicts, [script, hit]);
                }
                if (hit) throw abort();
            };
            trapChain(win, args[0], function (owner, key) {
                var value = current(owner, key);
                defineProperty(owner, key, {
                    configurable: false,
                    get: disguise(function () { check(); return value; }, null, 'get'),
                    set: disguise(function (next) { check(); value = next; }, null, 'set')
                });
            });
        }

        // MARK: - set-constant

        function noop() {}

        function constant(raw) {
            var fns = {
                noopFunc: function () { return disguise(function () {}, null, ''); },
                trueFunc: function () { return disguise(function () { return true; }, null, ''); },
                falseFunc: function () { return disguise(function () { return false; }, null, ''); },
                throwFunc: function () { return disguise(function () { throw new Error(); }, null, ''); },
                noopCallbackFunc: function () { return disguise(function () { return noop; }, null, ''); },
                noopPromiseResolve: function () { return disguise(function () { return Promise.resolve(); }, null, ''); },
                noopPromiseReject: function () { return disguise(function () { return Promise.reject(); }, null, ''); }
            };
            if (apply(hasOwn, fns, [raw])) return { value: fns[raw]() };
            switch (raw) {
                case 'undefined': return { value: undefined };
                case 'null': return { value: null };
                case 'true': return { value: true };
                case 'false': return { value: false };
                case '': case "''": case '""': case 'emptyStr': return { value: '' };
                case '[]': case 'emptyArr': return { value: [] };
                case '{}': case 'emptyObj': return { value: {} };
                case 'yes': case 'no': return { value: raw };
                case '-1': return { value: -1 };
            }
            if (/^\d+$/.test(raw)) {
                var number = parseInt(raw, 10);
                if (number <= 32767) return { value: number };
            }
            return null;
        }

        function named(args, from, token) {
            for (var i = from; i + 1 < args.length; i += 2) {
                if (args[i] === token) return args[i + 1];
            }
            return '';
        }

        function wrapped(value, as) {
            switch (as) {
                case 'function': return disguise(function () { return value; }, null, '');
                case 'callback': return disguise(function () { return function () { return value; }; }, null, '');
                case 'resolved': return Promise.resolve(value);
                case 'rejected': return Promise.reject(value);
            }
            return value;
        }

        function set(args) {
            if (!args[0] || args.length < 2) return;
            var made = constant(String(args[1]));
            if (!made) return;
            var as = named(args, 2, 'as');
            var fixed = made.value, ready = false;
            var value = function () {
                if (!ready) { fixed = wrapped(made.value, as); ready = true; }
                return fixed;
            };
            trapChain(win, args[0], function (owner, key) {
                var released = false, own;
                defineProperty(owner, key, {
                    configurable: false,
                    enumerable: true,
                    get: disguise(function () { return released ? own : value(); }, null, 'get'),
                    set: disguise(function (next) {
                        if (released) { own = next; return; }
                        var mine = value();
                        // A different type means the name is used for something else.
                        if (mine === undefined || mine === null || next === undefined || next === null) return;
                        if (typeof next !== typeof mine) { released = true; own = next; }
                    }, null, 'set')
                });
            });
        }

        // MARK: - addEventListener, setTimeout

        // One wrap for all of a frame's rules, so a call pays one trap however
        // many rules the site has.
        var listenerRules = null, listenerHits = null;
        var timerRules = null, timerHits = null;

        function inScope(target, elements) {
            if (!elements) return true;
            if (elements === 'window') return target === win;
            if (elements === 'document') return target === document;
            try { return !!(target && target.nodeType === 1 && target.matches(elements)); } catch (e) { return false; }
        }

        function listenerDefused(self, call) {
            if (call.length < 2 || !call[1]) return false;
            var type = String(call[0]), hits = null;
            for (var i = 0; i < listenerRules.length; i++) {
                var rule = listenerRules[i];
                if (!rule.type(type)) continue;
                if (hits === null) hits = hitsFor(listenerHits, listenerRules, call[1]);
                if (!hits) return false;
                if (hits[i] && inScope(self, rule.elements)) return true;
            }
            return false;
        }

        function aeld(args) {
            var type = matcher(args[0], true), source = matcher(args[1], true);
            if (!type || !source) return;
            if (!listenerRules) {
                listenerRules = [];
                listenerHits = new WeakMapType();
                wrap(EventTarget.prototype, 'addEventListener', function (target, self, call) {
                    try { if (listenerDefused(self, call)) return undefined; } catch (e) {}
                    return apply(target, self, call);
                });
            }
            listenerRules.push({ type: type, source: source, elements: named(args, 2, 'elements') });
        }

        function delayMatcher(raw) {
            var pattern = raw === undefined || raw === null ? '' : String(raw), negated = false;
            if (pattern === '') return function () { return true; };
            if (pattern.charAt(0) === '!') { negated = true; pattern = pattern.slice(1); }
            var range = /^(\d*)-(\d*)$/.exec(pattern), low, high;
            if (range && (range[1] || range[2])) {
                low = range[1] ? parseInt(range[1], 10) : 0;
                high = range[2] ? parseInt(range[2], 10) : Infinity;
            } else if (/^\d+$/.test(pattern)) {
                low = high = parseInt(pattern, 10);
            } else {
                return null;
            }
            return function (delay) {
                var ms = Math.floor(Number(delay));
                if (!(ms > 0)) ms = 0;
                var inside = ms >= low && ms <= high;
                return negated ? !inside : inside;
            };
        }

        function timerDefused(call) {
            var hits = null;
            for (var i = 0; i < timerRules.length; i++) {
                if (!timerRules[i].delay(call[1])) continue;
                if (hits === null) hits = hitsFor(timerHits, timerRules, call[0]);
                if (!hits) return false;
                if (hits[i]) return true;
            }
            return false;
        }

        function nostif(args) {
            if (!args.length || (!args[0] && !args[1])) return;
            var source = matcher(args[0], true), delay = delayMatcher(args[1]);
            if (!source || !delay) return;
            if (!timerRules) {
                timerRules = [];
                timerHits = new WeakMapType();
                wrap(win, 'setTimeout', function (target, self, call) {
                    try { if (timerDefused(call)) return apply(target, self, [noop, call[1]]); } catch (e) {}
                    return apply(target, self, call);
                });
            }
            timerRules.push({ source: source, delay: delay });
        }

        // MARK: - window.open

        var openRules = [];
        var ourOpens = new WeakSetType();

        function openText(call) {
            var parts = [];
            for (var i = 0; i < call.length; i++) {
                try { parts.push(String(call[i])); } catch (e) { parts.push(''); }
            }
            return parts.join(' ');
        }

        function decoyObject(owner, url, seconds) {
            var fake = {
                closed: false,
                opener: owner,
                name: '',
                location: { href: url },
                document: null,
                close: function () { fake.closed = true; },
                focus: noop,
                blur: noop,
                postMessage: noop
            };
            try { fake.document = owner.document.implementation.createHTMLDocument(''); } catch (e) {}
            apply(later, win, [function () { fake.closed = true; }, seconds * 1000]);
            return fake;
        }

        // A frame without script rights, so code that checks the window finds one.
        function decoy(owner, url, seconds, asObject) {
            var doc = owner.document, root = doc && doc.documentElement;
            if (asObject || !root) return decoyObject(owner, url, seconds);
            var frame = apply(createElement, doc, ['iframe']);
            apply(setAttribute, frame, ['sandbox', 'allow-same-origin']);
            apply(setAttribute, frame, ['style', 'position:absolute;width:1px;height:1px;left:-10000px;top:-10000px;border:0;visibility:hidden']);
            apply(appendChild, root, [frame]);
            var opened = frame.contentWindow;
            armRealm(opened);
            apply(later, win, [function () {
                try { apply(removeChild, frame.parentNode, [frame]); } catch (e) {}
            }, seconds * 1000]);
            return opened;
        }

        function openHandler(owner) {
            return function (target, self, call) {
                var text = openText(call);
                for (var i = 0; i < openRules.length; i++) {
                    var rule = openRules[i];
                    if (!rule.test(text)) continue;
                    if (rule.replacement === 'blank') {
                        var blank = Array.prototype.slice.call(call);
                        blank[0] = 'about:blank';
                        return apply(target, self, blank);
                    }
                    if (rule.seconds >= 0) {
                        try { return decoy(owner, call.length ? String(call[0]) : '', rule.seconds, rule.replacement === 'obj'); } catch (e) { return null; }
                    }
                    return null;
                }
                return apply(target, self, call);
            };
        }

        // Null for a cross-origin frame, so its window is never touched:
        // WebKit logs every blocked cross-origin access.
        function frameContent(element) {
            try { return apply(iframeDocument, element, []); } catch (e) {}
            try { return frameDocument ? apply(frameDocument, element, []) : null; } catch (e) { return null; }
        }

        function armDocument(doc) {
            var view = null;
            try { view = doc && apply(defaultView, doc, []); } catch (e) {}
            if (view) armRealm(view);
        }

        function hookFrameGetter(proto, key) {
            var descriptor = proto && getOwnDescriptor(proto, key);
            if (!descriptor || !descriptor.get) return;
            var proxy = new ProxyType(descriptor.get, {
                apply: function (target, self, call) {
                    var result = apply(target, self, call);
                    try { if (result) armDocument(key === 'contentDocument' ? result : frameContent(self)); } catch (e) {}
                    return result;
                }
            });
            disguise(proxy, descriptor.get);
            defineProperty(proto, key, { get: proxy, set: descriptor.set, enumerable: descriptor.enumerable, configurable: descriptor.configurable });
        }

        // A frame with no src loads at once, inside whatever inserted it
        // (parser, write, appendChild, innerHTML), so one capturing listener
        // arms it before the next line of page code. Load does not reach the
        // window, hence the document.
        function armOnLoad(doc) {
            apply(listen, doc, ['load', function (event) {
                try {
                    var element = apply(eventTarget, event, []);
                    var name = element && element.nodeType === 1 ? apply(localName, element, []) : '';
                    if (name === 'iframe' || name === 'frame') armDocument(frameContent(element));
                } catch (e) {}
            }, true]);
        }

        // Ad code falls back to a fresh iframe's open when the top one looks
        // wrapped, so every way a page reaches a new frame's window arms it.
        function armRealm(target) {
            var open;
            try { open = target && target.open; } catch (e) { return; }
            if (typeof open !== 'function' || apply(setHas, ourOpens, [open])) return;
            var proxy = wrap(target, 'open', openHandler(target));
            if (!proxy) return;
            apply(setAdd, ourOpens, [proxy]);
            try {
                armOnLoad(target.document);
                // Hooking a child frame's prototypes makes the engine build
                // them, the most costly part of arming a frame; its load
                // listener already covers the frames it makes.
                if (target !== win) return;
                hookFrameGetter(target.HTMLIFrameElement.prototype, 'contentWindow');
                hookFrameGetter(target.HTMLIFrameElement.prototype, 'contentDocument');
                if (target.HTMLFrameElement) {
                    hookFrameGetter(target.HTMLFrameElement.prototype, 'contentWindow');
                    hookFrameGetter(target.HTMLFrameElement.prototype, 'contentDocument');
                }
            } catch (e) {}
        }

        // MARK: - links clicked by script

        // On phones ad code turns a tap into a script click on a made-up
        // target=_blank link, which never goes through window.open.
        var linksGuarded = false;

        // As the click guard (shield-guard.js) reckons a site.
        function siteOf(host) {
            host = String(host || '').toLowerCase();
            if (/^[\d.]+$/.test(host) || host.indexOf(':') >= 0 || host.charAt(0) === '[') return host;
            var parts = host.split('.');
            if (parts.length < 3) return host;
            var keep = SECOND_LEVEL.indexOf(' ' + parts[parts.length - 2] + ' ') >= 0 ? 3 : 2;
            return parts.slice(-keep).join('.');
        }

        function linkOf(node) {
            for (var depth = 0; node && depth < 32; depth++) {
                if (node.nodeType === 1) {
                    var name = apply(localName, node, []);
                    if (name === 'a' || name === 'area') return node;
                }
                node = apply(parentNode, node, []);
            }
            return null;
        }

        // A new tab on another site, by a nowoif rule.
        function blockedLink(link) {
            var target = apply(getAttribute, link, ['target']);
            target = target === null ? '' : String(target).toLowerCase();
            if (!target || target === '_self' || target === '_parent' || target === '_top') return false;
            var href = apply(getAttribute, link, ['href']);
            if (href === null) return false;
            var url = new URLType(href, apply(baseURI, link, []));
            if (url.protocol !== 'http:' && url.protocol !== 'https:') return false;
            if (siteOf(url.hostname) === siteOf(win.location.hostname)) return false;
            var text = url.href + ' ' + target;
            for (var i = 0; i < openRules.length; i++) {
                if (openRules[i].test(text)) return true;
            }
            return false;
        }

        // The link is often a clear cover over the whole page, taken away
        // so the next tap reaches what is under it.
        function scriptClickBlocked(node) {
            var link = null;
            try {
                link = linkOf(node);
                if (!link || !blockedLink(link)) return false;
            } catch (e) { return false; }
            try {
                var parent = apply(parentNode, link, []);
                if (parent) apply(removeChild, parent, [link]);
            } catch (e) {}
            return true;
        }

        // The wraps cover links outside the page; the listener covers a
        // click made with another frame's natives.
        function guardLinks() {
            if (linksGuarded) return;
            linksGuarded = true;
            wrap(win.HTMLElement.prototype, 'click', function (target, self, call) {
                if (scriptClickBlocked(self)) return;
                return apply(target, self, call);
            });
            wrap(win.EventTarget.prototype, 'dispatchEvent', function (target, self, call) {
                var event = call[0], blocked = false;
                try { blocked = apply(eventType, event, []) === 'click' && !event.isTrusted && scriptClickBlocked(self); } catch (e) {}
                if (blocked) return false;
                return apply(target, self, call);
            });
            apply(listen, win, ['click', function (event) {
                if (!event.isTrusted && scriptClickBlocked(apply(eventTarget, event, []))) apply(preventDefault, event, []);
            }, true]);
        }

        function nowoif(args) {
            var test = matcher(args[0], true);
            if (!test) return;
            var seconds = args[1] ? parseFloat(args[1]) : -1;
            if (!(seconds >= 0)) seconds = -1;
            openRules.push({ test: test, seconds: seconds, replacement: args[2] || '' });
            armRealm(win);
            guardLinks();
        }

        // MARK: - run

        var SCRIPTLETS = { aopr: aopr, aopw: aopw, acs: acs, set: set, aeld: aeld, nostif: nostif, nowoif: nowoif };

        for (var i = 0; i < calls.length; i++) {
            var name = calls[i][0];
            if (!apply(hasOwn, SCRIPTLETS, [name])) continue;
            try { SCRIPTLETS[name](calls[i].slice(1)); } catch (e) {}
        }
    }

    // MARK: - the click guard, put in here when served (shield-guard.js)

    __YAB_GUARD__
})();
