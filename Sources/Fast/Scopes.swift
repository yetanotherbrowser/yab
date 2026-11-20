import SwiftUI
import WebKit

// Searching one site from the field, the way Arc and Chrome do it: type the
// site's name, "youtube", "yt", or anything the field finishes as
// youtube.com, and Tab. The field becomes YouTube's, as a place of the
// field's own is: the way back at its head, YouTube's mark and name at its
// foot, its edge in the site's color, and Return asks
// YouTube instead of the engine. ⌫ in the empty field, or Escape, gives the
// field back as it was. A site's alias and a space does the same, as in
// Chrome, while Settings › Field › Sites › Keyboard shortcut is Space or Tab
// (Chrome's default); at Tab only Tab does (`spaced`, register 2668).
//
// A few dozen sites are known from the start. Any other site that says how
// it is searched (an OpenSearch description, the thing Chrome reads for the
// same purpose) is learned the first time you are on it, and offered for
// Tab once you type its name.

struct Scope: Codable, Hashable, Identifiable {
    /// Which search this is: what its keyword, address, on or off and
    /// what was asked of it are kept under. The site's host for the app's
    /// own and the learned, one search a site. A search of your own is
    /// known by the address it was added with, so one host can have many,
    /// as internal tools under one host on different paths do, the way
    /// Chrome keeps a search engine per keyword, not per host (#2027).
    var id: String
    /// The site a search of your own is on, as the field writes it:
    /// tools.example.com. Nil when the id is the site, as it is for the
    /// app's own, the learned, and those of your own kept before #2027.
    var site: String?
    var name: String
    /// The results page, `%s` where the words go.
    var template: String
    /// What typed whole names it, besides its name and its host.
    var aliases: [String] = []
    /// Other hosts the field may finish that are the same site.
    var hosts: [String] = []
    /// The site's color, #RRGGBB. Nil for one learned without a color of
    /// its own: its icon's is used.
    var color: String?
    /// Learned from the site, not one of the app's own.
    var learned = false
    /// Added by hand in Settings › Search. Optional so files written
    /// before it was kept still read.
    var own: Bool?
    /// An extension's keyword (chrome.omnibox, ExtensionOmnibox.swift):
    /// the words go to the extension, not to a results page.
    var extensionID: String?

    /// One that can be removed: learned or added, not the app's own.
    var removable: Bool { learned || own == true }

    /// The site, as the field writes it: youtube.com.
    var host: String { site ?? id }

    /// Every host that is this site.
    var allHosts: [String] { [host] + hosts }

    var home: URL? { extensionID == nil ? URL(string: "https://" + host + "/") : nil }

    func url(for words: String) -> URL? { Engine.url(for: words, template: template) }

