import AppKit
import Combine

/// The same observable preferences Settings edits. No arbitrary defaults keys
/// or permission switches can be written through this registry.
@MainActor
struct NativeSetting {
    let id: String
    let title: String
    let schema: [String: Any]
    let read: (Preferences) -> NativeValue
    let write: (Preferences, NativeValue) throws -> Void
    let observe: (Preferences, @escaping () -> Void) -> AnyCancellable
    var scope: String { ["color", "grain", "transparency", "glass"].contains(id) ? "space" : "application" }

    /// Read only the registered persisted value, without constructing a new
    /// Preferences object (whose initializer also migrates unrelated settings).
    var saved: NativeValue? {
        let keys = ["theme": "look", "sidebar": "sidebar", "tab-icons": "tabs.glyph", "density": Density.key, "address-bar": "addressbar",
                    "full-url": "addressbar.full-url", "peek-address": "peek.address", "bookmarks-bar": "bookmarks.bar", "window": "backdrop",
                    "page-zoom": "pages.zoom", "warn-quit": "quit.warn", "sleep": "tabs.sleep",
                    "pins-every-space": SharedPins.key, "peek": "peek", "site-learn": "scopes.learn", "site-recent": "scopes.recent", "ask-where": "downloads.ask", "upload-finder": "uploads.finder",
                    "small-links": LinkWindow.key, "mail-motion": "mail.motion", "player": "player.shown", "agents-ask-opens": "agents.askOpens", "agents-cleanup": AgentTabsAfter.key,
                    "float-leave": "float.leave", "link-folders": "tabs.linkFolders", "folder-emoji": "tabs.folderEmoji", "opt-shift-folders": "tabs.optShiftFolders", "meeting-folders": "tabs.meetingFolders", "today-every-window": KeptEverywhere.todayKey, "float-away": "float.away", "dev-offer": "dev.offer", "dev-side": "dev.side", "search-engine": Engine.key, "tidy": "tabs.tidy",
                    "live-folders": LiveFolderFeature.key, "float-snap": Floater.snapToEdgesKey,
                    "sidebar-button": "sidebar.button", "glass-pins": "pins.glass", "tidy-tabs": "tidy.tabs", "tidy-titles": "tidy.titles", "folder-names": "folders.names",
                    "tidy-downloads": "tidy.downloads", "ai-instant-links": "field.instant", "ai-link-previews": LinkCard.key]
        guard let key = keys[id], let raw = Store.settings.object(forKey: key), let value = try? NativeValue.read(raw) else { return nil }
        let descriptor: [String: Any] = ["parameters": ["properties": ["value": schema], "required": ["value"]]]
        guard (try? NativeActions.validate(["value": value], descriptor: descriptor)) != nil else { return nil }
        return value
    }

    static func boolean(_ id: String, _ title: String, _ key: ReferenceWritableKeyPath<Preferences, Bool>) -> Self {
        Self(id: id, title: title, schema: ["type": "boolean"], read: { .bool($0[keyPath: key]) }, write: { prefs, value in
            guard case .bool(let on) = value else { throw NativeFailure("invalid_arguments", "\(title) needs a boolean") }
            prefs[keyPath: key] = on
        }, observe: { prefs, changed in prefs.changes(key).dropFirst().sink { _ in changed() } })
    }

    static func choice<T: RawRepresentable>(_ id: String, _ title: String, _ key: ReferenceWritableKeyPath<Preferences, T>, values: [String]) -> Self where T.RawValue == String {
        Self(id: id, title: title, schema: ["type": "string", "enum": values], read: { .string($0[keyPath: key].rawValue) }, write: { prefs, value in
            guard case .string(let raw) = value, values.contains(raw), let choice = T(rawValue: raw) else {
                throw NativeFailure("invalid_arguments", "\(title) needs one of: \(values.joined(separator: ", "))")
            }
            prefs[keyPath: key] = choice
        }, observe: { prefs, changed in prefs.changes(key).dropFirst().sink { _ in changed() } })
    }

    static func number(_ id: String, _ title: String, _ key: ReferenceWritableKeyPath<Preferences, Double>, range: ClosedRange<Double>) -> Self {
        Self(id: id, title: title, schema: ["type": "number", "minimum": range.lowerBound, "maximum": range.upperBound], read: { .number($0[keyPath: key]) }, write: { prefs, value in
            guard case .number(let n) = value, n.isFinite, range.contains(n) else { throw NativeFailure("invalid_arguments", "\(title) must be between \(range.lowerBound) and \(range.upperBound)") }
            prefs[keyPath: key] = n
        }, observe: { prefs, changed in prefs.changes(key).dropFirst().sink { _ in changed() } })
    }

