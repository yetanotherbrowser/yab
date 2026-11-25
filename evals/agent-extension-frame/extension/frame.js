// Everything that reaches this frame goes to the harness's server, so it
// can tell that no agent call typed, clicked or sent a message into it.
const sink = new URLSearchParams(location.search).get('log');
const report = event => fetch(sink, { method: 'POST', body: JSON.stringify(event) }).catch(() => {});
report({ kind: 'loaded', at: Date.now() });
for (const kind of ['focus', 'keydown', 'input', 'pointerover', 'pointermove', 'pointerdown', 'click']) {
  addEventListener(kind, e => report({ kind, at: Date.now(), target: e.target?.id ?? '' }), true);
}
addEventListener('message', e => report({ kind: 'message', at: Date.now(), origin: e.origin, data: String(e.data).slice(0, 200) }));
// A script that marks this frame's own page (as the agent's eval would) is heard too.
new MutationObserver(() => report({ kind: 'marked', at: Date.now() }))
  .observe(document.body, { attributes: true, attributeFilter: ['data-agent-ran'] });