    /// The words a results page of this site was asked, if the address is
    /// one: a query item that holds them, or the rest of a path after the
    /// part the template fixes.
    func words(in url: URL) -> String? {
        guard let host = url.host()?.lowercased(),
              allHosts.contains(where: { host == $0 || host == "www." + $0 || host.hasSuffix("." + $0) }),
              let shape = URLComponents(string: template.replacingOccurrences(of: "%s", with: Scope.mark))
        else { return nil }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var found: String?
        if let name = shape.queryItems?.first(where: { $0.value == Scope.mark })?.name {
            found = parts?.percentEncodedQueryItems?.first(where: { $0.name.removingPercentEncoding == name })?.value
        } else if let at = shape.path.range(of: Scope.mark) {
            let head = String(shape.path[..<at.lowerBound])
            let path = url.path()
            if !head.isEmpty, path.hasPrefix(head) {
                found = String(path.dropFirst(head.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
        }
        // A plus written in the address is a space, as a form sends one; a
        // plus the words had is %2B. Read after decoding, both were spaces,
        // and "c++ tutorial" was remembered as "c   tutorial".
        let words = found?.replacingOccurrences(of: "+", with: " ").removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return words.isEmpty ? nil : words
    }

    private static let mark = "YABSCOPEWORDS"

    // MARK: - color

    /// The site's color, made to show on the field it is drawn on: a site
    /// that is black is lifted on a dark field, one that is near white
    /// deepened on a light one.
    @MainActor func tint(dark: Bool) -> Color {
        let base = color.flatMap(Scope.parse) ?? Scopes.iconColor(self) ?? NSColor(Palette.muted)
        let rgb = base.usingColorSpace(.sRGB) ?? base
        let light = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        if dark, light < 0.3 { return Color(nsColor: rgb.blended(withFraction: 0.55, of: .white) ?? rgb) }
        if !dark, light > 0.8 { return Color(nsColor: rgb.blended(withFraction: 0.35, of: .black) ?? rgb) }
        return Color(nsColor: rgb)
    }

    @MainActor var icon: NSImage? {
        if let extensionID { return Extensions.shared.icon(for: ExtensionExternal.parts(extensionID).id, side: 16) }
        for host in allHosts {
            if let hit = Favicons.shared.cached(host) ?? Favicons.shared.cached("www." + host) { return hit }
        }
        return nil
    }

    var letter: String { String(name.prefix(1)).uppercased() }

    static func parse(_ hex: String) -> NSColor? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// An icon's color: the most colorful of its pixels, weighed by how
    /// colorful they are, so a red mark on white is red and not pink.
    static func average(of image: NSImage?) -> NSColor? {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.5 else { continue }
            let pr = Double(pixels[i]) / 255 / a, pg = Double(pixels[i + 1]) / 255 / a, pb = Double(pixels[i + 2]) / 255 / a
            let chroma = max(pr, pg, pb) - min(pr, pg, pb)
            let w = 0.05 + chroma * chroma
            r += pr * w; g += pg * w; b += pb * w; weight += w
        }
        guard weight > 0 else { return nil }
        return NSColor(srgbRed: r / weight, green: g / weight, blue: b / weight, alpha: 1)
    }
}

/// The sites the field can search, the app's own and the learned, which
/// are on, and the words last asked of each.
@MainActor
enum Scopes {
    static let offKey = "scopes.off"

    /// Every site that can be searched, the app's own first.
    /// Sites are learned as they are visited, and what was asked of a site
    /// is kept and offered again, with no switch for either
    /// (2026-10-13). Still set from the old settings, no longer read.
    static var learning = true
    static var recalling = true

    static let keywordsKey = "scopes.keywords"
    static let templatesKey = "scopes.templates"

    private static var fixtureSettings: UserDefaults?
    private static var settings: UserDefaults { fixtureSettings ?? Store.settings }

    /// Exercise the real manual-add/edit path without saved sites, defaults
    /// or icon requests escaping a unit-test fixture.
    static func withSitesForTesting(_ defaults: UserDefaults, _ body: () throws -> Void) rethrows {
        precondition(Store.testing && Store.unitTests && fixtureSettings == nil)
        let previous = memory, previousAll = allCache, previousOn = onCache
        fixtureSettings = defaults
        memory = Memory()
        changed()
        defer {
            memory = previous
            fixtureSettings = nil
            allCache = previousAll
            onCache = previousOn
        }
        try body()
    }

    /// Every site that can be searched, the app's own first, each as
    /// Settings has it: its keyword and results page as you set them.
    static var all: [Scope] {
        if let made = allCache { return made }
        let keywords = settings.dictionary(forKey: keywordsKey) as? [String: String] ?? [:]
        let templates = settings.dictionary(forKey: templatesKey) as? [String: String] ?? [:]
        let made = (preset + memory.learned).map { scope -> Scope in
            var scope = scope
            if let keyword = keywords[scope.id] { scope.aliases = keyword.isEmpty ? [] : [keyword] }
            if let template = templates[scope.id], Engine.accepts(template) { scope.template = template }
            return scope
        }
        allCache = made
        return made
    }

    private static var allCache: [Scope]?

    /// Something about the sites changed: the lists are made again.
    private static func changed() {
        allCache = nil
        onCache = nil
    }

    /// The keyword a site answers to besides its name; empty for none.
    static func setKeyword(_ keyword: String, for scope: Scope) {
        let clean = Scopes.clean(keyword)
        guard aliasProblem(clean, for: scope) == nil else { return }
        var keywords = settings.dictionary(forKey: keywordsKey) as? [String: String] ?? [:]
        keywords[scope.id] = clean
        settings.set(keywords, forKey: keywordsKey)
        changed()
    }

    /// An alias as it is kept: lowercased, no spaces.
    static func clean(_ keyword: String) -> String {
        keyword.trimmingCharacters(in: .whitespaces).lowercased().filter { !$0.isWhitespace }
    }

    /// Why a word can't be this site's alias, or nil if it can: it has to
    /// be a word, letters, digits, a dash or a dot, and not another site's
    /// alias or name already, or typing it would find either.
    static func aliasProblem(_ keyword: String, for scope: Scope) -> String? {
        let word = clean(keyword)
        guard !word.isEmpty else { return nil }
        if word.contains(where: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }) {
            return "Only letters, digits, - and ."
        }
        if let other = all.first(where: { $0.id != scope.id && ($0.aliases.contains(word) || $0.name.lowercased() == word || $0.host == word) }) {
            return "Already \(other.name)"
        }
        if let action = QuickActions.shared.actions.first(where: { $0.enabled && $0.alias == word }) {
            return "Already \(action.name)"
        }
        if let owner = ExtensionCommands.aliasOwner(word) { return "Already \(owner)" }
        return nil
    }

    /// Where a site sends the words, `%s` for them. The app's own
    /// again when it is the same as the app's own.
    static func setTemplate(_ template: String, for scope: Scope) {
        var templates = settings.dictionary(forKey: templatesKey) as? [String: String] ?? [:]
        let original = (preset + memory.learned).first { $0.id == scope.id }?.template
        templates[scope.id] = template == original ? nil : template
        settings.set(templates, forKey: templatesKey)
        changed()
    }

    /// The search Add Site would make of these fields, before it is kept:
    /// what the card checks its keyword against. Nil for an address that
    /// can't be one.
    static func draft(name: String, template: String) -> Scope? {
        guard Engine.accepts(template),
              let raw = URLComponents(string: template.replacingOccurrences(of: "%s", with: "a"))?.host?.lowercased()
        else { return nil }
        let host = raw.hasPrefix("www.") ? String(raw.dropFirst(4)) : raw
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return Scope(id: identity(for: template), site: host, name: trimmed.isEmpty ? host : trimmed,
                     template: template, own: true)
    }

    /// Who a new search of your own is: the one already sending words to
    /// this very address, which it then replaces, as a second Add of the
    /// same search changes its name and keyword; otherwise the address it
    /// is added with, made unique if an edited search still holds it. Never
    /// the host: one host has many searches (#2027).
    private static func identity(for template: String) -> String {
        let current = all
        if let same = current.first(where: { $0.removable && $0.extensionID == nil && $0.template == template }) {
            return same.id
        }
        let taken = Set(current.map(\.id))
        var id = template, n = 2
        while taken.contains(id) { id = template + "#\(n)"; n += 1 }
        return id
    }

    /// A site of your own, from Settings › Search › Add Site.
    static func add(name: String, template: String, keyword: String) -> Scope? {
        guard let scope = draft(name: name, template: template),
              aliasProblem(keyword, for: scope) == nil else { return nil }
        memory.learned.removeAll { $0.id == scope.id }
        memory.learned.append(scope)
        save()
        changed()
        // Add Site's fields are the whole new draft, including a blank
        // keyword. An earlier address edit must not override this template
        // after the same search has been replaced.
        setTemplate(template, for: scope)
        setKeyword(keyword, for: scope)
        if fixtureSettings == nil { Favicons.shared.fetch(host: scope.host) }
        return scope
    }

    /// The sites that are on, kept rather than read from the settings on
    /// every key: made again only when a site is turned on or off, learned
    /// or forgotten.
    static var on: [Scope] {
        if let made = onCache { return made }
        let made = all.filter { !off.contains($0.id) }
        onCache = made
        return made
    }

    private static var onCache: [Scope]?
    private static var off: Set<String> = Set(Store.settings.stringArray(forKey: offKey) ?? [])

    static func isOn(_ scope: Scope) -> Bool { !off.contains(scope.id) }

    static func set(_ scope: Scope, on: Bool) {
        if on { off.remove(scope.id) } else { off.insert(scope.id) }
        Store.settings.set(off.sorted(), forKey: offKey)
        changed()
    }

    /// A site's icon's color, drawn out of it once and kept, for a site
    /// with no color of its own. Not kept while it has no icon yet.
    private static var iconColors: [String: NSColor] = [:]

    static func iconColor(_ scope: Scope) -> NSColor? {
        if let known = iconColors[scope.id] { return known }
        guard let found = Scope.average(of: scope.icon) else { return nil }
        iconColors[scope.id] = found
        return found
    }

    // MARK: - which one the words name

    /// The site Tab would search, for these words and the ending the field
    /// is drawing after them. Named outright, by name, alias or host,
    /// first; then the site the ending finishes; then, with nothing being
    /// finished, a site whose name the words begin, from two letters, three
    /// for a learned one.
    static func offer(for typed: String, ending: String?) -> Scope? {
        // An extension's keyword, named whole ("to/" has a slash).
        if let keyword = ExtensionOmnibox.shared.scope(for: typed) { return keyword }
        let text = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty, !text.contains(" "), !text.contains("/") else { return nil }
        let sites = on
        if let named = sites.first(where: { scope in
            scope.allHosts.contains(text) || scope.aliases.contains(text) || key(scope.name) == text || keyword(scope) == text
        }) { return named }
        if let ending {
            let whole = (text + ending.lowercased())
            let host = String(whole.split(separator: "/").first ?? "")
            return sites.first { $0.allHosts.contains(host) }
        }
        return sites.first { scope in
            let least = scope.learned ? 3 : 2
            guard text.count >= least else { return false }
            return key(scope.name).hasPrefix(text) || keyword(scope).hasPrefix(text) || scope.host.hasPrefix(text)
        }
    }

    // MARK: - Space, as well as Tab

    /// Settings › Field › Sites › Keyboard shortcut: "Space or
    /// Tab" (on, the default) or "Tab" (off), whether a space after a
    /// site's alias starts that site's search as Tab does
    /// (omnibox.keyword_space_triggering_enabled).
    static let spaceKey = "field.keywordSpace"
    static var spaceStarts: Bool { settings.object(forKey: spaceKey) as? Bool ?? true }

    /// The site a space just typed starts, and the words its field begins
    /// with, decided as Chromium's omnibox decides it
    /// (OmniboxEditModel::ShouldAcceptKeywordAfterInsertingSpaceAtEnd and
    /// ShouldAcceptKeywordAfterInsertingSpaceInMiddle): the whole of an
    /// alias and then a space at the end ("yt " → YouTube, nothing in its
    /// field yet), or a space put in right after an alias that begins the
    /// words, the rest of them as they were ("yt|cats" → YouTube, "cats").
    /// Only an alias, the keyword in Sites' table or an extension's: a
    /// site's name or host, which Tab also takes, stays words ("youtube
    /// cats"), as Chromium enters on a keyword alone; so does a part of an
    /// alias ("st " for "so"). `caret` is where the caret is after the
    /// space, in the editor's UTF-16 count. A paste is never this, and is
    /// left out by the caller, as Chromium leaves it out.
    static func spaced(from old: String, to new: String, caret: Int) -> (scope: Scope, words: String)? {
        let text = new as NSString
        guard spaceStarts, old != new, caret >= 2, caret <= text.length,
              ["\u{20}", "\u{3000}"].contains(text.substring(with: NSRange(location: caret - 1, length: 1))) else { return nil }
        // One word before the space and nothing before it: "yt", not
        // " yt", "yt  " or "go yt".
        let head = text.substring(to: caret - 1)
        guard !head.contains(where: \.isWhitespace) else { return nil }
        let rest = text.substring(from: caret)
        // In the middle, only a space put in: the words before it as they were.
        if !rest.isEmpty {
            let was = old as NSString
            guard was.length >= caret, was.substring(to: caret - 1) == head else { return nil }
        }
        guard let scope = aliased(head) else { return nil }
        return (scope, rest)
    }

    /// The site this word is the alias of: the keyword in Sites' table of
    /// one that is on, or an extension's keyword.
    static func aliased(_ word: String) -> Scope? {
        let word = word.lowercased()
        guard !word.isEmpty else { return nil }
        if let keyword = ExtensionOmnibox.shared.scope(for: word) { return keyword }
        return on.first { $0.aliases.contains(word) }
    }

    /// A name as it would be typed: lowercased, without spaces.
    private static func key(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace }
    }