    /// A setting kept as a plain value in Yab's defaults, outside
    /// Preferences: read and written there, `apply` telling its owner.
    static func stored(_ id: String, _ title: String, _ schema: [String: Any], read: @escaping () -> NativeValue,
                       write: @escaping (NativeValue) throws -> Void) -> Self {
        Self(id: id, title: title, schema: schema, read: { _ in read() }, write: { _, value in try write(value) }, observe: { _, changed in
            // Read before subscribing: an owner's first read may migrate its
            // defaults and synchronously post another change notification.
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: Store.settings)
                .map { _ in read() }.prepend(read()).removeDuplicates().dropFirst().sink { _ in changed() }
        })
    }

    static func flag(_ id: String, _ title: String, key: String, default fallback: Bool, then: @escaping (Bool) -> Void = { _ in }) -> Self {
        stored(id, title, ["type": "boolean"], read: { .bool(Store.settings.object(forKey: key) as? Bool ?? fallback) }) { value in
            guard case .bool(let on) = value else { throw NativeFailure("invalid_arguments", "\(title) needs a boolean") }
            Store.settings.set(on, forKey: key)
            then(on)
        }
    }

    static func count(_ id: String, _ title: String, key: String, default fallback: Int, values: [Int]) -> Self {
        stored(id, title, ["type": "integer", "enum": values], read: { .number(Double(Store.settings.object(forKey: key) as? Int ?? fallback)) }) { value in
            guard case .number(let n) = value, values.map(Double.init).contains(n) else {
                throw NativeFailure("invalid_arguments", "\(title) is one of: \(values.map(String.init).joined(separator: ", "))")
            }
            Store.settings.set(Int(n), forKey: key)
        }
    }

    /// Mail's and Sync's settings, the field's, the icon's and the
    /// snippets', each written the way its row in Settings writes it.
    static var kept: [Self] { [
        flag("suggestions", "Suggestions under the field", key: "hints.noticing", default: true) { Hints.shared.suggesting = $0 },
        flag("site-search-space", "Space after a site's alias starts its search, as Tab does (Chrome's Space or Tab; off is Tab alone)",
             key: Scopes.spaceKey, default: true),
        flag("meetings", "Your next meeting on a pinned calendar", key: "meetings.show", default: true) { Meetings.shared.wanted = $0 },
        stored("app-icon", "App icon", ["type": "string", "enum": AppIconStyle.allCases.map(\.rawValue)],
               read: { .string(AppIconStyle.saved.rawValue) }) { value in
            guard case .string(let raw) = value, let style = AppIconStyle(rawValue: raw), AppIconStyle.choices.contains(style) else {
                throw NativeFailure("invalid_arguments", "Choose one of the icons the user has: \(AppIconStyle.choices.map(\.rawValue).joined(separator: ", "))")
            }
            style.choose()
        },
        flag("snippets-semicolon", "Type ; and a name in any box", key: SnippetSettings.semicolonKey, default: true),
        flag("snippets-offer", "Offer to keep what you paste often", key: SnippetSettings.offerKey, default: true),
        stored("sync-history", "Sync history of the last two weeks", ["type": "boolean"], read: { .bool(SyncCenter.shared.history) }) { value in
            guard case .bool(let on) = value else { throw NativeFailure("invalid_arguments", "Needs a boolean") }
            guard SyncCenter.shared.on else { throw NativeFailure("disabled", "Sync is off; the user turns it on in Settings › Sync") }
            SyncCenter.shared.history = on
        },
        stored("sync-addons", "Sync extensions and plugins", ["type": "boolean"], read: { .bool(SyncCenter.shared.addons) }) { value in
            guard case .bool(let on) = value else { throw NativeFailure("invalid_arguments", "Needs a boolean") }
            guard SyncCenter.shared.on else { throw NativeFailure("disabled", "Sync is off; the user turns it on in Settings › Sync") }
            SyncCenter.shared.addons = on
        },
        stored("mail-pin", "Mail pin", ["type": "boolean"], read: { .bool(MailCenter.shared.pinWanted) }) { value in
            guard case .bool(let on) = value else { throw NativeFailure("invalid_arguments", "Needs a boolean") }
            guard let browser = BrowserWindows.shared.browsers.first else { throw NativeFailure("conflict", "No browser window is open") }
            if on { MailCenter.shared.putPin(in: browser) } else { MailCenter.shared.takePin(in: browser) }
        },
        stored("mail-badge", "Count on the pin and the Dock", ["type": "string", "enum": MailNotify.Badge.allCases.map(\.rawValue)],
               read: { .string(MailNotify.shared.badgeMode.rawValue) }) { value in
            guard case .string(let raw) = value, let badge = MailNotify.Badge(rawValue: raw) else { throw NativeFailure("invalid_arguments", "Unknown count") }
            MailNotify.shared.setBadge(badge)
        },
        stored("mail-needs", "What needs you: only mail that asks you something", ["type": "boolean"], read: { .bool(MailList.shared.policy.asks) }) { value in
            guard case .bool(let on) = value else { throw NativeFailure("invalid_arguments", "Needs a boolean") }
            MailList.shared.policy.asks = on
        },
        stored("mail-window", "How far back, in days (0: every age)", ["type": "integer", "enum": [7, 30, 0]],
               read: { .number(Double(MailList.shared.policy.days ?? 0)) }) { value in
            guard case .number(let n) = value, [7, 30, 0].contains(Int(n)) else { throw NativeFailure("invalid_arguments", "7, 30 or 0") }
            MailList.shared.policy.days = n > 0 ? Int(n) : nil
        },
        stored("mail-ads", "Ads and promos", ["type": "string", "enum": ["only", "off", "skip"], "description": "only: hide here; off: keep in Other; skip: archive in Gmail too"],
               read: {
                   guard let ads = MailList.shared.ordered.first(where: { $0.id == MailSplits.ads }), ads.on else { return .string("off") }
                   return .string(ads.mode == .skip ? "skip" : "only")
               }) { value in
            guard case .string(let mode) = value, ["only", "off", "skip"].contains(mode) else { throw NativeFailure("invalid_arguments", "only, off or skip") }
            MailList.shared.setMode(mode, for: MailSplits.ads)
        },
        flag("mail-pitches", "Cold pitches: No ready in the list", key: MailOffers.declinesKey, default: false) { _ in MailDesk.shared.load() },
        stored("mail-splits-hide", "Hide empty splits", ["type": "boolean"], read: { .bool(MailList.shared.hideEmpty) }) { value in
            guard case .bool(let on) = value else { throw NativeFailure("invalid_arguments", "Needs a boolean") }
            MailList.shared.hideEmpty = on
        },
        flag("mail-sense", "Sort and sum up on this Mac", key: "mail.sense", default: true),
        flag("mail-summaries", "Split summaries", key: "mail.summaries", default: false),
        flag("mail-pixels", "Block tracking pixels", key: "mail.pixels", default: true),
        flag("mail-pdf-yab", "Open PDFs from Mail in Yab", key: "mail.pdf.yab", default: true),
        flag("mail-ahead", "Write replies ahead", key: "mail.ahead", default: false),
        count("mail-undo", "Undo send, in seconds", key: "mail.undo", default: 5, values: [5, 10, 20]),
        flag("mail-signature-replies", "Signature in replies and forwards", key: "mail.signature.replies", default: true),
        stored("mail-hours", "Working hours for free slots, as 09:00-18:00", ["type": "string", "maxLength": 11],
               read: {
                   let start = Store.settings.object(forKey: "mail.slots.start") as? Int ?? 9 * 60, end = Store.settings.object(forKey: "mail.slots.end") as? Int ?? 18 * 60
                   return .string(String(format: "%02d:%02d-%02d:%02d", start / 60, start % 60, end / 60, end % 60))
               }) { value in
            guard case .string(let text) = value else { throw NativeFailure("invalid_arguments", "As 09:00-18:00") }
            let minutes = text.split(separator: "-").map { part -> Int? in
                let hm = part.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Int($0) }
                return hm.count == 2 && (0...24).contains(hm[0]) && [0, 30].contains(hm[1]) ? hm[0] * 60 + hm[1] : nil
            }
            guard minutes.count == 2, let start = minutes[0], let end = minutes[1], end - start >= 30, end <= 24 * 60 else {
                throw NativeFailure("invalid_arguments", "As 09:00-18:00, on the half hour, the end at least 30 minutes after the start")
            }
            Store.settings.set(start, forKey: "mail.slots.start")
            Store.settings.set(end, forKey: "mail.slots.end")
        },
        count("mail-slot-length", "Slot length, in minutes", key: "mail.slots.length", default: 30, values: MailSlots.lengths),
        stored("mail-booking", "Booking link", ["type": "string", "maxLength": 300], read: { .string(Store.settings.string(forKey: "mail.booking") ?? "") }) { value in
            guard case .string(let text) = value else { throw NativeFailure("invalid_arguments", "A link, or empty") }
            let link = text.trimmingCharacters(in: .whitespaces)
            guard link.isEmpty || URL(string: link).map({ ["http", "https"].contains($0.scheme ?? "") }) == true else { throw NativeFailure("invalid_arguments", "An http(s) link, or empty") }
            Store.settings.set(link, forKey: "mail.booking")
        },
        stored("peek-click", "Peek links with: shift-click or option-click", ["type": "string", "enum": ["shift", "option"]],
               read: { .string(Store.settings.string(forKey: PeekClick.key) ?? PeekClick.shift.rawValue) }) { value in
            guard case .string(let raw) = value, PeekClick(rawValue: raw) != nil else { throw NativeFailure("invalid_arguments", "shift or option") }
            Store.settings.set(raw, forKey: PeekClick.key)
        },
        stored("energy-saver", "Energy Saver: off, when battery is at 20% or lower, or when unplugged", ["type": "string", "enum": EnergySaver.allCases.map(\.rawValue)],
               read: { .string(EnergySaver.current.rawValue) }) { value in
            guard case .string(let raw) = value, let choice = EnergySaver(rawValue: raw) else { throw NativeFailure("invalid_arguments", "off, low or unplugged") }
            EnergySaver.current = choice
        },
        flag("experimental-switcher-strip", "Recent Tabs Over the Page (Ctrl-Tab row)", key: SwitcherStrip.key, default: false),
        stored("switcher-reach", "Recent tabs come from every space or this space", ["type": "string", "enum": SwitchReach.allCases.map(\.rawValue)],
               read: { .string(SwitchReach.current.rawValue) }) { value in
            guard case .string(let raw) = value, SwitchReach(rawValue: raw) != nil else { throw NativeFailure("invalid_arguments", "Unknown reach") }
            Store.settings.set(raw, forKey: SwitchReach.key)
        },
        // Settings › Reading Mode, the theme in front's own size and face.
        reader("reader-theme", "Reading mode theme", ["type": "string", "enum": ReaderThemeID.allCases.map(\.rawValue)],
               read: { .string($0.theme.rawValue) }) { prefs, value in
            guard case .string(let raw) = value, let theme = ReaderThemeID(rawValue: raw) else { return false }
            prefs.theme = theme; return true
        },
        reader("reader-light", "Reading mode appearance", ["type": "string", "enum": ReaderMode.allCases.map(\.rawValue)],
               read: { .string($0.mode.rawValue) }) { prefs, value in
            guard case .string(let raw) = value, let mode = ReaderMode(rawValue: raw) else { return false }
            prefs.mode = mode; return true
        },
        reader("reader-wide", "Wide page in reading mode", ["type": "boolean"], read: { .bool($0.wide) }) { prefs, value in
            guard case .bool(let on) = value else { return false }
            prefs.wide = on; return true
        },
        reader("reader-size", "Reading text size, in points", ["type": "integer", "enum": ReaderLook.sizes],
               read: { .number(Double(ReaderLook.sizes[$0.look.size])) }) { prefs, value in
            guard case .number(let n) = value, let at = ReaderLook.sizes.firstIndex(of: Int(n)) else { return false }
            prefs.change { $0.size = at }; return true
        },
        reader("reader-font", "Reading font (site: the site's own)", ["type": "string", "enum": ReaderFont.allCases.map(\.rawValue)],
               read: { .string($0.look.font.rawValue) }) { prefs, value in
            guard case .string(let raw) = value, let face = ReaderFont(rawValue: raw) else { return false }
            prefs.change { $0.font = face }; return true
        },
    ] }

    /// Reading mode's, kept in ReaderStyle as its page writes them.
    static func reader(_ id: String, _ title: String, _ schema: [String: Any], read: @escaping (ReaderPrefs) -> NativeValue,
                       write: @escaping (inout ReaderPrefs, NativeValue) -> Bool) -> Self {
        stored(id, title, schema, read: { read(ReaderStyle.shared.prefs) }) { value in
            var prefs = ReaderStyle.shared.prefs
            guard write(&prefs, value) else { throw NativeFailure("invalid_arguments", "Unknown value for \(title)") }
            ReaderStyle.shared.prefs = prefs
        }
    }

    static var all: [Self] { kept + [
        choice("theme", "Theme", \.look, values: Look.allCases.map(\.rawValue)),
        boolean("sidebar", "Tabs in a sidebar", \.sidebar),
        choice("sidebar-side", "Sidebar side", \.sideFlank, values: ["left", "right"]),
        boolean("pins-every-space", "Pins in every space", \.pinsEverySpace),
        choice("tab-icons", "Tab icons", \.glyph, values: Glyph.allCases.map(\.rawValue)),
        choice("density", "Density", \.density, values: Density.allCases.map(\.rawValue)),
        boolean("address-bar", "Address bar", \.addressBar),
        boolean("full-url", "Show full URL", \.fullURL),
        boolean("peek-address", "Show address bar in Peek", \.peekAddress),
        choice("bookmarks-bar", "Bookmarks bar", \.bookmarkBar, values: BookmarkBarMode.allCases.map(\.rawValue)),
        choice("bookmarks-style", "Bookmarks show", \.bookmarkStyle, values: BookmarkStyle.allCases.map(\.rawValue)),
        choice("window", "Window background", \.backdrop, values: Backdrop.allCases.map(\.rawValue)),
        choice("color", "Background color", \.swatch, values: Swatch.allCases.map(\.rawValue)),
        number("transparency", "Background transparency", \.backdropTransparency, range: 0...1),
        boolean("glass", "Glass window", \.lookGlass),
        number("grain", "Background grain", \.grain, range: 0...1),
        number("page-zoom", "Default page zoom", \.pageZoom, range: 0.4...3),
        boolean("warn-quit", "Warn before quitting", \.warnsOnQuit),
        boolean("live-folders", "Live Folders", \.usesLiveFolders),
        boolean("ask-where", "Ask where to save files", \.asksWhereToSave),
        boolean("upload-finder", "Choose files to upload in Finder", \.uploadsInFinder),
        boolean("small-links", "Small windows for links", \.smallLinks),
        boolean("mail-motion", "Mail animations", \.mailAnimations),
        boolean("link-folders", "⌘-clicking links makes folders", \.linkFolders),
        boolean("folder-emoji", "Add emoji to new folders", \.folderEmoji),
        boolean("opt-shift-folders", "⌥⇧-click puts a tab in a folder", \.optShiftFolders),
        boolean("meeting-folders", "Group tabs for meetings", \.meetingFolders),
        boolean("today-every-window", "Today's tabs in every window", \.todayEveryWindow),
        boolean("float-leave", "Picture in Picture automatically, when leaving a video's tab or Yab", \.floatsOnLeave),
        flag("float-snap", "Snap Picture in Picture to edges", key: Floater.snapToEdgesKey, default: true) { on in
            for browser in BrowserWindows.shared.browsers { browser.floater.snapToEdges(on) }
        },
        boolean("player", "Show media player", \.showsPlayer),
        boolean("dev-offer", "Offer Developer Mode on local pages", \.offerDevMode),
        choice("dev-side", "Developer Tools open", \.devSide, values: ["bottom", "right", "left"]),
        choice("dev-json", "Show JSON as", \.jsonView, values: JSONShow.allCases.map(\.rawValue)),
        choice("dark-pages", "Dark pages: with the theme, always or off", \.darkPages, values: DarkMode.allCases.map(\.rawValue)),
        choice("search-engine", "Search engine", \.engine, values: Engine.allCases.map(\.rawValue)),
        boolean("search-suggest", "Suggest searches from your search engine", \.searchSuggest),
        boolean("small-key", "Open a small window from any app with its shortcut", \.smallKey),
        boolean("sidebar-button", "Show sidebar button", \.sidebarButton),
        boolean("glass-pins", "Glass pins", \.glassPins),
        boolean("tidy-tabs", "Tidy tabs: group Today tabs into folders by topic", \.tidyTabs),
        boolean("tidy-titles", "Tidy tab titles: shorten titles of kept tabs", \.tidyTitles),
        boolean("folder-names", "Name folders based on their tabs", \.folderNames),
        boolean("tidy-downloads", "Rename downloads based on their content", \.tidyDownloads),
        boolean("ai-instant-links", "Instant links: Shift-Return opens the top search result", \.instantLinks),
        boolean("ai-link-previews", "Link previews: hold Shift over a link", \.linkPreviews),
        Self(id: "tidy", title: "Archive idle tabs after hours", schema: ["type": "integer", "enum": Tidy.allCases.map(\.rawValue)],
             read: { .number(Double($0.tidyAfter.rawValue)) }, write: { prefs, value in
                 guard case .number(let n) = value, let tidy = Tidy.allCases.first(where: { Double($0.rawValue) == n }) else { throw NativeFailure("invalid_arguments", "Choose an available idle-tab duration") }
                 prefs.tidyAfter = tidy
             }, observe: { prefs, changed in prefs.changes(\.tidyAfter).dropFirst().sink { _ in changed() } }),
        choice("agents-ask-opens", "Default asking view", \.askOpens, values: AskOpens.allCases.map(\.rawValue)),
        choice("agents-cleanup", "Close agent tabs", \.agentTabsAfter, values: AgentTabsAfter.allCases.map(\.rawValue))
    ] }
}

