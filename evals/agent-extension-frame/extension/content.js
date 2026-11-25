// A password manager's frame on a page, in the two shapes they take:
// ?vault=hidden opens it on load at height 0 (1Password's sign-in frame),
// ?vault=focus opens a visible list under a field once one is focused.
// Like theirs, its host has a closed shadow root; &host=light puts the frame
// in the page's own tree instead, where a snapshot meets it.
const query = new URLSearchParams(location.search);
const mode = query.get('vault');
function open() {
  if (document.querySelector('vault-fixture')) return;
  const host = document.createElement('vault-fixture');
  const frame = document.createElement('iframe');
  frame.src = chrome.runtime.getURL('frame.html') + '?log=' + encodeURIComponent(location.origin + '/log');
  frame.style.cssText = mode === 'hidden'
    ? 'position:fixed;top:0;left:50%;width:100%;max-width:400px;height:0;border:0'
    : 'position:fixed;left:20px;top:140px;width:320px;height:160px;border:1px solid #888;z-index:2147483647';
  if (query.get('host') === 'light') {
    host.append(frame);
    document.body.append(host);
  } else {
    host.attachShadow({ mode: 'closed' }).append(frame);
    document.documentElement.append(host);
  }
}
// Ready: the harness takes its marks after this, so nothing earlier is missed.
fetch(location.origin + '/log', { method: 'POST', body: JSON.stringify({ kind: 'ready', at: Date.now(), href: location.href }) }).catch(() => {});
if (mode === 'hidden') open();
if (mode === 'focus') document.addEventListener('focusin', e => { if (e.target instanceof HTMLInputElement) open(); });
// The harness opens and closes it the way the extension would.
document.addEventListener('vault-fixture-open', open);
document.addEventListener('vault-fixture-close', () => document.querySelector('vault-fixture')?.remove());
