import SwiftUI
import UIKit

/// The Mac's groups, adapted to the pages that actually exist on this iPhone.
enum SettingsRoute: Hashable {
    case page(SettingsPageID)
    case space(Space.ID)
    case spaceName(Space.ID)
    case spaceEmoji(Space.ID)
    case spaceColor(Space.ID)
}

@MainActor
enum SettingsIndex {
    struct Match: Identifiable {
        let page: SettingsPageID
        let row: String?
        let words: String
        let detail: String?
        var id: String { page.rawValue + "." + (row ?? "page") }
    }
    /// The root's groups as on the Mac: basic pages, features, Yab itself.
    /// App Icon has a row of its own under Appearance where iOS can change
    /// the icon at all.
    static var groups: [[SettingsPageID]] {
        groups(alternateIcons: UIApplication.shared.supportsAlternateIcons)
    }

    static func groups(alternateIcons: Bool) -> [[SettingsPageID]] {
        [
            [.general, .search, .appearance] + (alternateIcons ? [.appIcon] : []) + [.tabs, .sync],
            // Extensions only once Apple grants the browser entitlement (ExtensionHost.isAvailable).
            [.ai, .spaces, .history, .passwords, .autofill] + (ExtensionHost.isAvailable ? [.extensions] : []) + [.privacy],
            [.about, .feedback],
        ]
    }