@MainActor
enum NativeActions {
    static let version = 1
    static let controlled = Set(["bench", "agents-asking", "agents-pay", "agents-sites", "agents-messages", "agents-elsewhere", "agents-remember", "agents-memory",
                                 "mail-agents", "mail-memory", "prove", "import-passwords", "import-cards", "your-passwords", "save-passwords", "fill", "passkeys",
                                 "codes-mail", "codes-texts", "codes-archive", "your-cards", "save-cards", "fill-cards", "fill-forms", "draft-forms",
                                 "shield", "cookies", "cache", "diary-text", "extensions-private", "default-browser", "agents-routines", "memory-forget",
                                 "mail-people", "sync-passwords", "activity", "crashes",
                                 // Profile selection changes access to signed-in accounts; the person confirms it.
                                 "space-sign-ins",
                                 // The person's consent for mail going to their AI (MailConsent): theirs alone.
                                 "mail-ahead", "mail-summaries", "mail-agents-others",
                                 // AI in Yab (AIUse): the person turns AI on or off, never an agent.
                                 "ai-use"])

    /// Sources an agent can add as Settings › Live Folders does; a search,
    /// a repository (live.follow_repo) and a routine's folder come their own ways.
    /// tabs.close: at most this many at once, like the other tab arrays.
    /// It never asks: closing is fully undoable.
    static let closeLimit = 50

