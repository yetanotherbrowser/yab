// Differential check for #706: runs the real PageReader.setup JavaScript,
// extracted from a PageReader.swift, over a local DOM fixture in jsdom.
// Usage: NODE_PATH=<dir with jsdom> node scripts/check-phone-reader-links.cjs <PageReader.swift> [<another PageReader.swift>]
// Prints what Reader shows for each file and exits 1 if a check fails on the
// first file given.
'use strict';
const fs = require('fs');
const { JSDOM } = require('jsdom');

function setupJS(swiftPath) {
  const swift = fs.readFileSync(swiftPath, 'utf8');
  const m = swift.match(/private static let setup = #"""\n([\s\S]*?)\n\s*"""#/);
  if (!m) throw new Error('no setup script in ' + swiftPath);
  // A Swift raw multiline string: no escapes; strip its 4-space indent.
  return m[1].split('\n').map(l => l.replace(/^ {4}/, '')).join('\n');
}

const prose = 'A long article carries useful prose that can be read locally while the original page keeps its own forms and listeners. '.repeat(4);
const fixture = `<!doctype html><title>Reader article</title><body><article id=article><h1>Reader article</h1>
<p>Sentence with <a href="/inline">linked words</a> and <a href="/styled"><em>styled link</em></a> inside. ${prose}</p>
<p>Away to <a href="https://elsewhere.example/x">outside words</a> and <a href="javascript:alert(1)">script words</a>. ${prose}</p>
${`<p>${prose}</p>`.repeat(8)}
<a href="/teaser"><div><p>Teaser card text that is a whole block inside one link.</p></div></a>
<div class="share">Share this boilerplate</div><nav>Nav boilerplate</nav><aside>Aside boilerplate</aside>
</article></body>`;

function run(swiftPath) {
  const dom = new JSDOM(fixture, { url: 'https://site.example/article', runScripts: 'outside-only', pretendToBeVisual: true });
  const w = dom.window;
  // What jsdom lacks and WebKit has; none of it decides what is copied.
  Object.defineProperty(w.HTMLElement.prototype, 'innerText', { get() { return this.textContent; } });
  w.matchMedia = () => ({ matches: false, addEventListener() {} });
  w.scrollTo = () => {};
  // Open, so the harness can read the reader's own root for old and new
  // files alike; the closed mode is not what is under test.
  const attach = w.Element.prototype.attachShadow;
  w.Element.prototype.attachShadow = function () { return attach.call(this, { mode: 'open' }); };
  w.eval(`(function(){ ${setupJS(swiftPath)} })()`);
  if (!w.__yabPhoneReader.enter()) throw new Error('reader did not enter for ' + swiftPath);
  return w.document.getElementById('yab-phone-reader').shadowRoot.querySelector('article').innerHTML;
}

function checks(html) {
  return [
    ['inline link text kept', html.includes('linked words')],
    ['same-origin href kept', html.includes('<a href="https://site.example/inline">linked words</a>')],
    ['link with inline child kept', html.includes('<a href="https://site.example/styled"><em>styled link</em></a>')],
    ['cross-origin text kept without href', html.includes('<a>outside words</a>')],
    ['javascript: text kept without href', html.includes('<a>script words</a>') && !html.includes('javascript:')],
    ['sentence reads whole', /Sentence with <a[^>]*>linked words<\/a> and/.test(html)],
    ['teaser card link dropped', !html.includes('Teaser card text')],
    ['class-named boilerplate dropped', !html.includes('Share this boilerplate')],
    ['nav and aside dropped', !html.includes('Nav boilerplate') && !html.includes('Aside boilerplate')],
  ];
}

let failed = false;
process.argv.slice(2).forEach((file, i) => {
  let html;
  try { html = run(file); } catch (e) { console.log(`${file}: ${e.message}`); if (i === 0) failed = true; return; }
  console.log(`\n== ${file}`);
  for (const [name, ok] of checks(html)) {
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}`);
    if (!ok && i === 0) failed = true;
  }
});
process.exit(failed ? 1 : 0);