    /// The site's name without its ending: habr for habr.com.
    static func keyword(_ scope: Scope) -> String {
        let parts = scope.host.split(separator: ".")
        return parts.count > 1 ? parts.dropLast().joined(separator: ".") : scope.host
    }

    // MARK: - what was asked

    /// The words last asked of this site, newest first, those that begin
    /// with, or have a word beginning with, what is typed.
    static func recent(_ scope: Scope, matching typed: String, limit: Int = 4) -> [String] {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        return (memory.asked[scope.id] ?? [])
            .filter { words in
                guard !needle.isEmpty else { return true }
                let lower = words.lowercased()
                return lower != needle && (lower.hasPrefix(needle) || lower.contains(" " + needle))
            }
            .prefix(limit)
            .map { $0 }
    }

    /// A page landed on: if it is a results page of a site the field
    /// searches, what it was asked is remembered for that site.
    static func landed(on url: URL) {
        for scope in all {
            guard let words = scope.words(in: url) else { continue }
            asked(words, of: scope)
            return
        }
    }

    /// These words asked of the site, newest first. From the field as well
    /// as from its results page: a site that goes straight to what was
    /// asked, Wikipedia to its article, never shows one.
    static func asked(_ words: String, of scope: Scope) {
        var list = memory.asked[scope.id] ?? []
        list.removeAll { $0.lowercased() == words.lowercased() }
        list.insert(words, at: 0)
        memory.asked[scope.id] = Array(list.prefix(20))
        save()
    }