    static let liveSources = ["github.pulls", "github.issues", "linear", "notion", "drive", "figma", "youtube", "feed"] + LiveGitService.allCases.map(\.sourceID)

    static var descriptors: [[String: Any]] {
        func action(_ id: String, _ title: String, _ kind: String, _ parameters: [String: Any], required: [String] = [], undo: Bool = false, permission: String = "requested") -> [String: Any] {
            ["id": id, "title": title, "version": version, "targetKind": kind, "parameters": ["type": "object", "properties": parameters, "required": required, "additionalProperties": false], "undo": undo, "permission": permission]
        }
        let string: [String: Any] = ["type": "string", "maxLength": 160]
        return NativeSetting.all.map { action("settings.set." + $0.id, $0.title, $0.scope, ["value": $0.schema], required: ["value"], undo: true) } + [
            action("settings.open", "Open a Settings page", "application", ["page": ["type": "string", "enum": SettingsPage.allCases.map(\.rawValue)]], required: ["page"]),
            action("space.create", "Create a space", "application", ["name": string, "separateSignIns": ["type": "boolean"]], required: ["name"], undo: true),
            action("space.rename", "Rename a space", "space", ["name": string], required: ["name"], undo: true),
            action("space.set_appearance", "Set a space's background", "space", ["color": string, "colors": ["type": "array", "items": string, "minItems": 0, "maxItems": 6], "grain": ["type": "number", "minimum": 0, "maximum": 1]], required: ["color"], undo: true),
            action("space.switch", "Show a space", "space", [:], undo: true),
            action("space.delete", "Delete a space and its local data", "space", [:], permission: "confirm"),
            action("tabs.pin", "Pin a tab", "tab", ["value": ["type": "boolean"]], required: ["value"], undo: true),
            action("tabs.rename", "Rename a tab", "tab", ["name": string], required: ["name"], undo: true),
            action("tabs.move", "Move selected tabs, or a whole folder with its folders, to a space", "space",
                   ["tabs": ["type": "array", "items": string, "minItems": 1, "maxItems": 50], "folder": string], undo: true, permission: "confirm_if_sign_ins_change"),
            action("tabs.reorder", "Reorder the current space's user tabs", "space", ["tabs": ["type": "array", "items": string, "minItems": 1, "maxItems": 50]], required: ["tabs"], undo: true, permission: "ask_if_user_tabs"),
            // The user's tabs closed when they ask ("close my YouTube
            // tabs"), as one batch Undo brings back where each stood.
            action("tabs.close", "Close the user's tabs; Undo brings them all back where they were", "space",
                   ["tabs": ["type": "array", "items": string, "minItems": 1, "maxItems": NativeActions.closeLimit],
                    "includePinned": ["type": "boolean", "description": "Only when the user named the pinned or kept tabs themselves. Those are put to sleep in their places, as ⌘W does, not removed"]],
                   required: ["tabs"], undo: true, permission: "none"),
            action("tabs.group", "Keep selected tabs in a new folder", "space", ["tabs": ["type": "array", "items": string, "minItems": 1, "maxItems": 50], "name": string], required: ["tabs", "name"], undo: true, permission: "ask_if_user_tabs"),
            // The column's Move to Folder, Move Out of Folder and Remove
            // Folder, Keep Tabs: the tabs stay open, where they are kept.
            action("tabs.move_to_folder", "Move tabs into a folder", "folder", ["tabs": ["type": "array", "items": string, "minItems": 1, "maxItems": 50]], required: ["tabs"], undo: true, permission: "ask_if_user_tabs"),
            action("tabs.move_out_of_folder", "Move tabs out of their folders, keeping them open", "space", ["tabs": ["type": "array", "items": string, "minItems": 1, "maxItems": 50], "oneStep": ["type": "boolean"]], required: ["tabs"], undo: true, permission: "ask_if_user_tabs"),
            action("folder.ungroup", "Ungroup a folder: remove it and keep its tabs open", "folder", [:], undo: true, permission: "ask_if_user_tabs"),
            action("site.set_zoom", "Set this site's zoom", "tab", ["value": ["type": "number", "minimum": 0.4, "maximum": 3]], required: ["value"], undo: true),
            // Settings › Spaces › Air Traffic Control: where a site's links go.
            action("links.set_route", "Open a site's links in a space, as Settings › Spaces' Air Traffic Control does", "application",
                   ["site": ["type": "string", "maxLength": 160, "description": "linear.app (the site and its subdomains), docs.google.com/spreadsheets (pages under a path), or a *pattern*"],
                    "space": ["type": "string", "maxLength": 160, "description": "A space id from native_context, or recent for the space on screen"],
                    "skipSmallWindow": ["type": "boolean", "description": "true: this site's links from other apps open in the main window, never a small window; false: as Small Window's setting says. Omitted keeps the rule's choice"]],
                   required: ["site", "space"], undo: true),
            action("links.remove_route", "Remove a site's Air Traffic Control rule", "application",
                   ["site": ["type": "string", "maxLength": 160]], required: ["site"], undo: true),
            action("links.set_default_space", "Set the space links from other apps open in when no rule matches", "application",
                   ["space": ["type": "string", "maxLength": 160, "description": "A space id, recent for the space on screen, or empty for none"]], required: ["space"], undo: true),
            // A site's own settings, by its host, as Settings' lists keep them.
            action("site.set_dark", "Keep a site light, or dark, whatever Dark pages says", "application",
                   ["site": ["type": "string", "maxLength": 160, "description": "A host such as github.com"],
                    "value": ["type": "string", "enum": ["light", "dark", "auto"], "description": "auto: as Dark pages decides for every site"]],
                   required: ["site", "value"], undo: true),
            action("site.keep_awake", "Never put a site's tabs to sleep (Settings › Tabs › Always keep these sites awake)", "application",
                   ["site": ["type": "string", "maxLength": 160], "value": ["type": "boolean"]], required: ["site", "value"], undo: true),
            action("pages.set_fonts", "Set default website fonts", "application", ["size": ["type": "integer", "minimum": 9, "maximum": 72], "minimum": ["type": "integer", "minimum": 0, "maximum": 72], "standard": string, "serif": string, "sans": string, "fixed": string], undo: true),
            action("mail.connect", "Connect Gmail", "application", ["email": string], permission: "user_oauth"),
            action("mail.reconnect", "Reconnect Gmail", "mailAccount", [:], permission: "user_oauth"),
            action("mail.disconnect", "Disconnect Gmail and remove its local mail and drafts", "mailAccount", [:], permission: "confirm"),
            action("live.add", "Add a live folder in the current space", "application",
                   ["source": ["type": "string", "enum": NativeActions.liveSources], "name": string, "address": ["type": "string", "maxLength": 160]],
                   required: ["source"], permission: "ask_in_ask_mode"),
            action("live.follow_repo", "Follow a GitHub repository's open pull requests in a live folder", "application",
                   ["repository": string], required: ["repository"], permission: "ask_in_ask_mode"),
            action("live.set", "Change a live folder's name, lists, repositories or time window", "liveFolder",
                   ["name": string, "show": ["type": "array", "items": string, "minItems": 1, "maxItems": 20],
                    "hidden": ["type": "array", "items": string, "minItems": 0, "maxItems": 50], "days": ["type": "integer", "enum": [0, 1, 7, 30]]], undo: true),
            action("live.update", "Update a live folder now", "liveFolder", [:]),
            action("live.stop", "Stop updating a live folder; its tabs stay as a plain folder", "liveFolder", [:], permission: "confirm"),
            action("mail.set_enabled", "Show or hide Mail without deleting accounts", "application", ["value": ["type": "boolean"]], required: ["value"], undo: true),
            action("mail.set_notify", "Set what an account's new mail notifies: off, needs (what needs you) or inbox (everything)", "mailAccount",
                   ["value": ["type": "string", "enum": MailNotify.Mode.allCases.map(\.rawValue)]], required: ["value"], undo: true),
            action("mail.set_read_statuses", "Turn an account's read statuses on or off (a tiny picture in sent mail tells when it was opened)", "mailAccount",
                   ["value": ["type": "boolean"]], required: ["value"], undo: true, permission: "confirm")
        ] + (EngineRules.available ? [
            action("site.set_engine", "Open a site in Chromium or WebKit; new tabs and tabs waking take it", "application",
                   ["site": ["type": "string", "maxLength": 160, "description": "The exact host, as the address shows it: www.youtube.com"],
                    "value": ["type": "string", "enum": ["chromium", "webKit", "default"], "description": "default: the built-in rule or the default engine"]],
                   required: ["site", "value"], undo: true)
        ] : []).map { descriptor in var descriptor = descriptor; descriptor["version"] = version; return descriptor }
    }

