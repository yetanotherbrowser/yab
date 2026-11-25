# What Yab's Chromium calls by itself

Yab's privacy page says what you do stays on your Mac and lists what little
leaves it. Chromium, left alone, calls Google in the background from its first
second. This page is the list of what it did, why, and what stops it.
`evals/chromium-platform/net_audit.py` is the check: a fresh world, an hour idle,
then a session that touches every feature known to call home, seen through
Chromium's NetLog and lsof over every process of the app.

## What a stock profile called in its first five minutes

| Host | What for | Stopped by |
|---|---|---|
| `update.googleapis.com`, `edgedl.me.gvt1.com` | Component updates: Chrome's model files, lists and certificates data | `--disable-component-update`; `--optimization-guide-manifest-override`, as the on-device model list registers on its own |
| `clients2.google.com/time/1/current` | Network time, plain http | `NetworkTimeServiceQuerying` off |
| `www.google.com/async/folae` | AI mode eligibility for Chrome's omnibox | `AimEnabled`, `AimServerEligibilityEnabled` off, `omnibox.ai_mode_settings` |
| `www.gstatic.com/.../translate_ranker_model` | Chrome's translate bubble | `TranslateRankerQuery`, `TranslateRankerEnforcement` off, `translate.enabled` |
| `safebrowsing.googleapis.com` | Safe Browsing lists, with no API key | `safebrowsing.enabled`; Yab has its own opt-in list |

Features of the same family are off too, so none starts later: optimization hints
and their models, autofill's server, domain reliability, client-side phishing
detection, sync, and speech recognition, which sends the microphone to Google under a key this build
does not have. `--disable-background-networking` is not used: it also stops extension
updates, which are the one background call a person asked for by installing one.

Those updates are Chrome's own since store extensions are store installs
(`docs/chromium-extensions.md`, "Store installs and updates"): at start and about
every five hours, Chrome's ExtensionUpdater sends the ids and versions of the
installed store extensions to `update.googleapis.com/service/update2/json` (its
update client; `--disable-component-update` stops only the component updater) and
downloads a newer package from the store's download hosts. With no store extension
installed it calls nothing. It is the same question WebKit's daily check asks
`clients2.google.com/service/update2/crx`.

## What a page can't make it do

Profile preferences, rewritten into every profile at each start, as WebKit tabs
behave:

| Preference | Value | What it stops |
|---|---|---|
| `net.network_prediction_options` | 2, no prediction | Prefetch and prerender a page asks for with speculation rules, and Chromium's own preloading |
| `enable_a_ping` | false | `<a ping>` posts |
| `webrtc.ip_handling_policy` | `default_public_interface_only` | Host candidates: a page learns no LAN address over WebRTC |
| `profile.cookie_controls_mode` | 1, block third party | Third-party cookies being set or read by scripts |

Turning Shield off for a site lets third-party cookies back in on it: YabCore
derives `*,host` and `*,www.host` allow exceptions in
`profile.content_settings.exceptions.cookies` from Shield's list each time Yab sends
it (`ShieldCookieExceptions`), the same hosts Shield is off on. Yab owns every `*,`
entry there.

Chromium 156 has already retired Topics, Protected Audience, Shared Storage and
Attribution Reporting: `document.browsingTopics()` throws, `joinAdInterestGroup`
does nothing and `runAdAuction` gives null, `window.sharedStorage` is missing, and
there are no Privacy Sandbox prompts. Nothing is set for them.

## Where it is set

`YabCore/src/core.mm` (`OnBeforeCommandLineProcessing`) for switches and features.
`YabCore/src/clear_data.inc` (`ChosenPreferences`) for profile preferences, written
into each profile's `Preferences` before Chrome reads it. A preference is the only
way to stop a service that starts with the profile: setting it afterwards leaves a
window in which it already called.

## What the choice costs

Components carried Chrome's certificate revocation list (CRLSet) and updates to the
root store and Certificate Transparency logs. Without them Chromium uses what the
binary shipped with, so a release must keep CEF current. Sites that break for lack of
a Chrome component list are not known; none showed in the evals.