    static func forget(_ scope: Scope) {
        memory.learned.removeAll { $0.id == scope.id }
        memory.asked[scope.id] = nil
        var templates = Store.settings.dictionary(forKey: templatesKey) as? [String: String] ?? [:]
        templates[scope.id] = nil
        Store.settings.set(templates, forKey: templatesKey)
        changed()
        save()
    }

    /// Everything asked of every site, as the history is cleared.
    static func forgetAsked() {
        memory.asked = [:]
        save()
    }

    // MARK: - learning a site

    /// Hosts already asked this session, whatever they answered.
    private static var asked: Set<String> = []

    /// A page finished loading: if its site isn't one the field searches
    /// yet, the page is asked whether it says how it is searched. Once a
    /// session per site, and never from a private tab.
    static func learn(from tab: Tab) {
        guard !tab.shy, !tab.bench, let url = tab.address, url.scheme == "https",
              let raw = url.host()?.lowercased() else { return }
        let host = raw.hasPrefix("www.") ? String(raw.dropFirst(4)) : raw
        guard !asked.contains(host), !all.contains(where: { scope in
            scope.allHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }) else { return }
        asked.insert(host)
        let probe = """
        (() => {
          const link = document.querySelector('link[rel="search"][type="application/opensearchdescription+xml"]');
          const meta = document.querySelector('meta[name="theme-color"]');
          return { href: link ? link.href : '', title: link ? (link.title || '') : '', theme: meta ? (meta.content || '') : '' };
        })()
        """
        tab.page.run(probe) { result in
            MainActor.assumeIsolated {
                guard let found = (try? result.get()) as? [String: String], let href = found["href"], !href.isEmpty,
                      let description = URL(string: href), description.scheme == "https" else { return }
                let theme = found["theme"].flatMap { Scope.parse($0) != nil ? $0 : nil }
                Task { await fetch(description, host: host, title: found["title"] ?? "", color: theme) }
            }
        }
    }

