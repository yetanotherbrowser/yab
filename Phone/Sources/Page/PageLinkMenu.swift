import UIKit
import WebKit

/// A link held on a page: Open in New Tab and Open in Background Tab, then
/// Download Linked File in a group of its own, over the system's own actions
/// for it (Open, Copy Link, Share and the rest, as WebKit suggests them), and
/// the linked page as the preview, loaded in the tab's own website store (a
/// private tab's in its private one). Only web links reach it: mail, calls and
/// other apps' addresses keep the system's menu. A link around an image adds
/// the image's rows (PageImage).
@MainActor
enum PageLinkMenu {
    enum Opening: Equatable, Sendable {
        /// A new tab in front, in the same space.
        case front
        /// After the tab it came from; the page stays in front.
        case background
        /// Beside the page it came from, the two in a split (iPad).
        case beside
    }

    static let newTab = "Open in New Tab"
    static let backgroundTab = "Open in Background Tab"
    static let download = "Download Linked File"
    static let beside = "Open in Split View"

    static func configuration(for url: URL, from source: WKWebView, canDownload: Bool, image: [UIMenuElement] = [], beside: Bool = false,
                              open: @escaping @MainActor (Opening) -> Void,
                              download: @escaping @MainActor () -> Void) -> UIContextMenuConfiguration {
        // Formed here, both providers are the main actor's; UIKit asks there.
        UIContextMenuConfiguration(identifier: url as NSURL, previewProvider: { [weak source] in
            guard let source else { return nil }
            return LinkPreviewController(url: url, configuration: source.configuration.copy() as! WKWebViewConfiguration)
        }, actionProvider: { suggested in
            menu(suggested, canDownload: canDownload, image: image, beside: beside, open: open, download: download,
                 copy: { UIPasteboard.general.url = url })
        })
    }

    /// Ours first, as groups of their own, then the system's for the link.
    static func menu(_ suggested: [UIMenuElement], canDownload: Bool = false, image: [UIMenuElement] = [], beside: Bool = false,
                     open: @escaping @MainActor (Opening) -> Void,
                     download: @escaping @MainActor () -> Void = {},
                     copy: @escaping @MainActor () -> Void = {}) -> UIMenu {
        let front = UIAction(title: newTab, image: UIImage.menuGlyph(MacGlyph.yabTabPlus)) { _ in open(.front) }
        front.accessibilityIdentifier = "link.newTab"
        let background = UIAction(title: backgroundTab,
                                  image: UIImage.menuGlyph(MacGlyph.yabTabDown)) { _ in open(.background) }
        background.accessibilityIdentifier = "link.backgroundTab"
        var opens = [front, background]
        if beside {
            let split = UIAction(title: Self.beside, image: UIImage.menuGlyph(MacGlyph.yabSplitPlus)) { _ in open(.beside) }
            split.accessibilityIdentifier = "link.beside"
            opens.append(split)
        }
        var groups: [UIMenuElement] = [UIMenu(options: .displayInline, children: opens)]
        if canDownload {
            let file = UIAction(title: Self.download, image: UIImage.menuGlyph(MacGlyph.yabDownload)) { _ in download() }
            file.accessibilityIdentifier = "link.download"
            groups.append(UIMenu(options: .displayInline, children: [file]))
        }
        var system = canDownload ? withoutDownload(suggested) : suggested
        if !image.isEmpty {
            groups.append(UIMenu(options: .displayInline, children: image))
            // WebKit's Save to Photos is ours now, and its bare Copy is the
            // link's beside Copy Image: said as Copy Link.
            system = without(["Save to Photos", "Copy"], in: system)
            let link = UIAction(title: "Copy Link", image: UIImage.menuGlyph(MacGlyph.link)) { _ in copy() }
            link.accessibilityIdentifier = "link.copy"
            groups.append(UIMenu(options: .displayInline, children: [link]))
        }
        return UIMenu(children: groups + system)
    }

    private static func without(_ titles: Set<String>, in elements: [UIMenuElement]) -> [UIMenuElement] {
        elements.compactMap { element in
            if let group = element as? UIMenu {
                let kept = without(titles, in: group.children)
                return kept.isEmpty ? nil : group.replacingChildren(kept)
            }
            return (element as? UIAction).map { titles.contains($0.title) } == true ? nil : element
        }
    }

    /// The system's own Download, should it offer one: ours stands for it.
    static func withoutDownload(_ elements: [UIMenuElement]) -> [UIMenuElement] {
        elements.compactMap { element in
            if let group = element as? UIMenu {
                let kept = withoutDownload(group.children)
                return kept.isEmpty ? nil : group.replacingChildren(kept)
            }
            let title = (element as? UIAction)?.title.lowercased() ?? ""
            return title.hasPrefix("download") ? nil : element
        }
    }
}

extension AppModel {
    /// Open in New Tab or Open in Background Tab: the link as a tab of the
    /// space the page is in, private when the page is. In the background it
    /// goes after the page, which stays in front, and the toast says so:
    /// nothing else on screen does.
    func openHeldLink(_ url: URL, from source: Tab.ID, as opening: PageLinkMenu.Opening) {
        guard let space = browser.space(holding: source) else { return }
        let isPrivate = space.isPrivate || browser.tab(source)?.isPrivate == true
        guard !isPrivate || privateLock.mayReveal else { return }
        let tab = PageFixtures.tab(for: url, isPrivate: isPrivate, in: world, fixturesEnabled: fixturesEnabled)
        switch opening {
        case .front:
            browser.open(tab, in: space.id, deduplicate: false)
        case .background:
            browser.openBehind(tab, after: source, in: space.id)
            Haptics.play(.soft, reason: Haptics.Reason.backgroundTab)
            say("Opened in Background", glyph: .squareBehindSquare1)
        case .beside:
            guard canOpenLinkBeside(source) else { return }
            workspace.openBeside(current: source, other: tab.id)
            browser.openBehind(tab, after: source, in: space.id)
            browser.select(tab.id)
        }
        profile?.capture(browser)
    }
}

extension AppModel {
    /// The Mac's Open in Split View: a wide iPad, an ordinary page.
    func canOpenLinkBeside(_ source: Tab.ID) -> Bool {
        guard workspace.canSplit, let tab = browser.tab(source), !tab.isPrivate, !tab.isMail,
              let space = browser.space(holding: source), !space.isPrivate else { return false }
        return true
    }
}

extension Haptics.Reason {
    static let backgroundTab = "background tab"  // soft: Open in Background Tab, with its toast
}

/// The linked page, as the held link's preview: to look at, not to use. A
/// tap on it opens the link in the tab (WebPool's commit).
final class LinkPreviewController: UIViewController {
    private let url: URL
    private let configuration: WKWebViewConfiguration

    init(url: URL, configuration: WKWebViewConfiguration) {
        self.url = url
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    @MainActor required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func loadView() {
        let page = WKWebView(frame: CGRect(origin: .zero, size: Metrics.screen), configuration: configuration)
        page.isUserInteractionEnabled = false
        page.allowsLinkPreview = false
        page.accessibilityIdentifier = "link.preview"
        page.load(URLRequest(url: url))
        view = page
    }
}
