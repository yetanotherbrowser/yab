// A page leaving for another document is not taken back by a reload of
// the page it is on that nobody asked for (feedback #172, OpenAI's sign-in,
// 2026-10-19).
//
// "Continue" on platform.openai.com sets location to auth.openai.com, and
// 4 to 8 ms later WebKit starts a reload of the login page itself, with no
// script on the stack and no call from the app, which cancels the other
// site's load (-999): the page came back as the same empty form. A bare
// WKWebView does the same, so Safari does too; Chrome goes on to the other
// site. The page is a React 19 app on the Navigation API, and the reload
// arrives through it as a "navigate" event of type "reload".
//
// So a reload of this address that no script and no person asked for,
// coming within moments of the page starting to leave, is cancelled, and
// the load it would have stopped goes on.
(function () {
  var nav = window.navigation;
  if (!nav || typeof NavigateEvent !== 'function') return;
  // The stray reload comes 4 to 8 ms after the page starts to leave.
  var MOMENTS = 500;
  var intercepted = new WeakSet();
  var intercept = NavigateEvent.prototype.intercept;
  if (typeof intercept === 'function') {
    NavigateEvent.prototype.intercept = function () {
      intercepted.add(this);
      return intercept.apply(this, arguments);
    };
  }
  var leaving = null;
  var since = 0;
  // Asked for in this document: the event its own call fires comes while
  // the call is still on the stack.
  var asked = 0;
  ['navigate', 'reload'].forEach(function (name) {
    var own = nav[name];
    if (typeof own !== 'function') return;
    nav[name] = function () {
      asked++;
      try { return own.apply(this, arguments); } finally { asked--; }
    };
  });
  function away(e) {
    return !!e && !e.defaultPrevented && !intercepted.has(e) && !e.hashChange && e.downloadRequest == null;
  }
  nav.addEventListener('navigate', function (e) {
    if (e.navigationType === 'reload' && e.cancelable && !e.userInitiated && !asked &&
        e.destination.url === location.href && Date.now() - since < MOMENTS && away(leaving)) {
      e.preventDefault();
      return;
    }
    // pushState and replaceState fire these too, but the page stays put, so
    // its own reload right after (a marker in the URL, then reload) goes on.
    if ((e.navigationType === 'push' || e.navigationType === 'replace') && !e.destination.sameDocument) {
      leaving = e;
      since = Date.now();
    }
  });
  nav.addEventListener('navigatesuccess', function () { leaving = null; });
  // A cached document keeps the departure that put it in the cache. That
  // request is no longer in flight when Back brings the document back.
  // Clear it before the application's pageshow handler can reload its view.
  window.addEventListener('pageshow', function (event) {
    if (event.persisted) { leaving = null; since = 0; }
  }, true);
})();
