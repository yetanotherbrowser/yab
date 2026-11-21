import Foundation
import WebKit

/// The Mac's prose scoring, with a resource-free copy for the phone. The
/// original document remains in its own WebKit view and website store.
/// The copy wears the reading theme (ReaderThemes.swift, the Mac's six):
/// `look` is ReaderPrefs.payload and `margins` its side margins, sent on
/// entering and again whenever the theme changes (WebPool.restyleReaders).
@MainActor
enum PageReader {
    static let world = WKContentWorld.world(name: "yab.phone.reader")
    static let probe = setup + "return {available:window.__yabPhoneReader.readable(), enabled:window.__yabPhoneReader.on(), documentID:window.__yabPhoneReader.documentID, originalY:window.__yabPhoneReader.originalY()};"
    static let enter = setup + "if(location.href!==expectedURL || window.__yabPhoneReader.documentID!==expectedDocument)return false; window.__yabPhoneReader.theme(look, margins); return window.__yabPhoneReader.enter();"
    static let leave = setup + "if(location.href!==expectedURL || window.__yabPhoneReader.documentID!==expectedDocument)return false; var left=window.__yabPhoneReader.leave();if(left)await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return left;"
    static let restyle = setup + "window.__yabPhoneReader.theme(look, margins); return window.__yabPhoneReader.on();"

    /// The theme as the page takes it: `look` and `margins`, only numbers,
    /// booleans, checked colors and the fonts' own fixed names.
    static func arguments(_ prefs: ReaderPrefs) -> [String: Any] {
        let data = (try? JSONEncoder().encode(prefs.payload)) ?? Data("{}".utf8)
        let look = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ["look": look, "margins": prefs.look.margins]
    }