    static func matches(_ query: String, content: SettingsContent) -> [Match] {
        let tokens = words(query)
        guard !tokens.isEmpty else { return [] }
        func finds(_ text: String) -> Bool {
            let candidates = words(text)
            return tokens.allSatisfy { token in candidates.contains { $0.hasPrefix(token) } }
        }
        var matches: [Match] = []
        for page in SettingsPageID.allCases where page != .extensions || ExtensionHost.isAvailable {
            let title = SettingsContent.title(page)
            if finds(title) {
                matches.append(Match(page: page, row: nil, words: title, detail: nil))
            } else if let row = content.sections(page).flatMap(\.rows).first(where: { finds($0.title + " " + ($0.value ?? "")) }) {
                // A specific preference wins over its page's broad synonyms,
                // so “dark” opens the actual Dark choice, not just Appearance.
                matches.append(Match(page: page, row: row.id, words: title, detail: row.title))
            } else if finds(keywords(page)) {
                matches.append(Match(page: page, row: nil, words: title, detail: nil))
            }
        }
        return matches.sorted {
            let left = $0.words.localizedCaseInsensitiveCompare(query) == .orderedSame
            let right = $1.words.localizedCaseInsensitiveCompare(query) == .orderedSame
            if left != right { return left }
            if ($0.row == nil) != ($1.row == nil) { return $0.row == nil }
            return $0.words.localizedCaseInsensitiveCompare($1.words) == .orderedAscending
        }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func keywords(_ page: SettingsPageID) -> String {
        switch page {
        case .general: "browser default links notifications swipe back forward gestures welcome first run onboarding"
        case .search: "engine google web address url guess questions ask task return"
        case .appearance: "theme light dark system color colour look websites pages"
        case .appIcon: "icon icons home screen logo"
        case .tabs: "today keep pins folders"
        case .ai: "answers questions claude chatgpt models agent"
        case .spaces: "workspaces personal work emoji sign ins cookies"
        case .sync: "mac devices recovery code encrypted join iphone turn off leave"
        case .recoveryKey: "recovery key sync account backup"
        case .passwords: "passkeys password credentials login"
        case .autofill: "forms fill addresses cards"
        case .privacy: "private lock face id history cookies website data clear ads ad blocker trackers content blocking"
        case .feedback: "report bug help"
        case .extensions: "chrome web store add-ons addons plugins dark reader metamask"
        case .history: "visited pages recent browsing clear forget"
        case .about: "version build crash reports daily activity"
        default: ""
        }
    }

    /// Current main PenTile uses the page key directly. In particular, the
    /// Passwords drawing differs from the generic key symbol's drawing.
    static func macMark(_ page: SettingsPageID) -> String? {
        switch page {
        case .general, .search, .appearance, .appIcon, .tabs, .sync, .ai, .spaces,
             .passwords, .autofill, .privacy, .about, .feedback, .history, .extensions: page.rawValue
        default: nil
        }
    }

    /// The marker under a feature's ink, in the Mac's PenArt.mark colors.
    /// Basic pages (the first group, App Icon among them) are ink only.
    static func macTint(_ page: SettingsPageID) -> UIColor? {
        switch page {
        case .ai: mark(0xa96be0)
        case .about: mark(0x8b6cf0)
        case .spaces, .autofill: mark(0x34b85a)
        case .passwords: mark(0x808087)
        case .privacy: mark(0x3b82f0)
        case .history: mark(0xf0943a)
        case .extensions: mark(0x615fd8)
        default: nil
        }
    }

    private static func mark(_ rgb: UInt32) -> UIColor {
        UIColor(red: CGFloat(rgb >> 16 & 0xff) / 255, green: CGFloat(rgb >> 8 & 0xff) / 255,
                blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }

    static func glyph(_ page: SettingsPageID) -> GlyphName? {
        switch page {
        case .general: .settingsGear1
        case .search: .magnifyingGlass
        case .appearance: .moon
        case .appIcon: nil
        case .tabs, .today: .squareBehindSquare1
        case .ai, .aboutPage: .sparkle
        case .spaces: .window
        case .sync: .arrowRotateClockwise
        case .passwords: .key1
        case .autofill: .creditCard1
        case .privacy, .lockScreen: .lock
        case .feedback: .chatBubble7
        case .mac: .macbook
        case .agent, .everythingElse: .agent
        case .defaultBrowser: .globe
        case .faceID: .faceId
        case .privateTabs: .incognito
        case .notifications: .bellCheck
        case .about: nil
        case .history: .history
        case .recoveryKey: .key1
        case .extensions: .plugin1
        }
    }

    static func tint(_ page: SettingsPageID) -> Color {
        switch page {
        case .search, .privacy, .defaultBrowser: Color(uiColor: .systemBlue)
        case .tabs, .today, .autofill, .history: Color(uiColor: .systemOrange)
        case .spaces, .sync: Color(uiColor: .systemGreen)
        // The person's later request replaced the prototype's purple accent.
        case .ai, .appearance, .agent, .everythingElse, .aboutPage: Ink.primary
        default: Color(uiColor: .systemGray)
        }
    }

    static func blurb(_ page: SettingsPageID) -> String? {
        switch page {
        case .search: "Search the web, or ask a question from the address field."
        case .spaces: "Sets of tabs, each with its pins, its color and whose sign-ins."
        case .sync: "Your spaces, tabs and chats on your devices, encrypted so only they can read them."
        case .ai: "Answers on this \(DeviceWord.name), and Claude or ChatGPT on your Mac."
        case .passwords: "Passwords and passkeys from your configured iOS provider."
        case .autofill: "Information offered by iOS on supported webpage fields."
        case .privacy: "Ads and trackers, private tabs, approval and Lock Screen details."
        case .feedback: "Tell us what happened. It goes straight to the people who make Yab."
        case .history: "Every page you opened, here and on your Mac."
        case .extensions: "Extensions from the Chrome Web Store, on every page you open."
        case .recoveryKey: "The key your sync was made with. With it, any device can join, even without your Mac."
        default: nil
        }
    }
}

/// One sharp tile, the same glyph at root size and the Mac's 56-point hero.
struct SettingsTile: View {
    let page: SettingsPageID
    var side: CGFloat = Metrics.Settings.indexTile
    var body: some View {
        Group {
            if let mark = SettingsIndex.macMark(page) {
                SettingsIconTile(mark: mark, tint: SettingsIndex.macTint(page), side: side)
                    .frame(width: side, height: side)
                    .allowsHitTesting(false)
            } else if let glyph = SettingsIndex.glyph(page) {
                Glyph(glyph, size: side * 0.58,
                      color: [.ai, .appearance, .agent, .everythingElse, .aboutPage].contains(page) ? Ink.onNewAnswer : .white)
                    .frame(width: side, height: side)
                    .background(SettingsIndex.tint(page), in: RoundedRectangle(cornerRadius: side * 0.27))
            } else {
                YabMark(size: side).clipShape(RoundedRectangle(cornerRadius: side * 0.27))
            }
        }.accessibilityHidden(true)
    }
}