    private static func fetch(_ description: URL, host: String, title: String, color: String?) async {
        var request = URLRequest(url: description, timeoutInterval: 8)
        request.setValue("application/opensearchdescription+xml", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.ephemeralFetcher.data(for: request),
              data.count < 200_000 else { return }
        let reader = OpenSearch()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), let raw = reader.template, let template = OpenSearch.template(from: raw) else { return }
        // Only a search of this site: a description that sends the words
        // somewhere else is not this site's to give.
        guard let target = URLComponents(string: template.replacingOccurrences(of: "%s", with: "a"))?.host?.lowercased(),
              target == host || target == "www." + host || target.hasSuffix("." + host) || host.hasSuffix("." + target)
        else { return }
        var name = reader.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.count > 30 { name = title.isEmpty || title.count > 30 ? host : title }
        let scope = Scope(id: host, name: name, template: template, color: color, learned: true)
        guard !all.contains(where: { $0.id == host || $0.host == host }) else { return }
        memory.learned.append(scope)
        if memory.learned.count > 200 { memory.learned.removeFirst(memory.learned.count - 200) }
        changed()
        save()
        Favicons.shared.fetch(host: host)
    }

    // MARK: - the app's own

    /// The language the reader reads, for the sites that are in one.
    private static var language: String {
        Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
    }