    private static let setup = #"""
    (function () {
      if (window.__yabPhoneReader) return;
      var now = null;
      var AROUND = /(^|\s)(comments?|reply|replies|sidebar|related|recommend\w*|footer|promo|newsletter|share|social|advert\w*|sponsor\w*)([\s_-]|$)/i;
      // With `inline`, as the copy asks: a link set in a sentence is part of
      // it (#706); a link that holds blocks is still a teaser card.
      var CARD = 'p,div,section,article,h1,h2,h3,h4,h5,h6,ul,ol,li,table,blockquote,pre,figure';
      function around(el, inline) {
        for (var up = el; up && up !== document.body && up !== document.documentElement; up = up.parentElement) {
          var tag = up.tagName;
          if (tag === 'ASIDE' || tag === 'NAV' || tag === 'FOOTER' || tag === 'DIALOG') return true;
          if (tag === 'A' && (!inline || up.querySelector(CARD))) return true;
          var role = up.getAttribute('role');
          if (role === 'complementary' || role === 'navigation' || role === 'dialog' || role === 'alertdialog') return true;
          var name = (typeof up.className === 'string' ? up.className : '') + ' ' + (up.id || '');
          if (name.length > 1 && AROUND.test(name)) return true;
        }
        return false;
      }

      // One pass over the paragraphs: each counts its prose toward every
      // element it sits in. textContent never asks for a layout, so this
      // is a couple of milliseconds on a long Wikipedia article.
      function visible(el) {
        for (var up=el; up; up=up.parentElement) {
          var style=getComputedStyle(up);
          if (style.display==='none' || style.visibility==='hidden' || style.visibility==='collapse' || parseFloat(style.opacity)===0) return false;
        }
        return true;
      }
      function measure() {
        var paragraphs = document.getElementsByTagName('p');
        var prose = new Map(), counts = new Map(), kept = [];
        for (var i = 0; i < paragraphs.length; i++) {
          var p = paragraphs[i];
          if (!visible(p)) continue;
          var letters = p.innerText.trim().length;
          if (letters < 25 || around(p)) continue;
          var linked = 0, links = p.getElementsByTagName('a');
          for (var k = 0; k < links.length; k++) linked += links[k].innerText.length;
          var own = letters - linked;
          // Mostly links is a list of them, set as a paragraph.
          if (own <= letters / 3) continue;
          kept.push({ p: p, letters: letters, own: own });
          for (var up = p.parentElement; up && up !== document.documentElement; up = up.parentElement) {
            prose.set(up, (prose.get(up) || 0) + own);
            counts.set(up, (counts.get(up) || 0) + 1);
          }
        }
        return { prose: prose, counts: counts, kept: kept };
      }

      // The article: the smallest element that still holds most of the
      // page's prose. From the body down, into whichever child holds four
      // fifths of what its parent does, until none does. A long article
      // split into sections stops at the sections' parent; a page whose
      // prose is spread over a feed stops high, and shows the lot.
      function best() {
        var m = measure(), top = document.body;
        if (!top || !m.prose.get(top)) return null;
        for (;;) {
          var whole = m.prose.get(top), next = null;
          for (var c = top.firstElementChild; c; c = c.nextElementSibling) {
            if ((m.prose.get(c) || 0) >= whole * 0.8) { next = c; break; }
          }
          if (!next || (m.counts.get(next) || 0) < 2) break;
          top = next;
        }
        return { el: top, prose: m.prose.get(top), paragraphs: m.counts.get(top) };
      }

      // Worth offering: at least three paragraphs side by side, each on its
      // own (a paragraph, or a box holding only it), carrying 1200 letters
      // of prose between them, and on screen. A feed's teasers sit in cards
      // with their headlines and don't count; an article's paragraphs do.
      function readable() {
        if (now) return true;
        var m = measure(), runs = new Map(), found = false;
        for (var i = 0; i < m.kept.length; i++) {
          var block = m.kept[i].p;
          while (block.parentElement && m.counts.get(block.parentElement) === 1) block = block.parentElement;
          if (block.textContent.length > m.kept[i].letters * 1.3 + 20) continue;
          var run = runs.get(block.parentElement) || { n: 0, prose: 0 };
          run.n++;
          run.prose += m.kept[i].own;
          runs.set(block.parentElement, run);
        }
        runs.forEach(function (run, parent) {
          if (found || run.n < 3 || run.prose < 1200) return;
          // A cookie notice's text is often there all along, hidden.
          if (parent.checkVisibility && !parent.checkVisibility()) return;
          found = true;
        });
        return found;
      }


      // Never clone an active node or its attributes. This creates no image,
      // media, frame, CSS or script request and copies no event handler.
      var allowed = new Set('ARTICLE SECTION DIV P H2 H3 H4 H5 H6 BLOCKQUOTE PRE CODE UL OL LI TABLE THEAD TBODY TFOOT TR TH TD STRONG EM B I U S SMALL SUP SUB BR HR FIGURE FIGCAPTION DL DT DD A SPAN'.split(' '));
      var blocked = new Set('SCRIPT STYLE LINK NOSCRIPT FORM NAV ASIDE FOOTER BUTTON INPUT SELECT TEXTAREA IFRAME FRAME OBJECT EMBED VIDEO AUDIO IMG PICTURE SOURCE TRACK CANVAS SVG MATH'.split(' '));
      function copy(node, budget) {
        if (++budget.nodes > 20000 || budget.letters > 400000) return null;
        if (node.nodeType === 3) {
          budget.letters += node.nodeValue.length;
          return document.createTextNode(node.nodeValue);
        }
        if (node.nodeType !== 1 || blocked.has(node.tagName) || node.tagName === 'H1' || around(node, true)) return null;
        if (node.getAttribute('aria-hidden') === 'true' || node.hidden || !visible(node)) return null;
        var tag = allowed.has(node.tagName) ? node.tagName.toLowerCase() : 'div';
        var out = document.createElement(tag);
        if (tag === 'a') {
          try {
            var url = new URL(node.getAttribute('href') || '', location.href);
            if ((url.protocol === 'http:' || url.protocol === 'https:') && url.origin === location.origin) out.setAttribute('href', url.href);
          } catch (_) {}
        }
        for (var child = node.firstChild; child; child = child.nextSibling) {
          var safe = copy(child, budget); if (safe) out.appendChild(safe);
        }
        return out;
      }
      // The theme's values (theme(), from Swift) on the reader's host;
      // the sheet below reads only these.
      var look = null, margins = 0, dark = matchMedia('(prefers-color-scheme: dark)');
      var css = [
        ':host{display:block!important;min-height:100vh;background:var(--bg,#fff);color:var(--ink,#171717);color-scheme:var(--scheme,light)}',
        'article{box-sizing:border-box;max-width:var(--w,38em);margin:0 auto;padding:24px var(--pad,24px) 80px;overflow-wrap:break-word;',
        'font-family:var(--f,ui-serif,Georgia,serif);font-size:var(--s,18px);line-height:var(--lh,1.72);font-weight:var(--wt,400);',
        'letter-spacing:var(--ls,0);word-spacing:var(--ws,0);text-align:var(--al,left)}',
        'article.just :is(p,li,blockquote){hyphens:auto;-webkit-hyphens:auto}',
        'h1{font:700 calc(var(--s,18px) * 1.6)/1.18 var(--f,ui-serif,Georgia,serif);letter-spacing:-0.015em;margin:0 0 12px;text-align:left}',
        '.site{font:500 13px/1.4 -apple-system,sans-serif;letter-spacing:0;word-spacing:0;opacity:.6;margin:0 0 32px;text-align:left}',
        'p{margin:0 0 1.35em}h2,h3,h4,h5,h6{font-family:inherit;font-weight:700;line-height:1.3;margin:1.5em 0 .6em;text-align:left}',
        'h2{font-size:1.3em}h3{font-size:1.15em}h4,h5,h6{font-size:1em}',
        'a{color:inherit;text-underline-offset:3px}pre,code{font:14px/1.6 ui-monospace,monospace;letter-spacing:0;word-spacing:0}',
        'pre{white-space:pre-wrap;padding:14px;background:color-mix(in srgb,var(--ink,#171717) 6%,transparent);border-radius:8px;text-align:left}',
        'blockquote{margin:1.5em 0;padding-left:1em;border-left:2px solid color-mix(in srgb,var(--ink,#171717) 22%,transparent);opacity:.85}',
        'table{display:block;overflow:auto;border-collapse:collapse}td,th{padding:6px;border:1px solid color-mix(in srgb,var(--ink,#171717) 18%,transparent)}',
        '::selection{background:var(--ink,#171717);color:var(--bg,#fff)}'
      ].join('');
      function ground() {
        if (!look) return { bg: '#ffffff', ink: '#171717', dark: false };
        var night = look.mode === 'dark' || (look.mode === 'auto' && dark.matches);
        return night ? look.night : look.day;
      }
      // Each value set on its own, so a site's face is a value and never
      // part of a sheet's text.
      function dress() {
        if (!now) return;
        var g = ground(), host = now.host.style;
        host.setProperty('--bg', g.bg); host.setProperty('--ink', g.ink);
        host.setProperty('--scheme', g.dark ? 'dark' : 'light');
        now.style.textContent = 'html:has(> #yab-phone-reader){height:auto!important;min-height:0!important;overflow:visible!important;scroll-behavior:auto!important;scroll-snap-type:none!important;transform:none!important;filter:none!important;background:' + g.bg + '!important}';
        if (!look) return;
        host.setProperty('--f', look.font || now.face || 'ui-serif,Georgia,serif');
        host.setProperty('--s', look.size + 'px'); host.setProperty('--lh', String(look.line));
        host.setProperty('--wt', String(look.weight));
        host.setProperty('--ls', look.letter + 'em'); host.setProperty('--ws', look.word + 'em');
        host.setProperty('--al', look.justify ? 'justify' : 'left');
        host.setProperty('--w', look.width + 'em');
        // A phone's column is the screen: margins widen or narrow its sides.
        host.setProperty('--pad', 'max(10px, calc(24px + ' + (margins * 0.3) + 'vw))');
        now.article.classList.toggle('just', !!look.justify);
      }
      function theme(value, sides) {
        look = value && typeof value === 'object' ? value : null;
        margins = typeof sides === 'number' && isFinite(sides) ? Math.max(-30, Math.min(30, sides)) : 0;
        dress();
      }
      dark.addEventListener('change', function () { if (now && look && look.mode === 'auto') dress(); });
      function on() { return !!now && now.host.isConnected && now.body === document.body; }
      function leave() {
        if (!now) return false;
        var old = now; now = null;
        old.host.remove(); old.style.remove();
        if (old.bodyStyle === null) old.body.removeAttribute('style');
        else old.body.setAttribute('style', old.bodyStyle);
        window.scrollTo({left:old.x, top:old.y, behavior:'instant'});
        return true;
      }
      function enter() {
        if (on()) return true;
        if (!readable()) return false;
        var found = best(), body = document.body;
        if (!found || !body) return false;
        var article = document.createElement('article');
        var title = document.createElement('h1');
        var originalTitle = found.el.querySelector('h1') || document.querySelector('h1');
        title.textContent = originalTitle ? originalTitle.textContent.trim() : document.title;
        article.appendChild(title);
        var site = document.createElement('p'); site.className='site'; site.textContent=location.hostname;
        article.appendChild(site);
        var clean = copy(found.el, {nodes:0, letters:0});
        if (!clean || clean.textContent.trim().length < 400) return false;
        article.appendChild(clean);
        var host = document.createElement('div');
        host.id='yab-phone-reader';
        host.style.setProperty('display','block','important');
        var shadow = host.attachShadow({mode:'closed'}), style = document.createElement('style');
        style.textContent=css; shadow.appendChild(style); shadow.appendChild(article);
        // A link is still an ordinary user navigation in this same page.
        shadow.addEventListener('click',function(e){var a=e.target.closest && e.target.closest('a[href]');if(a)leave();},true);
        var rootStyle = document.createElement('style');
        var prose = found.el.querySelector('p') || found.el;
        now={host:host,style:rootStyle,article:article,face:getComputedStyle(prose).fontFamily||'',body:body,bodyStyle:body.getAttribute('style'),x:window.scrollX,y:window.scrollY};
        dress();
        document.documentElement.appendChild(rootStyle); document.documentElement.appendChild(host);
        body.style.setProperty('display','none','important');
        window.scrollTo({left:0,top:0,behavior:'instant'});
        return true;
      }
      // html: what the closed reader shows, for tests in this isolated world.
      window.__yabPhoneReader={readable:readable,on:on,enter:enter,leave:leave,theme:theme,documentID:String(Date.now())+':'+String(Math.random()),originalY:function(){return on()?now.y:null;},html:function(){return on()?now.article.innerHTML:null;}};
    })();
    """#
}
