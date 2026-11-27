import Foundation
import WebKit

// Many tabs of one site, one page process, past a count: Chrome's process
// model.
//
// WebKit gives every tab a content process of its own. Each costs ten to
// twenty megabytes before its page has drawn anything (a JavaScript VM, its
// heaps, fonts, caches) and wakes the CPU on its own timers, a few times a
// second, even hidden. Chrome does the same until the number of renderers
// reaches a limit set by the Mac's memory (RenderProcessHostImpl::
// GetMaxRendererProcessCount: half the memory over about 85 MB a renderer,
// at most 82); past it, a new tab on a site some tab already has goes into
// that tab's renderer. A different site never does: sites stay apart, as
// they must for Spectre, and as WebKit's own process limit does not keep
// them (it puts any site anywhere once reached, which is why it isn't used).
//
// So here: once Yab has `limit` page processes, a page about to be built for
// a site another awake tab of the same store is on joins that tab's process
// (`_relatedWebView`, the SPI a window opened by a page uses to share its
// opener's). The process with the fewest pages is taken. A page that later
// goes to another site moves to another process on its own (WebKit's
// process swap on navigation), as always.
//
// What it costs: pages sharing a process share its main thread, so a busy
// one slows the other, and a crash takes both, as with any shared renderer process.
// Putting one of them to sleep gives back only its share (PageProcesses),
// and a stuck one is ended with its group (StuckWatch), as tabs a page
// opened always were.
//
// A site found with video or sound stops sharing. WebKit keeps one media
// session manager for a whole page process, and each time a video starts,
// stops or comes into view it goes over every media element of every page
// in that process (MediaSessionManagerCocoa::performSessionStatusUpdate).
// Five tabs of a page of 96 muted videos in one
// process held its main thread 90 to 96% of the time while one of them
// scrolled; each in a process of its own, 5 to 8%.
//
// Measured (docs/evidence/night-memory-2026-10-14.md): 200 tabs on a
// 16 GB Mac, 201 page processes and 5156 MB, now 91 and 3753 MB.
@MainActor
enum SiteProcesses {
    /// On; YAB_SHARE_SITES=0 turns it off, for the A/B.
    static let on = ProcessInfo.processInfo.environment["YAB_SHARE_SITES"] != "0"

    /// How many page processes before same-site pages share one: Chrome's
    /// renderer limit for this Mac's memory, or YAB_SHARE_LIMIT. A test
    /// lowers it to make a sibling with two pages.
    static var limit: Int = {
        if let set = ProcessInfo.processInfo.environment["YAB_SHARE_LIMIT"].flatMap(Int.init), set > 0 { return set }
        return limit(memory: ProcessInfo.processInfo.physicalMemory)
    }()

    /// Chrome's: half the memory over an estimated 85 MB a renderer, between 3 and 82.
    nonisolated static func limit(memory: UInt64) -> Int {
        Int(min(82, max(3, memory / 2 / (85 << 20))))
    }

    /// The view a page for `url` in `store` should share a process with, or
    /// nil for a process of its own.
    static func sibling(for url: URL?, store: WKWebsiteDataStore) -> WKWebView? {
        guard on, let wanted = site(of: url), !mediaSites.contains(wanted) else { return nil }
        guard let all = processes(), all.count >= limit else { return nil }
        var best: (view: WKWebView, load: Int)?
        for views in all {
            guard let view = views.first(where: { site(of: $0.url) == wanted && $0.configuration.websiteDataStore === store })
            else { continue }
            // Every page in that process must be on this site: one moved
            // elsewhere since keeps its process until it swaps.
            guard views.allSatisfy({ site(of: $0.url) == wanted }) else { continue }
            if best == nil || views.count < best!.load { best = (view, views.count) }
        }
        return best?.view
    }

    /// Sites a page of which had media, this run: their next pages get
    /// processes of their own. Kept in memory only.
    private(set) static var mediaSites: Set<String> = []

    /// WebKit asked, once a page has loaded or settled on screen, whether
    /// it has any media, playing, paused or muted.
    static func learn(from web: WKWebView) {
        guard on, let site = site(of: web.url), !mediaSites.contains(site) else { return }
        ask(web)
    }

    /// The page's media state, learned for the site the page was on when
    /// asked: a reply that comes after the view went to another site is
    /// about the page it left.
    static func ask(_ web: WKWebView, then answer: @escaping @MainActor (WKMediaPlaybackState) -> Void = { _ in }) {
        let site = site(of: web.url)
        web.requestMediaPlaybackState { state in
            MainActor.assumeIsolated {
                if let site { heard(state, on: site) }
                answer(state)
            }
        }
    }

    static func heard(_ state: WKMediaPlaybackState, on site: String) {
        if state != .none { mediaSites.insert(site) }
    }

    /// The site of an address as WebKit keeps sites apart: scheme and
    /// registrable domain. Nil for anything but http(s).
    static func site(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased(), !host.isEmpty
        else { return nil }
        return scheme + "://" + Vault.registrable(host)
    }

    /// Every page process WebKit runs, by the views it serves (no
    /// footprints read: PageProcesses.census does that, and costs more).
    private static func processes() -> [[WKWebView]]? {
        let selector = NSSelectorFromString("_webContentProcessInfo")
        guard WKProcessPool.responds(to: selector) else { return nil }
        return autoreleasepool {
            guard let list = WKProcessPool.perform(selector)?.takeUnretainedValue() as? [NSObject] else { return nil }
            let webViews = NSSelectorFromString("webViews")
            return list.map { info in info.responds(to: webViews) ? info.value(forKey: "webViews") as? [WKWebView] ?? [] : [] }
        }
    }

    private static let relate = NSSelectorFromString("_setRelatedWebView:")
    private static let relatedGetter = NSSelectorFromString("_relatedWebView")

    /// The view the configuration's next view is to share a process with:
    /// the opener, for the configuration WebKit hands a window a page opens.
    static func related(of configuration: WKWebViewConfiguration) -> WKWebView? {
        guard configuration.responds(to: relatedGetter) else { return nil }
        return configuration.perform(relatedGetter)?.takeUnretainedValue() as? WKWebView
    }

    /// The configuration's next view joins `sibling`'s process (or a new
    /// one, for nil).
    static func relate(_ configuration: WKWebViewConfiguration, to sibling: WKWebView?) {
        guard configuration.responds(to: relate) else { return }
        configuration.perform(relate, with: sibling)
    }
}