    static let preset: [Scope] = [
        Scope(id: "youtube.com", name: "YouTube", template: "https://www.youtube.com/results?search_query=%s",
              aliases: ["yt"], hosts: ["m.youtube.com", "youtu.be"], color: "#FF0033"),
        Scope(id: "google.com", name: "Google", template: "https://www.google.com/search?q=%s",
              color: "#4285F4"),
        Scope(id: "chatgpt.com", name: "ChatGPT", template: "https://chatgpt.com/?q=%s",
              aliases: ["gpt"], hosts: ["chat.openai.com"], color: "#10A37F"),
        Scope(id: "claude.ai", name: "Claude", template: "https://claude.ai/new?q=%s", color: "#D97757"),
        Scope(id: "perplexity.ai", name: "Perplexity", template: "https://www.perplexity.ai/search?q=%s",
              aliases: ["pplx"], color: "#20808D"),
        Scope(id: "github.com", name: "GitHub", template: "https://github.com/search?q=%s",
              aliases: ["gh"], color: "#8250DF"),
        Scope(id: "wikipedia.org", name: "Wikipedia", template: "https://\(language).wikipedia.org/w/index.php?search=%s",
              aliases: ["wiki"], color: "#72777D"),
        Scope(id: "maps.google.com", name: "Google Maps", template: "https://www.google.com/maps/search/%s",
              aliases: ["maps", "gmaps"], color: "#1A73E8"),
        Scope(id: "images.google.com", name: "Google Images", template: "https://www.google.com/search?tbm=isch&q=%s",
              aliases: ["images", "img"], color: "#4285F4"),
        Scope(id: "translate.google.com", name: "Google Translate", template: "https://translate.google.com/?sl=auto&tl=\(language)&text=%s&op=translate",
              aliases: ["translate", "tr"], color: "#1A73E8"),
        Scope(id: "mail.google.com", name: "Gmail", template: "https://mail.google.com/mail/u/0/#search/%s", color: "#EA4335"),
        Scope(id: "drive.google.com", name: "Google Drive", template: "https://drive.google.com/drive/search?q=%s",
              aliases: ["drive"], color: "#1FA463"),
        Scope(id: "reddit.com", name: "Reddit", template: "https://www.reddit.com/search/?q=%s",
              hosts: ["old.reddit.com"], color: "#FF4500"),
        Scope(id: "x.com", name: "X", template: "https://x.com/search?q=%s",
              aliases: ["twitter"], hosts: ["twitter.com"], color: "#000000"),
        Scope(id: "linkedin.com", name: "LinkedIn", template: "https://www.linkedin.com/search/results/all/?keywords=%s",
              color: "#0A66C2"),
        Scope(id: "stackoverflow.com", name: "Stack Overflow", template: "https://stackoverflow.com/search?q=%s",
              aliases: ["so"], color: "#F48024"),
        Scope(id: "developer.mozilla.org", name: "MDN", template: "https://developer.mozilla.org/search?q=%s",
              color: "#1B1B1B"),
        Scope(id: "npmjs.com", name: "npm", template: "https://www.npmjs.com/search?q=%s", color: "#CB3837"),
        Scope(id: "developer.apple.com", name: "Apple Developer", template: "https://developer.apple.com/search/?q=%s",
              aliases: ["adev"], color: "#0071E3"),
        Scope(id: "news.ycombinator.com", name: "Hacker News", template: "https://hn.algolia.com/?q=%s",
              aliases: ["hn"], hosts: ["hn.algolia.com"], color: "#FF6600"),
        Scope(id: "producthunt.com", name: "Product Hunt", template: "https://www.producthunt.com/search?q=%s",
              aliases: ["ph"], color: "#DA552F"),
        Scope(id: "amazon.com", name: "Amazon", template: "https://www.amazon.com/s?k=%s",
              color: "#FF9900"),
        Scope(id: "spotify.com", name: "Spotify", template: "https://open.spotify.com/search/%s",
              hosts: ["open.spotify.com"], color: "#1DB954"),
        Scope(id: "music.apple.com", name: "Apple Music", template: "https://music.apple.com/search?term=%s",
              aliases: ["music"], color: "#FA2D48"),
        Scope(id: "twitch.tv", name: "Twitch", template: "https://www.twitch.tv/search?term=%s", color: "#9146FF"),
        Scope(id: "netflix.com", name: "Netflix", template: "https://www.netflix.com/search?q=%s", color: "#E50914"),
        Scope(id: "imdb.com", name: "IMDb", template: "https://www.imdb.com/find/?q=%s", color: "#F5C518"),
        Scope(id: "pinterest.com", name: "Pinterest", template: "https://www.pinterest.com/search/pins/?q=%s",
              color: "#E60023"),
        Scope(id: "dribbble.com", name: "Dribbble", template: "https://dribbble.com/search/%s", color: "#EA4C89"),
        Scope(id: "duckduckgo.com", name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s",
              aliases: ["ddg"], color: "#DE5833"),
    ]

    // MARK: - the file

    private struct Memory: Codable {
        var learned: [Scope] = []
        var asked: [String: [String]] = [:]
    }

    private static var file: URL { Store.file("scopes.json") }

    private static var memory: Memory = read()

    /// The file again, as sync wrote it from another Mac (SyncCenter).
    static func reload() {
        memory = read()
        changed()
    }

    private static func read() -> Memory {
        guard let data = try? Data(contentsOf: file) else { return Memory() }
        guard let decoded = decode(data) else {
            Store.quarantine(file)
            return Memory()
        }
        if decoded.separated { save() }
        return decoded.memory
    }

    /// A file's sites as they are kept, and whether any had to be given an
    /// identity of its own to be read (separate).
    private static func decode(_ raw: Data) -> (memory: Memory, separated: Bool)? {
        var data = raw
        // Sites saved while yab spelled it the British way.
        if let text = String(data: data, encoding: .utf8), text.contains("\"colour\"") {
            data = Data(text.replacingOccurrences(of: "\"colour\"", with: "\"color\"").utf8)
        }
        guard var read = try? JSONDecoder().decode(Memory.self, from: data) else { return nil }
        let separated = separate(&read)
        return (read, separated)
    }

