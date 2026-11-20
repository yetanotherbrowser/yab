# Yab

Yet another browser. A small, quiet browser for the Mac, with an app for iPhone.

![Yab with tabs down the left, a product page, and an agent watching its price](docs/images/readme/window.jpg)

Yab is a browser with nothing in the way: a row of tabs, across the top or down the left, and the page. One field takes addresses and searches. Pages run on **WebKit**, the engine inside every Mac, or, on Apple silicon, on **Chromium**, per tab or per site. Agents from the AI providers you already pay for can work in tabs of their own, and never see a private tab.

**[Download Yab](https://yetanotherbrowser.com)** · macOS 15.4 or later · [What's new](https://yetanotherbrowser.com/changelog) · [Manual](https://yetanotherbrowser.com/manual)

## What it does

- **One field.** Type an address and you go there; type words and you search. It finishes addresses from your own history and sends nothing until you press Return.
- **Tabs that stay out of the way.** Pins, folders and spaces. Tabs from your last session come back instantly and cost nothing until you click them. `⌘K` finds any open tab.
- **Two engines.** WebKit and, on Apple silicon, Chromium, with Chrome extensions, Chrome DevTools and the Chrome Web Store. There the released app opens pages in Chromium by default, and protected video and Apple Pay checkouts in WebKit.
- **Blocking and hiding built in.** An ad blocker that runs inside the engine, before a request is made. `⇧⌘H` hides any element on a site, for good.
- **Reading mode, floating video, split view, Peek**, each one key away.
- **Passwords in your keychain**, or in the password manager you already use.
- **Agents in their own tabs**, with your sign-ins, asking before they send, pay or delete.
- **Sync that can't be read**: optional, end to end encrypted, between your Macs and iPhone.

![Reading mode in four themes](docs/images/readme/reading.jpg)

What Yab keeps and sends, line by line: [docs/privacy.md](docs/privacy.md). Every shortcut: [docs/keyboard.md](docs/keyboard.md).

## Build it

On a Mac with Xcode 26 or later:

```bash
git clone https://github.com/yetanotherbrowser/yab.git
```

```bash
cd yab && ./build.sh
```

```bash
open "build/yab Dev.app"
```

That makes **Yab Dev**, a development copy with its own bundle id, settings, data and keychain items, so it runs beside a real Yab without touching it. It is signed ad hoc; you need no Apple developer account. Tests run with `swift test`.

The full setup, Chromium tabs, the iPhone app and what each check proves: [CONTRIBUTING.md](CONTRIBUTING.md). A map of the code: [docs/architecture.md](docs/architecture.md).

## Contribute

Yab has more bug reports than hands. Help is welcome, most of all on bugs.

- **Report a bug** with the [bug form](https://github.com/yetanotherbrowser/yab/issues/new/choose). The Yab version, macOS version and the tab's engine (WebKit or Chromium) matter most.
- **Fix one.** Issues labeled [`good first issue`](https://github.com/yetanotherbrowser/yab/labels/good%20first%20issue) and [`help wanted`](https://github.com/yetanotherbrowser/yab/labels/help%20wanted) are ready to pick up. Read [CONTRIBUTING.md](CONTRIBUTING.md) first: it says what proof a pull request needs.
- **Security issues** go privately, never in an issue: [SECURITY.md](SECURITY.md).

How a report becomes a release: [docs/open-source/process.md](docs/open-source/process.md). Who decides what: [GOVERNANCE.md](GOVERNANCE.md). Everyone here follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

See [LICENSE](LICENSE). Third-party code in the app and the notices its licenses require: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
