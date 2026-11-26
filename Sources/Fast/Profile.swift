import Foundation

// Who you are, for forms: the things an event, a job or a sign-up asks
// that aren't an address. Your company, your title, where you are, your
// LinkedIn, X, GitHub and site, and a line and a paragraph about you.
//
// Kept as plain JSON in the browser's own folder, next to memory, and
// written by you (Autofill's You, in the box) or by an agent reading your own pages
// (the `profile` tool). A card, a password or a number that pays for
// something never goes here: those are the keychain's (Wallet, Vault).

struct Profile: Codable, Equatable {
    var name = ""
    /// "Founding designer at Tern", the line under a name.
    var headline = ""
    var company = ""
    var role = ""
    /// "Stockholm, Sweden": where you are, as you'd say it.
    var location = ""
    var linkedin = ""
    var x = ""
    var github = ""
    var website = ""
    var telegram = ""
    var instagram = ""
    /// A sentence about you.
    var bio = ""
    /// A paragraph about you, for a box that wants more.
    var about = ""
    /// What you are working on now, a line: "What are you building?"
    var working = ""
    /// "English, Swedish".
    var languages = ""
    /// "Europe/Stockholm".
    var timezone = ""
    /// Only as you gave them yourself, on a page of yours.
    var pronouns = ""
    var updated: Date?
    /// Who wrote it last: "you", "agent", "contact card".
    var source = ""
    /// Where each key came from: "LinkedIn", "contact card", "memory", "you".
    var sources: [String: String] = [:]
    /// Keys you wrote yourself: nothing else writes over them.
    var edited: Set<String> = []

    static let keys = ["name", "headline", "company", "role", "location", "linkedin", "x", "github", "website",
                       "telegram", "instagram", "bio", "about", "working", "languages", "timezone", "pronouns"]

    init() {}

    enum CodingKeys: String, CodingKey {
        case name, headline, company, role, location, linkedin, x, github, website, telegram, instagram
        case bio, about, working, languages, timezone, pronouns, updated, source, sources, edited
    }