    /// Before #2027 a search of your own was known by its host, so one
    /// added on a host the app searches itself (github.com/issues beside
    /// GitHub), or one written twice by a sync, shared its id with another:
    /// one keyword, one switch and one list of what was asked for both.
    /// Each such one is given its own identity, the address it was added
    /// with, carrying the keyword, address, switch and words it had, so
    /// nothing it did changes and no search goes. Every other search keeps
    /// its id, and with it everything kept under it. Reads neither `all`
    /// nor `memory`: it runs while the file is first read.
    private static func separate(_ memory: inout Memory) -> Bool {
        var taken = Set(preset.map(\.id))
        var keywords = settings.dictionary(forKey: keywordsKey) as? [String: String] ?? [:]
        var templates = settings.dictionary(forKey: templatesKey) as? [String: String] ?? [:]
        var moved = false
        for index in memory.learned.indices {
            let scope = memory.learned[index]
            guard taken.contains(scope.id) else { taken.insert(scope.id); continue }
            guard scope.own == true, scope.extensionID == nil else { continue }
            var id = scope.template, n = 2
            while taken.contains(id) { id = scope.template + "#\(n)"; n += 1 }
            taken.insert(id)
            let old = scope.id
            memory.learned[index].id = id
            memory.learned[index].site = scope.host
            if let keyword = keywords[old] { keywords[id] = keyword }
            if let template = templates[old] { templates[id] = template }
            if let asked = memory.asked[old] { memory.asked[id] = asked }
            if off.contains(old) { off.insert(id); Store.settings.set(off.sorted(), forKey: offKey) }
            moved = true
        }
        guard moved else { return false }
        settings.set(keywords, forKey: keywordsKey)
        settings.set(templates, forKey: templatesKey)
        return true
    }

    /// The tests: a scopes.json read as the app reads it, its sites then
    /// the fixture's (withSitesForTesting). Nil when the file can't be read.
    static func readForTesting(_ data: Data) -> Bool? {
        precondition(Store.testing && Store.unitTests && fixtureSettings != nil)
        guard let decoded = decode(data) else { return nil }
        memory = decoded.memory
        changed()
        return decoded.separated
    }

    private static var saving = false