    /// Settings rows only the user changes there, by decision: flows (bring
    /// in, connect, add), pages that only show, the Keep Mac Awake switch
    /// (it turns Open at Login on too), models and their accounts. A row in
    /// none of the lists fails NativeControlTests, so a new row is classified
    /// when it lands rather than answered with steps by hand (feedback #84).
    static let uiOnly: Set<String> = [
        "show-yab", "experimental-notes", "notes-root", "notes-new", "notes-daily", "notes-writing", "shield-lists", "experimental-mail",
        "experimental-requests", "experimental-menu-commands", "agents-row", "site-search", "quick-action:new-document", "quick-action:new-meeting",
        "reachable", "bring-in", "engine-default", "bring-tabs", "import-firefox", "import-bookmarks-file", "import-history-file", "other-history",
        "import-extensions", "agents-ask-sound", "dev-agents-allowed", "agents-claude", "agents-codex", "agents-cursor", "agents-details",
        "dev-measure", "dev-servers", "dev-command", "dev-claude", "dev-codex", "dev-mcp", "agents-skills", "agents-model-tasks",
        "agents-model-commands", "agents-model-drafts", "agents-model-field", "models-add", "models-mac", "models-lists", "memory-notes",
        "memory-finder", "skills-new", "skills-yours", "skills-built-in", "space-dots", "field-size", "reading-mode", "site-notifications",
        "reader-customize", "reader-colors", "browser-look", "page-kept", "field-fallbacks", "field-sections", "frequent-reach", "pins", "boosts",
        "boost-list", "boosts-sign-ins", "add-extension", "mail-all-accounts", "mail-default", "mail-sorting", "mail-splits", "mail-ahead-consent",
        "use-yab-passwords", "connect-password-manager", "never", "bring-cards", "drives", "by-site", "agents-drives", "save-to", "sync-devices",
        "safe-browsing", "your-history-open", "history", "capture", "updates", "feedback", "community", "credits", "thanks", "acknowledgements",
        "invite", "invite-message", "invite-icons", "best-friend", "best-color", "best-shares", "best-icon", "best-message", "welcome"
    ]

