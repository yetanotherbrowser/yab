// Saves as a clipper's popup does: a blob link clicked, then revoked at once.
document.addEventListener('click', event => {
  if (event.target instanceof HTMLAnchorElement) return;
  const url = URL.createObjectURL(new Blob(['# Popup save\n'], {type: 'text/markdown'}));
  const link = document.createElement('a');
  link.href = url;
  link.download = 'popup-save.md';
  document.body.append(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
});