    /// A moment after, off the main thread, once for a burst.
    private static func save() {
        guard fixtureSettings == nil else { return }
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            saving = false
            let copy = memory
            DispatchQueue.global(qos: .utility).async {
                guard let data = try? JSONEncoder().encode(copy) else { return }
                try? FileManager.default.createDirectory(at: Store.folder, withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
        }
    }
}

/// An OpenSearch description, read for its name and the results page it
/// sends words to.
private final class OpenSearch: NSObject, XMLParserDelegate {
    var name = ""
    var template: String?
    private var inName = false

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        let local = element.split(separator: ":").last.map(String.init) ?? element
        if local == "ShortName" { inName = true }
        if local == "Url", template == nil,
           (attributes["type"] ?? "text/html").lowercased().hasPrefix("text/html"),
           (attributes["method"] ?? "get").lowercased() == "get",
           let found = attributes["template"] {
            template = found
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inName { name += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if element.hasSuffix("ShortName") { inName = false }
    }

    /// The description's template in the field's own form, `%s` for the
    /// words, optional parameters left out. Nil when it asks for something
    /// else the field can't give.
    static func template(from raw: String) -> String? {
        guard raw.contains("{searchTerms}") else { return nil }
        var text = raw.replacingOccurrences(of: "{searchTerms}", with: "%s")
        // An optional parameter, {startPage?}: its pair goes, or the
        // placeholder alone when it stands in a path.
        if let pair = try? NSRegularExpression(pattern: "[?&][^=&#]+=\\{[^}]+\\?\\}") {
            text = pair.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        text = text.replacingOccurrences(of: "\\{[^}]+\\?\\}", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "{inputEncoding}", with: "UTF-8").replacingOccurrences(of: "{outputEncoding}", with: "UTF-8")
        if text.contains("&"), !text.contains("?") { text = text.replacingOccurrences(of: "&", with: "?", options: [], range: text.range(of: "&")) }
        guard !text.contains("{"), Engine.accepts(text) else { return nil }
        return text
    }
}

// MARK: - the field, searching one site

extension Browser {
    /// Tab: the field becomes the site the words name, empty, the words
    /// kept to be given back.
    @discardableResult
    func enterScope() -> Bool {
        guard query.scope == nil, let scope = query.offering else { return false }
        enter(scope, giving: typed, words: "")
        return true
    }

    /// A space typed after a site's alias, with Settings' Keyboard shortcut
    /// at Space or Tab: the field becomes that site's, as Tab makes it,
    /// with the words after the space in it (Scopes.spaced). Only in the
    /// plain field, as Tab's site is only offered there. ⌫ in its empty
    /// field gives back the alias and its space, as Chromium's does
    /// (OmniboxEditModel::ClearKeyword), so words typed on from there stay
    /// words.
    func enterScope(spacing old: String, to new: String, caret: Int) -> Bool {
        guard query.scope == nil, query.place == nil, !query.actionsPage, query.edit == nil, !query.answering,
              emojiWords == nil, let (scope, words) = Scopes.spaced(from: old, to: new, caret: caret) else { return false }
        enter(scope, giving: (new as NSString).substring(to: caret), words: words)
        return true
    }

    private func enter(_ scope: Scope, giving before: String, words: String) {
        query.before = before
        query.offering = nil
        // Before the scope is published, so the one redraw it causes has it.
        query.tints = (scope.tint(dark: false), scope.tint(dark: true))
        query.scope = scope
        if let id = scope.extensionID {
            ExtensionOmnibox.shared.started(id, in: self)
        } else {
            for host in scope.allHosts { Favicons.shared.fetch(host: host) }
        }
        picked = nil
        query.pointed = nil
        typed = words
    }

    /// ⌫ in the empty field gives back the words Tab took; Escape keeps
    /// what has been typed since, to be searched as anything else is.
    @discardableResult
    func leaveScope(restoring: Bool = false) -> Bool {
        guard let scope = query.scope else { return false }
        if let id = scope.extensionID { ExtensionOmnibox.shared.cancelled(id) }
        query.scope = nil
        picked = nil
        query.pointed = nil
        typed = restoring ? query.before : typed
        return true
    }

    /// The field put away or sent somewhere: plain again, quietly.
    func dropScope() {
        if let scope = query.scope {
            if let id = scope.extensionID { ExtensionOmnibox.shared.cancelled(id) }
            query.scope = nil
        }
        if query.offering != nil { query.offering = nil }
        // And the field's own places, and ⌘K's list.
        if query.place != nil { endAnswer(); query.place = nil }
        if query.acting != nil { query.acting = nil }
        if query.actionsPage { query.actionsPage = false }
    }

    /// What the field offers while it is one site's: the words, asked of
    /// it, and what was asked of it before that the words begin.
    func scoped(_ scope: Scope) -> [Suggestion] {
        if let id = scope.extensionID {
            // The extension hears every change and answers in its own time.
            ExtensionOmnibox.shared.changed(id, text: typed, in: self)
            return ExtensionOmnibox.shared.suggestions(id, name: scope.name, text: typed)
        }
        let text = typed.trimmingCharacters(in: .whitespaces)
        var list: [Suggestion] = []
        if !text.isEmpty, let url = scope.url(for: text) {
            list.append(Suggestion(key: text, title: scope.name, url: url, kind: .search))
        }
        for words in Scopes.recent(scope, matching: text, limit: text.isEmpty ? 4 : 3) {
            guard let url = scope.url(for: words) else { continue }
            list.append(Suggestion(key: words, title: "", url: url, kind: .asked))
        }
        // Nothing asked yet: the site's pages last been to, under what was
        // asked of it before, as Arc lists them, rather than an empty card.
        if text.isEmpty, list.count < 5 {
            for page in history.pages(on: scope.allHosts, limit: 5 - list.count) {
                list.append(Suggestion(key: page.key, title: page.title, url: page.url, kind: .visited))
            }
        }
        return list
    }

    /// Return while the field is one site's.
    func submitScoped(_ scope: Scope, _ way: Way, copyingTabs: Bool = false) -> Bool {
        if let id = scope.extensionID {
            let chosen = (query.pointed ?? picked).flatMap { offers.indices.contains($0) ? offers[$0] : nil }
            let content = chosen?.url.flatMap(ExtensionOmnibox.content(of:))?.content ?? typed
            enteredKeyword(id, content: content, way)
            return true
        }
        if let chosen = query.pointed ?? picked, offers.indices.contains(chosen) {
            let offer = offers[chosen]
            if offer.kind == .search || offer.kind == .asked, !privateBrowsing { Scopes.asked(offer.key, of: scope) }
            take(offer, way, copyingTab: copyingTabs)
            return true
        }
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard let url = text.isEmpty ? scope.home : scope.url(for: text) else { return false }
        if !text.isEmpty, !privateBrowsing { Scopes.asked(text, of: scope) }
        send(url, way)
        return true
    }
}

extension Browser {
    /// Return on an extension's keyword: the extension is told what, and
    /// how it may open it; the field goes, as after a place.
    func enteredKeyword(_ id: String, content: String, _ way: Way) {
        ExtensionOmnibox.shared.entered(id, content: content, way: way, askingNew: askingNew)
        query.scope = nil
        if query.offering != nil { query.offering = nil }
        typed = ""
        editing = false
    }
}