    /// A file from before a key was added reads with that key empty.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String { ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil) ?? "" }
        name = text(.name); headline = text(.headline); company = text(.company); role = text(.role)
        location = text(.location); linkedin = text(.linkedin); x = text(.x); github = text(.github)
        website = text(.website); telegram = text(.telegram); instagram = text(.instagram); bio = text(.bio)
        about = text(.about); working = text(.working); languages = text(.languages); timezone = text(.timezone)
        pronouns = text(.pronouns); source = text(.source)
        updated = (try? c.decodeIfPresent(Date.self, forKey: .updated)) ?? nil
        sources = ((try? c.decodeIfPresent([String: String].self, forKey: .sources)) ?? nil) ?? [:]
        edited = ((try? c.decodeIfPresent(Set<String>.self, forKey: .edited)) ?? nil) ?? []
    }

    /// `edited` sorted: a set lists its members in another order in each
    /// run, and the file must read the same on every Mac (sync compares it).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name); try c.encode(headline, forKey: .headline); try c.encode(company, forKey: .company)
        try c.encode(role, forKey: .role); try c.encode(location, forKey: .location); try c.encode(linkedin, forKey: .linkedin)
        try c.encode(x, forKey: .x); try c.encode(github, forKey: .github); try c.encode(website, forKey: .website)
        try c.encode(telegram, forKey: .telegram); try c.encode(instagram, forKey: .instagram); try c.encode(bio, forKey: .bio)
        try c.encode(about, forKey: .about); try c.encode(working, forKey: .working); try c.encode(languages, forKey: .languages)
        try c.encode(timezone, forKey: .timezone); try c.encode(pronouns, forKey: .pronouns)
        try c.encodeIfPresent(updated, forKey: .updated)
        try c.encode(source, forKey: .source); try c.encode(sources, forKey: .sources)
        try c.encode(edited.sorted(), forKey: .edited)
    }

    /// Writes what is given, key by key, and says what changed and what was
    /// left because you wrote it yourself. `force`: you, from the page.
    @discardableResult
    mutating func merge(_ given: [String: String], source from: String, force: Bool = false) -> (changed: [String], kept: [String]) {
        var changed: [String] = [], kept: [String] = []
        for key in Profile.keys {
            guard let raw = given[key] else { continue }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value == self[key] {
                if force { edited.insert(key); sources[key] = value.isEmpty ? nil : "you" }
                continue
            }
            if edited.contains(key), !force { kept.append(key); continue }
            self[key] = value
            if value.isEmpty { sources[key] = nil } else { sources[key] = from }
            if force { edited.insert(key) }
            changed.append(key)
        }
        if !changed.isEmpty { source = force ? "you" : from }
        return (changed, kept)
    }

    subscript(key: String) -> String {
        get {
            switch key {
            case "name": return name
            case "headline": return headline
            case "company": return company
            case "role": return role
            case "location": return location
            case "linkedin": return linkedin
            case "x": return x
            case "github": return github
            case "website": return website
            case "telegram": return telegram
            case "instagram": return instagram
            case "bio": return bio
            case "about": return about
            case "working": return working
            case "languages": return languages
            case "timezone": return timezone
            case "pronouns": return pronouns
            default: return ""
            }
        }
        set {
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "name": name = v
            case "headline": headline = v
            case "company": company = v
            case "role": role = v
            case "location": location = v
            case "linkedin": linkedin = v
            case "x": x = v
            case "github": github = v
            case "website": website = v
            case "telegram": telegram = v
            case "instagram": instagram = v
            case "bio": bio = v
            case "about": about = v
            case "working": working = v
            case "languages": languages = v
            case "timezone": timezone = v
            case "pronouns": pronouns = v
            default: break
            }
        }
    }

    var isEmpty: Bool { Profile.keys.allSatisfy { self[$0].isEmpty } }

    /// Nothing in it but what your card in Contacts gave, often a name and
    /// a city: as good as empty for a form, while memory may know far more.
    /// Taken for empty, it would never have asked memory or you for the rest.
    var thin: Bool {
        Profile.keys.allSatisfy { self[$0].isEmpty || (sources[$0] == "contact card" && !edited.contains($0)) }
    }

    /// What an agent or the page is told: the filled keys only.
    var said: [String: String] {
        Dictionary(uniqueKeysWithValues: Profile.keys.compactMap { key in self[key].isEmpty ? nil : (key, self[key]) })
    }

    // MARK: - kept

    static var file: URL { Store.file("profile.json") }

    /// Read on the main thread and on the notes page's queue (KnowRelay):
    /// never touched but under `guard`.
    nonisolated(unsafe) private static var cached: (file: URL, profile: Profile, stamp: Date?)?
    private static let guard_ = NSLock()

    /// Read once, and again only when the file changed underneath.
    static func load(from file: URL = Profile.file) -> Profile {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        if let known = guard_.withLock({ cached }), known.file == file, known.stamp == stamp { return known.profile }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = (try? Data(contentsOf: file)).flatMap { try? decoder.decode(Profile.self, from: $0) } ?? Profile()
        guard_.withLock { cached = (file, profile, stamp) }
        return profile
    }

    /// `stamp`: whether `updated` becomes now.
    @discardableResult
    static func save(_ profile: Profile, origin: ContextOrigin = .unknown, stamp: Bool = true, to file: URL = Profile.file) -> Bool {
        ContextPrivacy.shared.transaction {
            let current = load(from: file)
            var next = profile
            if case .manual(let fields) = origin {
                next = current
                for key in fields {
                    next[key] = profile[key]; next.sources[key] = profile.sources[key]
                    if profile.edited.contains(key) { next.edited.insert(key) } else { next.edited.remove(key) }
                }
            }
            return ContextPrivacy.shared.mutate(resource: "profile", before: cells(current), after: cells(next), origin: origin) { write(next, to: file, stamp: stamp) }
        }
    }

    /// A profile as it came from another device, written as it is: its
    /// `updated` is when it changed there. Dated now, the file no longer
    /// said what its record does, and went back up as a change made here.
    @discardableResult
    static func saveSynced(_ profile: Profile, to file: URL = Profile.file) -> Bool {
        save(profile, origin: .usage, stamp: false, to: file)
    }

    static func cells(_ profile: Profile) -> [String: ContextPrivacy.Cell] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0, ContextPrivacy.Cell(value: profile[$0], source: profile.sources[$0], edited: profile.edited.contains($0))) })
    }

    private static func write(_ profile: Profile, to file: URL, stamp: Bool) -> Bool {
        var profile = profile
        if stamp { profile.updated = Date() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(profile) else { return false }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return false }
        guard_.withLock { cached = nil }
        return true
    }

    static func forget() {
        try? FileManager.default.removeItem(at: file)
        guard_.withLock { cached = nil }
    }

    // MARK: - as a box asks for it

    /// A handle out of whatever was kept: "@miralq", "miralq",
    /// "https://x.com/miralq/" all give "miralq".
    static func handle(_ kept: String) -> String {
        var t = kept.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: t.contains("://") ? t : "https://" + t), let host = url.host(), host.contains(".") {
            let parts = url.path.split(separator: "/").map(String.init)
            // linkedin.com/in/name, t.me/name, x.com/name
            if let first = parts.first {
                t = (first == "in" || first == "company") && parts.count > 1 ? parts[1] : first
            } else {
                t = ""
            }
        }
        if t.hasPrefix("@") { t.removeFirst() }
        return t
    }

    /// Where each kind of link lives, for a box that wants the whole address.
    static let homes: [String: String] = [
        "linkedin": "https://www.linkedin.com/in/", "x": "https://x.com/", "github": "https://github.com/",
        "telegram": "https://t.me/", "instagram": "https://www.instagram.com/",
    ]

    /// The value for `key` in the shape the box asks for: a handle with or
    /// without "@", or the whole address, by what its placeholder, its
    /// label, its type and its length say.
    func value(_ key: String, shape: FormField) -> String? {
        let kept = self[key]
        guard !kept.isEmpty else { return nil }
        guard let home = Profile.homes[key] else {
            if key == "website", shape.type == "url", !kept.contains("://") { return "https://" + kept }
            return kept
        }
        let handle = Profile.handle(kept)
        guard !handle.isEmpty else { return nil }
        let hint = (shape.placeholder + " " + shape.label).lowercased()
        let asksAddress = shape.type == "url" || hint.contains("http") || hint.contains(".com") || hint.contains("t.me")
            || hint.contains("url") || hint.contains("link") || hint.contains("profile")
        let asksHandle = hint.contains("@") || hint.contains("handle") || hint.contains("username") || hint.contains("user name")
        if asksHandle && !(hint.contains("http") || shape.type == "url") {
            // "@username" in the box: with the at; "username" alone: without.
            let at = shape.placeholder.contains("@") || (key == "x" || key == "instagram" || key == "telegram") && !shape.placeholder.lowercased().contains("username")
            return at ? "@" + handle : handle
        }
        if asksAddress || key == "linkedin" {
            // A box that shows the address without its scheme gets it so.
            let plain = shape.placeholder.lowercased()
            if !plain.isEmpty, !plain.contains("http"), plain.contains(".") {
                return String(home.dropFirst("https://".count)).replacingOccurrences(of: "www.", with: "") + handle
            }
            return home + handle
        }
        if shape.maxLength > 0, shape.maxLength < 20 { return handle }
        return key == "github" ? handle : "@" + handle
    }
}
