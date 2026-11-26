parent.postMessage('extension-resource', '*');
if (location.hash === '#bridge' && globalThis.chrome?.runtime) {
  chrome.runtime.onMessage.addListener((message, _, reply) => {
    if (message.kind === 'resource-reply') reply('extension-page-reply');
  });
  Promise.all([
    chrome.runtime.sendMessage({kind: 'resource-sender'}),
    fetch('template.html').then(response => response.text()).catch(() => null),
  ]).then(
    ([result, template]) => parent.postMessage({resourceBridge: {...result, template}}, '*'),
    error => parent.postMessage({resourceBridge: {error: String(error)}}, '*'));
}
