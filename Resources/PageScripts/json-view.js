// A document that came as JSON, shown as a tree you can fold and search, or
// as text set out with indents and line numbers (JSONView.swift,
// docs/json-viewer.md). It runs in yab's own world, at the document's end,
// in the main frame only. Anything that isn't JSON leaves at the first lines.
//
// The page is never taken apart: WebKit's own <pre> stays in the body, which
// is only hidden, so `text`, `snapshot` and ⌘J read the JSON as it was sent.
// The viewer is a sibling of <body>, in a closed shadow root no extension or
// agent snapshot sees. Only the rows on screen are in it, so a document of a
// million lines scrolls like one of a hundred; find asks the viewer, which
// looks in the data, not in what is drawn.
(function () {
  'use strict';

  // ======================================================================
  // The data: read, laid out and written back. Nothing here needs a page,
  // so the tests run it in JavaScriptCore alone (JSONViewTests).
  // ======================================================================
  var Core = (function () {
    var NUM = /-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/y;

    // The text read as JSON, in order: keys where they were written, numbers
    // exactly as written (JSON.parse puts the keys that look like numbers
    // first and rounds 1849384729384729384), a second key of the same name
    // kept and marked. Throws an error with `at`, where reading stopped.
    function parse(s, from) {
      var i = from || 0, L = s.length, lines = 0;
      function fail(message) { var e = new Error(message); e.at = Math.min(i, L); throw e; }
      function ws() {
        for (;;) {
          var c = s.charCodeAt(i);
          if (c === 32 || c === 10 || c === 13 || c === 9) i++;
          else return c;
        }
      }
      function str() {
        var start = ++i;
        for (;;) {
          var q = s.indexOf('"', i);
          if (q < 0) { i = start - 1; fail('A string is not closed'); }
          var b = q - 1, n = 0;
          while (b >= start && s.charCodeAt(b) === 92) { b--; n++; }
          if (n % 2 === 1) { i = q + 1; continue; }
          var raw = s.slice(start, q);
          var nl = raw.indexOf('\n');
          if (nl >= 0) { i = start + nl; fail('A string breaks across lines'); }
          i = q + 1;
          return raw.indexOf('\\') < 0 ? raw : unescape(raw, start);
        }
      }
      function unescape(raw, start) {
        var out = '', k = 0;
        for (;;) {
          var j = raw.indexOf('\\', k);
          if (j < 0) return out + raw.slice(k);
          out += raw.slice(k, j);
          var e = raw.charAt(j + 1);
          if (e === 'n') out += '\n';
          else if (e === 't') out += '\t';
          else if (e === 'r') out += '\r';
          else if (e === 'b') out += '\b';
          else if (e === 'f') out += '\f';
          else if (e === '"' || e === '\\' || e === '/') out += e;
          else if (e === 'u' && /^[0-9a-fA-F]{4}$/.test(raw.substr(j + 2, 4))) { out += String.fromCharCode(parseInt(raw.substr(j + 2, 4), 16)); k = j + 6; continue; }
          else { i = start + j; fail('Not a valid escape'); }
          k = j + 2;
        }
      }
      function value() {
        var c = ws();
        lines++;
        if (c === 123) {
          i++;
          var pairs = [], seen = null;
          c = ws();
          if (c === 125) { i++; return { t: 'o', v: pairs }; }
          for (;;) {
            if (c !== 34) fail('Expected a key in quotes');
            var k = str();
            if (ws() !== 58) fail('Expected \u201C:\u201D after the key');
            i++;
            var v = value(), d = false;
            if (!seen) seen = new Set();
            if (seen.has(k)) d = true; else seen.add(k);
            pairs.push({ k: k, v: v, d: d });
            c = ws();
            if (c === 44) { i++; c = ws(); continue; }
            if (c === 125) { i++; lines++; return { t: 'o', v: pairs }; }
            fail('Expected \u201C,\u201D or \u201C}\u201D');
          }
        }
        if (c === 91) {
          i++;
          var items = [];
          c = ws();
          if (c === 93) { i++; return { t: 'a', v: items }; }
          for (;;) {
            items.push(value());
            c = ws();
            if (c === 44) { i++; continue; }
            if (c === 93) { i++; lines++; return { t: 'a', v: items }; }
            fail('Expected \u201C,\u201D or \u201C]\u201D');
          }
        }
        if (c === 34) return { t: 's', v: str() };
        NUM.lastIndex = i;
        var m = NUM.exec(s);
        if (m) { i += m[0].length; return { t: 'n', v: m[0] }; }
        if (s.startsWith('true', i)) { i += 4; return { t: 'l', v: 'true' }; }
        if (s.startsWith('false', i)) { i += 5; return { t: 'l', v: 'false' }; }
        if (s.startsWith('null', i)) { i += 4; return { t: 'l', v: 'null' }; }
        fail(i >= L ? 'The text ends too early' : 'Unexpected \u201C' + s.charAt(i) + '\u201D');
      }
      var root;
      try {
        root = value();
      } catch (e) {
        if (e instanceof RangeError) { e = new Error('Nested too deeply to read'); e.at = i; }
        throw e;
      }
      ws();
      if (i < L) fail('Extra text after the JSON');
      return { root: root, lines: lines };
    }

    // Where `at` is, as the line and column an editor would say.
    function place(s, at) {
      var line = 1, k = -1;
      for (;;) {
        var n = s.indexOf('\n', k + 1);
        if (n < 0 || n >= at) break;
        line++;
        k = n;
      }
      return { line: line, col: at - k };
    }

    // The text set out a value a line, without reading it into a tree: where
    // each line starts and ends in the text and how deep it is. Taken a slice
    // at a time (`more`), so the first screen of 84 MB is there at once and
    // the rest comes in behind it; a tree of millions of nodes never is.
    function indexer(s, from) {
      var cap = 1 << 16, n = 0;
      var starts = new Int32Array(cap), ends = new Int32Array(cap), depths = new Uint16Array(cap);
      var i = from || 0, L = s.length, depth = 0, open = -1, last = i;
      var out = { n: 0, starts: starts, ends: ends, depths: depths, done: false, more: more };
      function push(a, b, d) {
        if (n === cap) {
          cap *= 2;
          var s2 = new Int32Array(cap); s2.set(starts); starts = s2;
          var e2 = new Int32Array(cap); e2.set(ends); ends = e2;
          var d2 = new Uint16Array(cap); d2.set(depths); depths = d2;
          out.starts = starts; out.ends = ends; out.depths = depths;
        }
        starts[n] = a; ends[n] = b; depths[n] = d > 65535 ? 65535 : d; n++;
      }
      // Reads on for about `budget` more characters; says whether it is done.
      function more(budget) {
        if (out.done) return true;
        var stop = budget === undefined ? L : Math.min(L, i + budget);
        while (i < stop) {
          var c = s.charCodeAt(i);
          if (c === 32 || c === 10 || c === 13 || c === 9) { i++; continue; }
          if (c === 34) {
            if (open < 0) open = i;
            var q = i + 1;
            for (;;) {
              q = s.indexOf('"', q);
              if (q < 0) { q = L - 1; break; }
              var b = q - 1, k = 0;
              while (s.charCodeAt(b) === 92) { b--; k++; }
              if ((k & 1) === 0) break;
              q++;
            }
            i = q + 1; last = i;
            continue;
          }
          if (c === 123 || c === 91) {
            if (open < 0) open = i;
            var j = i + 1;
            while (j < L) { var w = s.charCodeAt(j); if (w === 32 || w === 10 || w === 13 || w === 9) j++; else break; }
            if (s.charCodeAt(j) === c + 2) { i = j + 1; last = i; continue; }
            i++; last = i;
            push(open, i, depth); open = -1;
            depth++;
            continue;
          }
          if (c === 125 || c === 93) {
            if (open >= 0) push(open, last, depth);
            if (depth > 0) depth--;
            open = i;
            i++; last = i;
            continue;
          }
          if (c === 44) { i++; last = i; if (open >= 0) { push(open, i, depth); open = -1; } continue; }
          if (c === 58) { i++; last = i; continue; }
          if (open < 0) open = i;
          i++;
          while (i < L) {
            var t = s.charCodeAt(i);
            if (t === 44 || t === 125 || t === 93 || t === 58 || t === 32 || t === 10 || t === 13 || t === 9 || t === 34) break;
            i++;
          }
          last = i;
        }
        if (i >= L) {
          if (open >= 0) { push(open, last, depth); open = -1; }
          out.done = true;
        }
        out.n = n;
        return out.done;
      }
      return out;
    }

    function index(s, from) {
      var ix = indexer(s, from);
      ix.more();
      return ix;
    }

    // One line of `index` as it reads: white space outside strings gone, a
    // space after each colon, two spaces a level in front.
    function compact(seg) {
      var out = '', k = 0, L = seg.length;
      while (k < L) {
        var c = seg.charAt(k);
        if (c === '"') {
          var q = k + 1;
          while (q < L) { var d = seg.charAt(q); if (d === '\\') { q += 2; continue; } if (d === '"') break; q++; }
          out += seg.slice(k, q + 1);
          k = q + 1;
          continue;
        }
        if (c === ' ' || c === '\n' || c === '\r' || c === '\t') { k++; continue; }
        out += c === ':' ? ': ' : c;
        k++;
      }
      return out;
    }

    // Where each line of the text as sent starts and ends.
    function plainLines(s) {
      var starts = [], ends = [], k = 0;
      for (;;) {
        var n = s.indexOf('\n', k);
        starts.push(k);
        if (n < 0) {
          // The newline a file ends with ends its last line; it starts none.
          if (k === s.length && starts.length > 1) starts.pop();
          else ends.push(s.length);
          break;
        }
        ends.push(n > k && s.charCodeAt(n - 1) === 13 ? n - 1 : n);
        k = n + 1;
      }
      return { n: starts.length, starts: starts, ends: ends };
    }

    // Back to JSON, two spaces a level, keys in their order and numbers as
    // they came.
    function pretty(node) {
      var out = [];
      (function w(n, pad) {
        if (n.t === 'o') {
          if (!n.v.length) { out.push('{}'); return; }
          var inner = pad + '  ';
          out.push('{\n');
          for (var i = 0; i < n.v.length; i++) {
            out.push(inner, JSON.stringify(n.v[i].k), ': ');
            w(n.v[i].v, inner);
            out.push(i < n.v.length - 1 ? ',\n' : '\n');
          }
          out.push(pad, '}');
        } else if (n.t === 'a') {
          if (!n.v.length) { out.push('[]'); return; }
          var inner2 = pad + '  ';
          out.push('[\n');
          for (var j = 0; j < n.v.length; j++) {
            out.push(inner2);
            w(n.v[j], inner2);
            out.push(j < n.v.length - 1 ? ',\n' : '\n');
          }
          out.push(pad, ']');
        } else if (n.t === 's') {
          out.push(JSON.stringify(n.v));
        } else {
          out.push(n.v);
        }
      })(node, '');
      return out.join('');
    }

    // On one line, for a record of NDJSON.
    function inline(n) {
      if (n.t === 'o') return '{' + n.v.map(function (x) { return JSON.stringify(x.k) + ': ' + inline(x.v); }).join(', ') + '}';
      if (n.t === 'a') return '[' + n.v.map(inline).join(', ') + ']';
      if (n.t === 's') return JSON.stringify(n.v);
      return n.v;
    }

    // What Copy Value takes: a string without its quotes, the rest as JSON.
    function plain(n) { return n.t === 's' ? n.v : pretty(n); }

    // A key or string as its row draws it: a line break, tab or other
    // control character written back as JSON writes it. A row is one line
    // 22 points high, so a real line break drew the rest of the string over
    // the rows below it.
    var CONTROL = /[\u0000-\u001f]/g;
    var ESCAPES = { '\n': '\\n', '\r': '\\r', '\t': '\\t', '\b': '\\b', '\f': '\\f' };
    function oneLine(v) {
      return v.replace(CONTROL, function (c) {
        return ESCAPES[c] || '\\u' + ('000' + c.charCodeAt(0).toString(16)).slice(-4);
      });
    }

    // `owner.login`, `topics[3]`, `["a b"]`; `$` for the whole.
    function pathText(p) {
      var out = '';
      for (var i = 0; i < p.length; i++) {
        var k = p[i];
        if (typeof k === 'number') out += '[' + k + ']';
        else if (/^[A-Za-z_$][\w$]*$/.test(k)) out += (i ? '.' : '') + k;
        else out += '[' + JSON.stringify(k) + ']';
      }
      return out || '$';
    }

    // `.owner.login`, `.topics[3]`, `.["$schema"]`; `.` for the whole. jq
    // takes a name after a dot only when it is letters, digits and `_`: a
    // `$` there starts a variable, so `.$schema` doesn't run.
    function jq(p) {
      var out = '';
      for (var i = 0; i < p.length; i++) {
        var k = p[i];
        if (typeof k === 'number') out += '[' + k + ']';
        else if (/^[A-Za-z_]\w*$/.test(k)) out += '.' + k;
        else out += '[' + JSON.stringify(k) + ']';
      }
      return out.charAt(0) === '.' ? out : '.' + out;
    }

    function child(n, k) {
      if (n.t === 'a') return n.v[k];
      for (var i = 0; i < n.v.length; i++) if (n.v[i].k === k) return n.v[i].v;
      return null;
    }

    // Time words for a date: "2 hours ago", "in 3 days".
    function ago(ms, now) {
      var d = (now - ms) / 1000, ahead = d < 0;
      d = Math.abs(d);
      var say;
      if (d < 3600) { var m = Math.max(1, Math.round(d / 60)); say = m + (m === 1 ? ' min' : ' min'); }
      else if (d < 86400) { var h = Math.round(d / 3600); say = h + (h === 1 ? ' hour' : ' hours'); }
      else if (d < 86400 * 45) { var dd = Math.round(d / 86400); say = dd + (dd === 1 ? ' day' : ' days'); }
      else if (d < 86400 * 365) { var mo = Math.round(d / (86400 * 30)); say = mo + (mo === 1 ? ' month' : ' months'); }
      else { var y = Math.floor(d / (86400 * 365)); say = y + (y === 1 ? ' year' : ' years'); }
      return ahead ? 'in ' + say : say + ' ago';
    }

    // The quiet word after a value: how long ago a date was, when a Unix
    // time is, a color's swatch (said apart, `swatch`).
    function hint(n, key, now) {
      if (n.t === 's' && /^\d{4}-\d\d-\d\dT\d\d:\d\d/.test(n.v)) {
        var t = Date.parse(n.v);
        if (!isNaN(t)) return ago(t, now);
      }
      if (n.t === 'n' && typeof key === 'string' && /(_at|^exp|^iat|^nbf|timestamp|^time)$/i.test(key) && /^\d{10}(\d{3})?$/.test(n.v)) {
        var ms = n.v.length === 13 ? +n.v : +n.v * 1000;
        return new Date(ms).toISOString().slice(0, 16).replace('T', ' ') + ' UTC';
      }
      return '';
    }

    function swatch(n) {
      return n.t === 's' && /^#(?:[0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(n.v) ? n.v : '';
    }

    // A security prefix that keeps JSON from being run as a script, and
    // where the JSON starts after it.
    function prefix(s) {
      var m = /^\s*(\)\]\}',?|while\s*\(\s*1\s*\)\s*;|for\s*\(\s*;\s*;\s*\)\s*;)/.exec(s.slice(0, 64));
      return m ? { text: m[1].replace(/,$/, ''), from: m[0].length } : null;
    }

    return { parse: parse, place: place, index: index, indexer: indexer, compact: compact, plainLines: plainLines, pretty: pretty,
             inline: inline, plain: plain, oneLine: oneLine, pathText: pathText, jq: jq, child: child, ago: ago, hint: hint,
             swatch: swatch, prefix: prefix };
  })();

  if (typeof document === 'undefined') { globalThis.__yabJSONCore = Core; return; }
  if (window.top !== window || window.__yabJSON) return;

  // ======================================================================
  // Whether this document is JSON at all. Most pages leave here.
  // ======================================================================
  var PREF = '__YAB_MODE__';
  var KEEPS = __YAB_KEEPS__;
  var BIG = 25e6;
  var type = String(document.contentType || '').toLowerCase();
  var path = location.pathname.toLowerCase();
  var file = location.protocol === 'file:';
  var ndjson = /^application\/(x-ndjson|jsonl|x-jsonlines|jsonlines)$/.test(type) || /\.(ndjson|jsonl)$/.test(path);
  var jsonType = /^(application|text)\/(x-)?json$/.test(type) || /\+json$/.test(type) || (file && /\.json$/.test(path));
  var plainType = type === 'text/plain';
  if (!ndjson && !jsonType && !plainType) return;
  var body = document.body;
  if (!body) return;
  // Chromium puts its own pretty-print control beside the <pre>, in a
  // `json-formatter-container`; it is hidden with the body like the rest.
  var kids = Array.prototype.filter.call(body.children, function (e) {
    return !(e.tagName === 'DIV' && e.classList.contains('json-formatter-container'));
  });
  if (kids.length !== 1 || kids[0].tagName !== 'PRE') return;
  var pre = kids[0];
  var raw = pre.textContent;
  if (!raw || !raw.trim()) return;
  var skipped = Core.prefix(raw);
  var from = skipped ? skipped.from : 0;
  var plainSent = plainType && !ndjson && !(file && /\.json$/.test(path));
  if (plainSent) {
    if (raw.length > BIG) return;
    var first = raw.slice(from).trimStart().charAt(0);
    if (first !== '{' && first !== '[') return;
  }

  var data = null, lines = 0, error = null, records = null;
  if (ndjson) {
    records = [];
    var pl = Core.plainLines(raw);
    for (var r = 0; r < pl.n; r++) {
      var text = raw.slice(pl.starts[r], pl.ends[r]);
      if (!text.trim()) continue;
      try { records.push({ node: Core.parse(text).root, text: text }); } catch (e) { records.push({ node: null, text: text }); }
    }
    if (!records.length) return;
  } else if (raw.length <= BIG) {
    try {
      var read = Core.parse(raw, from);
      data = read.root;
      lines = read.lines;
    } catch (e) {
      // A log that only starts like JSON is left as it came.
      if (plainSent) return;
      var where = Core.place(raw, e.at || 0);
      error = { message: e.message, line: where.line, col: where.col };
    }
  }
  var big = !ndjson && raw.length > BIG;

  // ======================================================================
  // The viewer.
  // ======================================================================
  var handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.yabJSON;
  function post(m) { try { if (handler) handler.postMessage(m); } catch (e) {} }

  function isBox(n) { return !!n && (n.t === 'o' || n.t === 'a'); }
  function pk(p) { return p.join('\u0001'); }
  function nodeAt(p) {
    var n = data;
    for (var i = 0; i < p.length && n; i++) n = Core.child(n, p[i]);
    return n;
  }

  // How deep the tree opens at first: all of it up to 300 lines, as
  // Firefox; past that the root and the first level, or only the root
  // when the first level alone is tens of thousands of rows.
  function firstDepth() {
    if (!isBox(data) || lines <= 300) return Infinity;
    var count = 2;
    for (var i = 0; i < data.v.length; i++) {
      var c = data.t === 'o' ? data.v[i].v : data.v[i];
      count += isBox(c) && c.v.length ? 2 + c.v.length : 1;
      if (count > 20000) return 1;
    }
    return 2;
  }

  var KEY = 'yab.json:' + location.href;
  var kept = {};
  if (KEEPS) { try { kept = JSON.parse(sessionStorage.getItem(KEY) || '{}') || {}; } catch (e) { kept = {}; } }
  var S = {
    shown: PREF,
    // Folded by depth, with the boxes opened or shut by hand on top, by
    // the node itself: a tree of a million nodes needs no set of them all.
    foldDepth: firstDepth(),
    folds: new Map(), foldPaths: new Map(),
    sel: null, selPath: null,
    more: new Set(),
    q: '', hits: [], hit: -1, capped: false,
  };
  // Back, forward or ⌘R to the same document: as it was left.
  if (kept.pref === PREF && kept.size === raw.length) {
    if (kept.shown) S.shown = kept.shown;
    if (typeof kept.depth === 'number') S.foldDepth = kept.depth;
    else if (kept.depth === null) S.foldDepth = Infinity;
    if (data && Array.isArray(kept.folds)) kept.folds.forEach(function (f) {
      var n = nodeAt(f[0]);
      if (isBox(n)) { S.folds.set(n, f[1]); S.foldPaths.set(n, f[0]); }
    });
  }
  if (S.shown === 'tree' && (error || (big && !data))) S.shown = 'text';
  if (ndjson && S.shown !== 'sent') S.shown = 'tree';

  function keep() {
    if (!KEEPS) return;
    try {
      var folds = [];
      S.folds.forEach(function (v, n) { var p = S.foldPaths.get(n); if (p && folds.length < 2000) folds.push([p, v]); });
      sessionStorage.setItem(KEY, JSON.stringify({ pref: PREF, size: raw.length, shown: S.shown,
        depth: S.foldDepth === Infinity ? null : S.foldDepth, folds: folds }));
    } catch (e) {}
  }

  var COLORS = __YAB_COLORS__;
  var CHEV = '<svg viewBox="0 0 10 10" aria-hidden="true"><path d="M2 3.5 5 6.5 8 3.5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>';
  var CSS = [
    ':host{all:initial;display:block;min-height:100vh;color-scheme:light dark;',
    '--ground:#fff;--ink:#171717;--muted:#474747;--faint:#616161;--hair:#e8e8e8;--wash:#efefef;--hover:#f6f6f6;',
    '--accent:#2f6bff;--sel:rgba(47,107,255,.14);--red:#d92d20;--red-wash:rgba(217,45,32,.09);--amber:#b45309;',
    '--hit:rgba(255,204,0,.45);--hit-on:rgba(255,150,0,.75);',
    '--j-key:' + COLORS.key[0] + ';--j-str:' + COLORS.string[0] + ';--j-num:' + COLORS.number[0] + ';--j-lit:' + COLORS.literal[0] + ';',
    'background:var(--ground);color:var(--ink);font:12.5px/22px ui-monospace,"SF Mono",Menlo,monospace;-webkit-font-smoothing:antialiased;cursor:default}',
    '@media (prefers-color-scheme:dark){:host{--ground:#1c1c1c;--ink:#ededed;--muted:#d1d1d1;--faint:#bdbdbd;--hair:#333;--wash:#2d2d2d;--hover:#262626;',
    '--accent:#6d97ff;--sel:rgba(109,151,255,.22);--red:#ff6b5e;--red-wash:rgba(255,107,94,.12);--amber:#f0a43a;',
    '--j-key:' + COLORS.key[1] + ';--j-str:' + COLORS.string[1] + ';--j-num:' + COLORS.number[1] + ';--j-lit:' + COLORS.literal[1] + '}}',
    '.top{padding:14px 0 0}.skip{margin:0 16px 8px;font:11.5px/1.5 system-ui,-apple-system,sans-serif;color:var(--faint)}',
    '.skip code{font:11px ui-monospace,"SF Mono",Menlo,monospace;background:var(--wash);padding:1px 5px;border-radius:5px}',
    '.vp{position:relative;margin-bottom:30px}.rows{position:absolute;left:0;top:0;min-width:100%}',
    '.row{display:block;height:22px;line-height:22px;padding:0 16px;white-space:pre;position:relative;box-sizing:border-box}',
    '.row[data-i]:hover{background:var(--hover)}.row.sel,.row.sel:hover{background:var(--sel)}',
    '.ind{display:inline-block}.tw{width:16px;height:16px;display:inline-grid;place-items:center;color:var(--faint);vertical-align:-3px}',
    '.tw[data-tw]{cursor:pointer}.tw svg{width:9px;height:9px;transition:transform .12s}.tw.shut svg{transform:rotate(-90deg)}',
    '@media (prefers-reduced-motion:reduce){.tw svg{transition:none}}',
    '.k{color:var(--j-key)}.s{color:var(--j-str)}.n{color:var(--j-num)}.l{color:var(--j-lit)}.p{color:var(--faint)}',
    '.sum,.hintw,.more,.dup{font:11.5px system-ui,-apple-system,sans-serif}',
    '.sum{color:var(--faint);margin-left:6px}.hintw{color:var(--faint);margin-left:10px}',
    '.sw{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:5px;vertical-align:-1px;box-shadow:0 0 0 .5px rgba(127,127,127,.6) inset}',
    'a.lnk{color:inherit;text-decoration:underline;text-decoration-color:color-mix(in srgb,currentColor 35%,transparent);text-underline-offset:2px;cursor:pointer}',
    '.more{color:var(--accent);margin-left:6px;cursor:pointer}.dup{color:var(--amber);font-size:11px;margin-left:8px}',
    'mark{background:var(--hit);color:inherit;border-radius:3px}mark.on{background:var(--hit-on)}',
    '.lines .row{padding-left:0}.lno{display:inline-block;width:46px;text-align:right;padding-right:14px;color:var(--faint);opacity:.65}',
    '.row.err{background:var(--red-wash)}.row.err .lno{color:var(--red);opacity:1}',
    '.errnote{height:22px;line-height:22px;padding-left:60px;font:12px/22px system-ui,-apple-system,sans-serif;color:var(--red);white-space:pre}',
    '.rec{height:30px;padding-top:4px;border-top:1px solid var(--hair)}.rec.first{border-top:0}.rec .lno{width:30px}',
    '.menu{position:absolute;z-index:7;min-width:220px;background:var(--ground);border-radius:10px;box-shadow:0 0 0 .5px rgba(0,0,0,.22),0 12px 30px -8px rgba(0,0,0,.35);',
    'padding:5px;font:13px system-ui,-apple-system,sans-serif;color:var(--ink)}',
    '.menu [data-a]{height:24px;display:flex;align-items:center;justify-content:space-between;padding:0 10px;border-radius:5px;gap:20px;white-space:nowrap}',
    '.menu [data-a]:hover{background:var(--accent);color:#fff}.menu [data-a]:hover .ks{color:#fff}',
    '.menu .sep{height:1px;margin:4px 6px;background:var(--hair)}.menu .ks{color:var(--faint);font-size:12px;font-family:ui-monospace,"SF Mono",Menlo,monospace}',
    '.thumb{position:absolute;z-index:8;width:64px;height:64px;border-radius:10px;background:#000 center/cover no-repeat;',
    'box-shadow:0 0 0 .5px rgba(0,0,0,.2),0 10px 24px -8px rgba(0,0,0,.4);pointer-events:none}',
    '[hidden]{display:none!important}',
  ].join('');

  var host = null, shadow = null, topEl, vp, rowsEl, menuEl, thumbEl, sheet = null;
  // The tree's rows now, or the broken text's lines; the text of whole JSON
  // is `textIndex` and needs no rows of its own.
  var rows = [], rowIndex = new Map(), rowH = 22, textIndex = null, rawIndex = null, indexing = 0;
  var drawn = { first: -1, last: -1 };

  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return c === '&' ? '&amp;' : c === '<' ? '&lt;' : c === '>' ? '&gt;' : '&quot;'; }); }
  function hl(s, on) {
    s = String(s);
    var q = S.q;
    if (!q) return esc(s);
    var low = s.toLowerCase(), f = q.toLowerCase(), out = '', a = 0, j;
    while ((j = low.indexOf(f, a)) >= 0) {
      out += esc(s.slice(a, j)) + '<mark' + (on ? ' class="on"' : '') + '>' + esc(s.slice(j, j + f.length)) + '</mark>';
      a = j + f.length;
    }
    return out + esc(s.slice(a));
  }
  function shut(n, depth) {
    var f = S.folds.get(n);
    return f === undefined ? depth >= S.foldDepth : f;
  }
  function setFold(n, p, folded) {
    if ((p.length >= S.foldDepth) === folded) { S.folds.delete(n); S.foldPaths.delete(n); }
    else { S.folds.set(n, folded); S.foldPaths.set(n, p); }
  }

  // ---- the rows ----

  // The tree as the rows it shows now: each value a row, and each opened
  // box's end one more. A row knows its parent's row, so its path is read
  // back up when it is wanted, not made for every row.
  function treeRows() {
    var out = [];
    rowIndex = new Map();
    function walk(n, k, up, d, last, dup, idx) {
      var box = isBox(n), folded = box && n.v.length > 0 && shut(n, d);
      var at = out.length;
      rowIndex.set(n, at);
      out.push({ n: n, k: k, up: up, d: d, last: last, dup: dup, idx: idx, shut: folded, box: box });
      if (box && !folded && n.v.length) {
        var L = n.v.length;
        if (n.t === 'o') for (var i = 0; i < L; i++) walk(n.v[i].v, n.v[i].k, at, d + 1, i === L - 1, n.v[i].d, false);
        else for (var j = 0; j < L; j++) walk(n.v[j], j, at, d + 1, j === L - 1, false, true);
        out.push({ close: true, n: n, d: d, last: last, up: at });
      }
    }
    walk(data, null, -1, 0, true, false, false);
    return out;
  }
  function rowPath(i) {
    var r = rows[i];
    if (!r || r.close || S.shown !== 'tree' || ndjson) return null;
    var p = [];
    while (r && r.up >= 0) { p.unshift(r.k); r = rows[r.up]; }
    return p;
  }

  function lineText(i) {
    if (error) return raw.slice(rawIndex.starts[i], rawIndex.ends[i]);
    return '  '.repeat(textIndex.depths[i]) + Core.compact(raw.slice(textIndex.starts[i], textIndex.ends[i]));
  }

  // The text of whole JSON indexed a slice at a time, behind the first
  // screen: never a long task on the page's thread.
  function indexOn() {
    if (!textIndex || textIndex.done || indexing) return;
    indexing = setTimeout(function () {
      indexing = 0;
      if (!textIndex || textIndex.done) return;
      textIndex.more(6e6);
      if (S.shown === 'text' && host && host.isConnected) refit(false);
      indexOn();
    }, 0);
  }

  function layout() {
    rowH = ndjson && S.shown === 'tree' ? 30 : 22;
    if (S.shown === 'tree') { rows = ndjson ? records : treeRows(); return; }
    rows = [];
    if (error) {
      rawIndex = rawIndex || Core.plainLines(raw);
      for (var i = 0; i < rawIndex.n; i++) {
        rows.push({ line: i });
        if (i + 1 === error.line) rows.push({ note: true });
      }
      return;
    }
    if (!textIndex) {
      textIndex = Core.indexer(raw, from);
      textIndex.more(3e6);
    }
    indexOn();
  }
  function count() {
    if (S.shown === 'text' && !error) return textIndex ? textIndex.n : 0;
    return rows.length;
  }

  // ---- drawing a row ----

  function sumWords(n) {
    var c = n.v.length;
    return c.toLocaleString('en-US') + (n.t === 'a' ? (c === 1 ? ' item' : ' items') : (c === 1 ? ' key' : ' keys'));
  }
  function leafHTML(n, on) {
    if (n.t === 's') {
      var v = n.v, sw = Core.swatch(n), body;
      if (v.length > 200 && !S.more.has(n)) {
        body = '<span class="s">"' + hl(Core.oneLine(v.slice(0, 200)), on) + '…"</span><span class="more" data-more>+' + (v.length - 200).toLocaleString('en-US') + ' more</span>';
      } else if (/^https?:\/\/\S+$/.test(v)) {
        body = '<a class="s lnk" href="' + esc(v) + '" data-link>"' + hl(v, on) + '"</a>';
      } else {
        body = '<span class="s">"' + hl(Core.oneLine(v), on) + '"</span>';
      }
      return (sw ? '<span class="sw" style="background:' + esc(sw) + '"></span>' : '') + body;
    }
    return '<span class="' + (n.t === 'n' ? 'n' : 'l') + '">' + hl(n.v, on) + '</span>';
  }
  function current() { return S.hit >= 0 ? S.hits[S.hit] : null; }
  function treeRowHTML(r, i) {
    var pad = '<span class="ind" style="width:' + (r.d * 16) + 'px"></span>';
    if (r.close) return '<div class="row">' + pad + '<span class="tw"></span><span class="p">' + (r.n.t === 'a' ? ']' : '}') + (r.last ? '' : ',') + '</span></div>';
    var hit = current(), on = !!hit && hit.node === r.n;
    var keyH = r.k === null || r.idx ? '' : '<span class="k">"' + hl(Core.oneLine(r.k), on) + '"</span><span class="p">: </span>';
    var comma = '<span class="p">' + (r.last ? '' : ',') + '</span>';
    var html;
    if (r.box) {
      var n = r.n.v.length, open = r.n.t === 'a' ? '[' : '{', close = r.n.t === 'a' ? ']' : '}';
      var tw = n ? '<span class="tw' + (r.shut ? ' shut' : '') + '" data-tw>' + CHEV + '</span>' : '<span class="tw"></span>';
      if (!n) html = tw + keyH + '<span class="p">' + open + close + '</span>' + comma;
      else if (r.shut) html = tw + keyH + '<span class="p">' + open + ' … ' + close + '</span>' + comma + '<span class="sum">' + sumWords(r.n) + '</span>';
      else html = tw + keyH + '<span class="p">' + open + '</span>';
    } else {
      var h = Core.hint(r.n, r.idx ? null : r.k, Date.now());
      html = '<span class="tw"></span>' + keyH + leafHTML(r.n, on) + comma + (h ? '<span class="hintw">' + esc(h) + '</span>' : '');
    }
    if (r.dup) html += '<span class="dup">duplicate key</span>';
    return '<div class="row' + (S.sel === r.n ? ' sel' : '') + '" data-i="' + i + '">' + pad + html + '</div>';
  }

  // A line of text, colored as the tree is: a string before a colon is a key.
  function colorLine(line, on) {
    var out = '', k = 0, L = line.length;
    while (k < L) {
      var c = line.charAt(k);
      if (c === '"') {
        var q = k + 1;
        while (q < L) { var d = line.charAt(q); if (d === '\\') { q += 2; continue; } if (d === '"') break; q++; }
        var tok = line.slice(k, q + 1), after = line.charAt(q + 1);
        out += '<span class="' + (after === ':' ? 'k' : 's') + '">' + hl(tok, on) + '</span>';
        k = q + 1;
        continue;
      }
      var m = /^(-?\d[\d.eE+-]*|true|false|null)/.exec(line.slice(k, k + 400));
      if (m && (k === 0 || /[\s\[{:,]/.test(line.charAt(k - 1)))) {
        out += '<span class="' + (/^[-\d]/.test(m[1]) ? 'n' : 'l') + '">' + hl(m[1], on) + '</span>';
        k += m[1].length;
        continue;
      }
      var j = k + 1;
      while (j < L && line.charAt(j) !== '"' && !/[-\dtfn]/.test(line.charAt(j))) j++;
      var part = line.slice(k, j);
      out += /^\s+$/.test(part) ? part : '<span class="p">' + hl(part, on) + '</span>';
      k = j;
    }
    return out;
  }
  function textRowHTML(i) {
    var hit = current();
    if (error) {
      var r = rows[i];
      if (r.note) return '<div class="errnote">' + esc(error.message + ', column ' + error.col) + '</div>';
      var bad = r.line + 1 === error.line;
      return '<div class="row' + (bad ? ' err' : '') + '"><span class="lno">' + (r.line + 1) + '</span>' + hl(lineText(r.line), !!hit && hit.line === r.line) + '</div>';
    }
    return '<div class="row"><span class="lno">' + (i + 1) + '</span>' + colorLine(lineText(i), !!hit && hit.line === i) + '</div>';
  }
  function recordHTML(r, i) {
    var hit = current(), on = !!hit && hit.line === i;
    var body = r.node ? colorLine(Core.inline(r.node), on) : hl(r.text, on);
    return '<div class="row rec' + (i ? '' : ' first') + '"><span class="lno">' + (i + 1) + '</span>' + body + '</div>';
  }
  function rowHTML(i) {
    if (S.shown === 'tree') return ndjson ? recordHTML(rows[i], i) : treeRowHTML(rows[i], i);
    return textRowHTML(i);
  }

  // ---- the window over the rows ----

  // Past this the page's height is a scale of the rows' (WebKit lays out
  // up to some 33 million points).
  var CAP = 15e6;
  function vpTop() { return vp.getBoundingClientRect().top + scrollY; }
  function geometry() {
    var n = count(), total = n * rowH, scaled = total > CAP;
    return { n: n, height: scaled ? CAP : total, scaled: scaled };
  }
  function draw(force) {
    if (!host || !host.isConnected) return;
    var g = geometry(), view = innerHeight, y = scrollY - vpTop();
    var exact;
    if (!g.scaled) exact = y / rowH;
    else exact = Math.min(1, Math.max(0, y / Math.max(1, g.height - view))) * Math.max(0, g.n - view / rowH);
    var first = Math.max(0, Math.floor(exact) - 30);
    var last = Math.min(g.n, Math.ceil(exact + view / rowH) + 30);
    var top = g.scaled ? y - (exact - first) * rowH : first * rowH;
    if (!force && first === drawn.first && last === drawn.last) {
      if (g.scaled) rowsEl.style.top = top + 'px';
      return;
    }
    var html = '';
    for (var i = first; i < last; i++) html += rowHTML(i);
    rowsEl.innerHTML = html;
    rowsEl.style.top = top + 'px';
    rowsEl.className = 'rows' + (S.shown === 'text' ? ' lines' : '');
    drawn.first = first;
    drawn.last = last;
  }
  function refit(force) {
    vp.style.height = geometry().height + 'px';
    draw(force !== false);
  }
  function rowY(i) {
    var g = geometry();
    if (!g.scaled) return vpTop() + i * rowH;
    return vpTop() + (i / Math.max(1, g.n - innerHeight / rowH)) * (g.height - innerHeight);
  }
  function center(i) {
    window.scrollTo({ top: Math.max(0, rowY(i) - innerHeight / 2 + rowH / 2), behavior: 'instant' });
    draw(true);
  }
  function nearest(i) {
    var y = rowY(i), view = innerHeight;
    if (y < scrollY + 8) window.scrollTo({ top: Math.max(0, y - 8), behavior: 'instant' });
    else if (y + rowH > scrollY + view - 8) window.scrollTo({ top: y + rowH - view + 8, behavior: 'instant' });
    draw(true);
  }

  function build() {
    host = document.createElement('yab-json');
    shadow = host.attachShadow({ mode: 'closed' });
    shadow.innerHTML = '<style>' + CSS + '</style><div class="top"></div><div class="vp"><div class="rows"></div></div>' +
      '<div class="menu" hidden></div><div class="thumb" hidden></div>';
    topEl = shadow.querySelector('.top');
    vp = shadow.querySelector('.vp');
    rowsEl = shadow.querySelector('.rows');
    menuEl = shadow.querySelector('.menu');
    thumbEl = shadow.querySelector('.thumb');
    if (skipped) topEl.innerHTML = '<div class="skip">Yab skipped <code>' + esc(skipped.text) + '</code> before the JSON.</div>';
    // The body WebKit made stays, hidden, for agents and extensions; the
    // canvas around the viewer is its ground, light or dark.
    sheet = new CSSStyleSheet();
    sheet.replaceSync('html{color-scheme:light dark;background:#fff}body{display:none!important}' +
      '@media (prefers-color-scheme:dark){html{background:#1c1c1c}}');
    listen();
  }

  // Shows the document as `mode`: tree, text, or as it was sent.
  function show(mode) {
    if (mode === 'tree' && !data && !ndjson && !error) {
      // A big document read only now, when the tree is asked for.
      try {
        var read = Core.parse(raw, from);
        data = read.root;
        lines = read.lines;
        S.foldDepth = firstDepth();
      } catch (e) {
        var where = Core.place(raw, e.at || 0);
        error = { message: e.message, line: where.line, col: where.col };
      }
    }
    if (mode === 'tree' && error) mode = 'text';
    if (mode !== 'tree') { S.sel = null; S.selPath = null; }
    if (S.q) { S.hits = []; S.hit = -1; }
    S.shown = mode;
    if (mode === 'sent') {
      if (host) host.remove();
      try { document.adoptedStyleSheets = document.adoptedStyleSheets.filter(function (s) { return s !== sheet; }); } catch (e) {}
    } else {
      if (!host) build();
      if (!host.isConnected) document.documentElement.appendChild(host);
      try { if (document.adoptedStyleSheets.indexOf(sheet) < 0) document.adoptedStyleSheets = document.adoptedStyleSheets.concat([sheet]); } catch (e) {}
      layout();
      drawn.first = -1;
      refit(true);
    }
    keep();
    tell();
  }

  function tell() {
    post({
      kind: 'state', shown: S.shown, pref: PREF, size: raw.length, big: big, plain: plainSent,
      ndjson: !!ndjson, skipped: skipped ? skipped.text : null,
      error: error ? { line: error.line, col: error.col, message: error.message } : null,
    });
  }

  // ---- folding ----

  // The rows again, the one at `anchor` (a node) kept where it stood.
  function relayout(anchor) {
    var before = anchor && rowIndex.has(anchor) ? rowY(rowIndex.get(anchor)) - scrollY : null;
    layout();
    vp.style.height = geometry().height + 'px';
    if (before !== null && rowIndex.has(anchor)) window.scrollTo({ top: rowY(rowIndex.get(anchor)) - before, behavior: 'instant' });
    draw(true);
    keep();
  }
  function foldAll(p, folded) {
    var n = nodeAt(p);
    if (!isBox(n)) return;
    (function w(x, q) {
      if (!isBox(x) || !x.v.length) return;
      setFold(x, q, folded);
      if (x.t === 'o') for (var i = 0; i < x.v.length; i++) w(x.v[i].v, q.concat([x.v[i].k]));
      else for (var j = 0; j < x.v.length; j++) w(x.v[j], q.concat([j]));
    })(n, p);
  }
  function toggle(p, deep) {
    var n = nodeAt(p);
    if (!isBox(n) || !n.v.length) return;
    var folded = !shut(n, p.length);
    if (deep) foldAll(p, folded); else setFold(n, p, folded);
    relayout(n);
  }
  function expandAll() {
    if (S.shown !== 'tree' || ndjson) return;
    S.foldDepth = Infinity;
    S.folds.clear();
    S.foldPaths.clear();
    relayout(S.sel);
  }
  function collapseAll() {
    S.foldDepth = 1;
    S.folds.clear();
    S.foldPaths.clear();
    relayout(data);
  }
  function opened(p) {
    var n = data;
    for (var j = 0; j < p.length && n; j++) {
      if (isBox(n) && shut(n, j)) setFold(n, p.slice(0, j), false);
      n = Core.child(n, p[j]);
    }
  }

  // ---- choosing a row ----

  function select(p) {
    S.selPath = p;
    S.sel = p ? nodeAt(p) : null;
    draw(true);
  }

  // ---- find ----

  var LIMIT = 100000;
  function search(q) {
    S.q = q;
    S.hits = [];
    S.capped = false;
    if (!q) return;
    var f = q.toLowerCase();
    if (S.shown === 'tree' && !ndjson) {
      var p = [];
      (function w(n, k, idx) {
        if (S.hits.length >= LIMIT) { S.capped = true; return; }
        var mine = (!idx && typeof k === 'string' && k.toLowerCase().indexOf(f) >= 0) ||
          (!isBox(n) && String(n.v).toLowerCase().indexOf(f) >= 0);
        if (mine) S.hits.push({ node: n, p: p.slice() });
        if (n.t === 'o') for (var i = 0; i < n.v.length; i++) { p.push(n.v[i].k); w(n.v[i].v, n.v[i].k, false); p.pop(); }
        else if (n.t === 'a') for (var j = 0; j < n.v.length; j++) { p.push(j); w(n.v[j], j, true); p.pop(); }
      })(data, null, true);
      // Every box on the way to a match opened, the first two thousand;
      // past that, each as its match comes up.
      for (var h = 0; h < Math.min(S.hits.length, 2000); h++) opened(S.hits[h].p);
      relayout(S.sel || data);
      return;
    }
    if (S.shown === 'text' && !error && textIndex) textIndex.more();
    var n = count();
    for (var i = 0; i < n; i++) {
      var t;
      if (ndjson && S.shown === 'tree') t = rows[i].node ? Core.inline(rows[i].node) : rows[i].text;
      else if (error) { if (rows[i].note) continue; t = lineText(rows[i].line); }
      else t = lineText(i);
      if (t.toLowerCase().indexOf(f) >= 0) {
        S.hits.push({ line: error ? rows[i].line : i, row: i });
        if (S.hits.length >= LIMIT) { S.capped = true; break; }
      }
    }
  }
  function reveal() {
    var hit = current();
    if (!hit) { draw(true); return; }
    if (hit.node) {
      if (!rowIndex.has(hit.node)) { opened(hit.p); relayout(S.sel || data); }
      center(rowIndex.get(hit.node) || 0);
    } else {
      center(hit.row);
    }
  }
  function answer() { return { index: S.hit, total: S.hits.length, capped: S.capped }; }
  function find(op, needle, forward) {
    if (op === 'close') { S.q = ''; S.hits = []; S.hit = -1; draw(true); return {}; }
    if (op === 'pause') return answer();
    if (op === 'step') {
      if (!S.hits.length) return answer();
      S.hit = (S.hit + (forward === false ? -1 : 1) + S.hits.length) % S.hits.length;
      reveal();
      return answer();
    }
    var q = String(needle || '').trim();
    var was = current();
    if (q !== S.q || op === 'find') search(q);
    S.hit = S.hits.length ? 0 : -1;
    if (op !== 'find' && was) {
      for (var i = 0; i < S.hits.length; i++) {
        if ((was.node && S.hits[i].node === was.node) || (was.line !== undefined && S.hits[i].line === was.line)) { S.hit = i; break; }
      }
    }
    if (op === 'find') reveal(); else draw(true);
    return answer();
  }

  // ---- copying ----

  function copyText(text) { post({ kind: 'copy', text: text }); }
  function wholeText() {
    if (ndjson) return raw;
    if (data) return Core.pretty(data);
    return raw;
  }

  // ---- the row's menu ----

  function closeMenu() { if (menuEl) { menuEl.hidden = true; menuEl.innerHTML = ''; } }
  function openMenu(p, x, y) {
    var n = nodeAt(p), link = n && n.t === 's' && /^https?:\/\/\S+$/.test(n.v);
    var items = [];
    if (link) items.push('<div data-a="tab">Open Link in New Tab</div><div class="sep"></div>');
    items.push('<div data-a="value">Copy Value</div>');
    items.push('<div data-a="path">Copy Path <span class="ks">' + esc(Core.pathText(p)) + '</span></div>');
    if (p.length) items.push('<div data-a="key">Copy Key</div>');
    items.push('<div data-a="jq">Copy as jq <span class="ks">' + esc(Core.jq(p)) + '</span></div>');
    if (isBox(n) && n.v.length) items.push('<div class="sep"></div><div data-a="expand">Expand All Below</div><div data-a="collapse">Collapse All Below</div>');
    menuEl.innerHTML = items.join('');
    menuEl.hidden = false;
    var box = host.getBoundingClientRect();
    var w = menuEl.offsetWidth, h = menuEl.offsetHeight;
    var left = Math.min(x - box.left, document.documentElement.clientWidth - box.left - w - 8);
    var top = y - box.top;
    if (y + h > innerHeight - 6) top -= h;
    menuEl.style.left = Math.max(4, left) + 'px';
    menuEl.style.top = Math.max(4, top) + 'px';
    menuEl.dataset.p = JSON.stringify(p);
  }
  function act(a, p) {
    var n = nodeAt(p);
    if (!n) return null;
    var text = null;
    if (a === 'value') text = Core.plain(n);
    else if (a === 'path') text = Core.pathText(p);
    else if (a === 'key') text = String(p[p.length - 1]);
    else if (a === 'jq') text = Core.jq(p);
    else if (a === 'tab') post({ kind: 'open', url: n.v });
    else if (a === 'expand') { foldAll(p, false); relayout(n); }
    else if (a === 'collapse') { foldAll(p, true); relayout(n); }
    if (text !== null) copyText(text);
    return text;
  }

  // ---- keys and the pointer ----

  function inTree() { return !!(host && host.isConnected && S.shown === 'tree' && !ndjson && data); }
  function press(e) {
    var meta = e.metaKey || e.ctrlKey;
    if (meta && !e.altKey && !e.shiftKey && (e.key === 'c' || e.key === 'C')) {
      if (String(document.getSelection() || '')) return false;
      copyText(inTree() && S.sel ? Core.plain(S.sel) : wholeText());
      return true;
    }
    if (meta || !inTree()) return false;
    if (e.key === 'Escape') {
      if (menuEl && !menuEl.hidden) { closeMenu(); return true; }
      if (!S.sel) return false;
      select(null);
      return true;
    }
    var at = S.sel && rowIndex.has(S.sel) ? rowIndex.get(S.sel) : -1;
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      if (at < 0 || e.altKey) return false;
      var step = e.key === 'ArrowDown' ? 1 : -1, i = at + step;
      while (i >= 0 && i < rows.length && rows[i].close) i += step;
      if (i < 0 || i >= rows.length) return true;
      select(rowPath(i));
      nearest(i);
      return true;
    }
    if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
      var p = at >= 0 ? rowPath(at) : [];
      var node = nodeAt(p), open = e.key === 'ArrowRight';
      if (e.altKey) {
        if (at < 0) { if (open) expandAll(); else collapseAll(); }
        else { foldAll(p, !open); relayout(node); }
        return true;
      }
      if (at < 0) return false;
      var box = isBox(node) && node.v.length > 0;
      if (open) { if (box && shut(node, p.length)) toggle(p, false); }
      else if (box && !shut(node, p.length) && p.length) toggle(p, false);
      else if (p.length) { select(p.slice(0, -1)); nearest(rowIndex.get(S.sel)); }
      return true;
    }
    return false;
  }

  function rowOf(target) {
    var row = target && target.closest ? target.closest('.row[data-i]') : null;
    return row ? +row.getAttribute('data-i') : -1;
  }
  function hideThumb() { thumbEl.hidden = true; thumbEl.style.backgroundImage = ''; }

  function listen() {
    window.addEventListener('scroll', function () { draw(false); }, { passive: true });
    window.addEventListener('resize', function () { draw(true); });
    window.addEventListener('keydown', function (e) {
      if (!host || !host.isConnected || e.defaultPrevented) return;
      if (press(e)) e.preventDefault();
    });
    shadow.addEventListener('mousedown', function (e) {
      if (e.button !== 0) return;
      if (!menuEl.hidden && !e.target.closest('.menu')) closeMenu();
      var tw = e.target.closest('[data-tw]');
      if (!tw) return;
      e.preventDefault();
      var p = rowPath(rowOf(tw));
      if (p) { select(p); toggle(p, e.altKey); }
    });
    shadow.addEventListener('click', function (e) {
      if (e.target.closest('.menu')) {
        var a = e.target.closest('[data-a]');
        if (a) { act(a.getAttribute('data-a'), JSON.parse(menuEl.dataset.p || '[]')); closeMenu(); }
        return;
      }
      var i = rowOf(e.target);
      if (i < 0 || !inTree()) return;
      var p = rowPath(i);
      if (!p) return;
      if (e.target.closest('[data-more]')) { S.more.add(rows[i].n); draw(true); return; }
      // A link goes where it points, here or, with ⌘, in a new tab: the
      // browser's own way, as any link.
      if (e.target.closest('[data-link]')) return;
      if (String(document.getSelection() || '')) return;
      select(p);
    });
    shadow.addEventListener('contextmenu', function (e) {
      var i = rowOf(e.target);
      if (i < 0 || !inTree()) return;
      var p = rowPath(i);
      if (!p) return;
      e.preventDefault();
      select(p);
      openMenu(p, e.clientX, e.clientY);
    });
    document.addEventListener('mousedown', function (e) {
      if (menuEl && !menuEl.hidden && e.target !== host) closeMenu();
    });
    // A picture behind a link, only while the pointer is on it: nothing is
    // asked of its server before.
    shadow.addEventListener('mouseover', function (e) {
      var a = e.target.closest('[data-link]');
      if (!a) { hideThumb(); return; }
      var url = a.getAttribute('href');
      if (!/avatar|\.(png|jpe?g|gif|webp|svg|avif)(\?|#|$)/i.test(url)) return;
      var r = a.getBoundingClientRect(), box = host.getBoundingClientRect();
      thumbEl.style.backgroundImage = 'url("' + url.replace(/"/g, '%22') + '")';
      thumbEl.style.left = Math.min(r.right - box.left + 8, document.documentElement.clientWidth - box.left - 72) + 'px';
      thumbEl.style.top = Math.max(4, r.top - box.top - 20) + 'px';
      thumbEl.hidden = false;
    });
    shadow.addEventListener('mouseout', function (e) {
      if (e.target.closest && e.target.closest('[data-link]')) hideThumb();
    });
    // Back to a page the cache kept: the tab hears again what it is.
    window.addEventListener('pageshow', function (e) { if (e.persisted) tell(); });
  }

  // ======================================================================
  // What yab asks of it (JSONView.swift), and the bench.
  // ======================================================================
  function rowText(i) {
    var d = document.createElement('div');
    d.innerHTML = rowHTML(i);
    return d.textContent;
  }

  window.__yabJSON = {
    finds: function () { return !!(host && host.isConnected && S.shown !== 'sent'); },
    find: find,
    command: function (c) {
      c = c || {};
      switch (c.do) {
        case 'mode': show(c.to); return S.shown;
        case 'expand': expandAll(); return true;
        case 'collapse': collapseAll(); return true;
        case 'copy': return wholeText();
        case 'raw': return raw;
        case 'reveal':
          if (!error || S.shown === 'sent') return false;
          if (S.shown !== 'text') show('text');
          for (var i = 0; i < rows.length; i++) if (rows[i].line + 1 === error.line) { center(i); break; }
          return true;
        case 'state': tell(); return S.shown;
        // The bench: what is drawn and chosen, and the hands' own ways in.
        case 'bench':
          if (c.finish && textIndex) textIndex.more();
          var n = host && host.isConnected ? count() : 0;
          var out = { shown: S.shown, pref: PREF, error: error, big: big, plain: plainSent, ndjson: !!ndjson,
            skipped: skipped ? skipped.text : null, rows: n, indexed: !textIndex || textIndex.done,
            sel: S.selPath ? Core.pathText(S.selPath) : null, hits: S.hits.length, hit: S.hit,
            scrollY: scrollY, drawnFirst: drawn.first, drawnLast: drawn.last, menu: menuEl ? !menuEl.hidden : false,
            host: !!(host && host.isConnected), bodyHidden: getComputedStyle(document.body).display === 'none',
            keys: data && data.t === 'o' ? data.v.map(function (x) { return x.k; }) : null,
            dark: matchMedia('(prefers-color-scheme: dark)').matches };
          var from = c.from || 0, texts = [];
          for (var j = from; j < Math.min(n, from + (c.lines || 40)); j++) texts.push(rowText(j));
          out.lines = texts;
          if (c.dom && rowsEl) {
            out.dom = [].map.call(rowsEl.querySelectorAll('.row,.errnote'), function (el) {
              var r = el.getBoundingClientRect(), cs = getComputedStyle(el), tw = el.querySelector('[data-tw]');
              var t = tw ? tw.getBoundingClientRect() : null;
              return { text: el.textContent, cls: el.className, marks: el.querySelectorAll('mark').length,
                on: el.querySelectorAll('mark.on').length, h: r.height, y: r.top + r.height / 2, x: r.left + 120,
                tw: t ? [t.left + t.width / 2, t.top + t.height / 2] : null, bg: cs.backgroundColor };
            });
            out.colors = {};
            ['k', 's', 'n', 'l'].forEach(function (k) { var el = rowsEl.querySelector('.' + k); if (el) out.colors[k] = getComputedStyle(el).color; });
            out.ground = host ? getComputedStyle(host).backgroundColor : '';
          }
          return out;
        case 'press':
          return press({ key: c.key, altKey: !!c.alt, metaKey: !!c.meta, ctrlKey: false, shiftKey: !!c.shift });
        case 'click':
          var p = c.path || [];
          if (c.twisty) toggle(p, !!c.alt); else select(p);
          return pk(p);
        case 'menu':
          var mp = c.path || [];
          if (c.open) {
            var mi = rowIndex.get(nodeAt(mp)), r0 = rowsEl.querySelector('[data-i="' + mi + '"]');
            var rr = r0 ? r0.getBoundingClientRect() : { left: 40, top: 40 };
            select(mp);
            openMenu(mp, rr.left + 160, rr.top + 11);
            return menuEl.textContent;
          }
          closeMenu();
          return act(c.item, mp);
        case 'more':
          S.more.add(nodeAt(c.path || []));
          draw(true);
          return true;
        case 'scroll':
          if (typeof c.row === 'number') center(c.row);
          else if (c.path) { opened(c.path); relayout(S.sel || data); center(rowIndex.get(nodeAt(c.path)) || 0); }
          return scrollY;
      }
      return null;
    },
  };

  show(S.shown);
})();
