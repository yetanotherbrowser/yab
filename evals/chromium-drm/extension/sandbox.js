(async () => {
    const icon = new Image();
    icon.src = 'sandbox.svg';
    const image = icon.decode().then(() => true, () => false);
    const font = new FontFace('Fixture', 'url(sandbox.ttf)').load().then(() => true, () => false);
    const runtime = Boolean(globalThis.browser?.runtime?.id || globalThis.chrome?.runtime?.id);
    parent.postMessage({sandboxAssets: {image: await image, font: await font, runtime}}, '*');
})();