    static func classification(_ item: SettingsItem) -> String {
        if NativeSetting.all.contains(where: { $0.id == item.id }) { return "read_write" }
        if controlled.contains(item.id) { return "user_only" }
        if ["mail", "mail-accounts", "mail-notify", "mail-reads", "snippets-list"].contains(item.id) { return "operation" }
        if ["page-font-size", "page-fonts", "page-minimum-font", "gradient"].contains(item.id) { return "read_write" }
        if ["spaces", "space-list", "add-space", "live-folders-add", "live-folders-repo", "link-routes", "link-routes-default", "awake-sites"].contains(item.id) { return "operation" }
        return "ui_only"
    }

    static func validate(_ arguments: [String: NativeValue], descriptor: [String: Any]) throws {
        let schema = descriptor["parameters"] as? [String: Any] ?? [:]
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        guard Set(arguments.keys).isSubset(of: Set(properties.keys)), (schema["required"] as? [String] ?? []).allSatisfy({ arguments[$0] != nil }) else {
            throw NativeFailure("invalid_arguments", "Missing or unknown action parameters")
        }
        for (key, value) in arguments {
            let rule = properties[key] ?? [:]
            switch (rule["type"] as? String, value) {
            case ("boolean", .bool): break
            case ("string", .string(let text)):
                guard text.count <= (rule["maxLength"] as? Int ?? 160), !text.contains("\0") else { throw NativeFailure("invalid_arguments", "\(key) is too long") }
                if let options = rule["enum"] as? [String], !options.contains(text) { throw NativeFailure("invalid_arguments", "Unknown \(key)") }
            case ("number", .number(let n)), ("integer", .number(let n)):
                guard n.isFinite, n >= ((rule["minimum"] as? NSNumber)?.doubleValue ?? -.infinity), n <= ((rule["maximum"] as? NSNumber)?.doubleValue ?? .infinity),
                      rule["type"] as? String != "integer" || n.rounded() == n else { throw NativeFailure("invalid_arguments", "\(key) is outside its allowed range") }
                if let options = rule["enum"] as? [Int], !options.map(Double.init).contains(n) { throw NativeFailure("invalid_arguments", "Unknown \(key)") }
            case ("array", .array(let values)):
                guard values.count >= (rule["minItems"] as? Int ?? 0), values.count <= (rule["maxItems"] as? Int ?? 50), values.allSatisfy({ if case .string(let s) = $0 { return s.count <= 160 }; return false }) else { throw NativeFailure("invalid_arguments", "Invalid \(key) list") }
            default: throw NativeFailure("invalid_arguments", "Wrong type for \(key)")
            }
        }
    }
}
