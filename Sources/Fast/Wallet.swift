import YabStore
import AppKit
import Security
import LocalAuthentication
import os

// Where cards and addresses live: the macOS keychain, beside the passwords
// (Vault.swift), as generic items under this app's own service. One item a
// card or an address, its data a small JSON record.
//
// A card's number is its secret. What can be said about a card without it,
// the brand, the last four digits, the name, when it runs out, rides in the
// item's attributes, so the list under a field and Autofill's place are drawn
// without reading a single number. The number is read when it is filled or
// shown, and only after Touch ID, every time. Its security code, when the
// page it was paid on had one, is kept beside it in the same secret, as
// Chrome keeps it, and goes out the same way: filled, or shown and copied
// after Touch ID.

struct SavedCard: Identifiable, Equatable {
    var id: String
    /// Digits only. Empty in lists: see `Wallet.number(of:)`.
    var number: String
    /// The last four digits, kept apart from the number so a list can say
    /// which card it is.
    var last4: String
    var brand: String
    var name: String
    var month: Int
    var year: Int
    var used: Date?
    var saved: Date?
    /// What the person calls it, "Travel".
    var nickname = ""
    /// The browser it was brought in from, "Chrome", or empty.
    var source = ""
    /// The site it was last paid on, "northwind.shop".
    var usedOn = ""
    /// Who issued it and its level, from its first digits (Bins).
    var issuer = ""
    var level = ""
    /// Its security code. Empty in lists, as the number is: see
    /// `Wallet.securityCode(of:)`.
    var csc = ""
    /// The id of the kept address it is billed to, or empty for none.
    var billing = ""
    /// Whether a security code is kept with it, said without reading it.
    var keepsCode = false

    /// Its name in the box's short list: Amex, not American Express.
    var shortTitle: String { brand == "American Express" ? "Amex ending in \(last4)" : title }

    /// "Visa ending in 4242", how every list names it.
    var title: String { "\(brand) ending in \(last4)" }
    /// "08/28".
    var expiry: String { String(format: "%02d/%02d", month, year % 100) }
    var expired: Bool {
        let now = Calendar.current.dateComponents([.year, .month], from: Date())
        return (year, month) < (now.year ?? 0, now.month ?? 0)
    }
    /// Months left before it runs out: 0 in its last month, 1 the month
    /// before, negative once it has.
    var monthsLeft: Int {
        let now = Calendar.current.dateComponents([.year, .month], from: Date())
        return (year - (now.year ?? 0)) * 12 + month - (now.month ?? 0)
    }
    /// "Expires next month", said in words while it is close; nil otherwise.
    var soon: String? {
        switch monthsLeft {
        case 0: return "Expires this month"
        case 1: return "Expires next month"
        default: return nil
        }
    }
    /// "Chase · Signature", what is known of who issued it.
    var from: String {
        [issuer, level].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct StreetAddress: Identifiable, Equatable, Codable {
    var id: String
    var name = ""
    var organization = ""
    /// Every line of the street, one a line: the first is the street, the
    /// rest the apartment, the suite, the floor.
    var street = ""
    var city = ""
    /// The state, the province, the region.
    var region = ""
    var postal = ""
    /// As the page or the person wrote it, "United States" or "US".
    var country = ""
    var phone = ""
    var email = ""
    var used: Date?
    var saved: Date?
    /// Where it came from, "Chrome" or "Contacts", and the site it was last
    /// shipped to. Optional, so what was kept before these reads as it was.
    var source: String?
    var usedOn: String?
    /// Where Get to Know found it, as you'd say it: "your order on
    /// nordbutik.se", "Tern's contact page" (yab://you shows it).
    var found: String?

    var line1: String { street.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? "" }
    /// "Sam R., 221 Mission St", how a list names it.
    var title: String {
        [name, line1].filter { !$0.isEmpty }.joined(separator: ", ")
    }
    /// "San Francisco 94105", the line under it.
    var place: String {
        [city, postal].filter { !$0.isEmpty }.joined(separator: " ")
    }
    /// Whether it says enough to be worth keeping: a street and where it is.
    var whole: Bool { !line1.isEmpty && (!city.isEmpty || !postal.isEmpty) }
    /// Its mark in a list: a building for a work address, as Get to Know
    /// Me keeps one, a house for any other.
    var mark: String { source?.hasSuffix(", work") == true ? "building.2" : "house" }

    // MARK: how a list under a field says it

    /// "690 Long Bridge St": the street as a list names it, no building's
    /// name before the number, no apartment after it, the long words short.
    var listStreet: String { listParts.street }
    /// "Apt 1210", kept apart so a list never cuts it: in one building it is
    /// all that tells two addresses apart. With a building too, the last.
    var listUnit: String { listParts.unit }
    /// What a name, an email or a phone box shows of it, nil for any other
    /// box (`WalletField.box`) or when it holds none.
    func listOwn(_ box: String) -> String? {
        let words = name.split(separator: " ").map(String.init)
        let own: String
        switch box {
        case "name": own = name
        case "given": own = words.first ?? ""
        case "family": own = words.dropFirst().joined(separator: " ")
        case "email": own = email
        case "tel", "telNational": own = phone
        default: return nil
        }
        return own.isEmpty ? nil : own
    }
    /// "Azure · San Francisco 94158": the building or the company, then
    /// the place, the postal code first where the country writes it so, a
    /// ZIP without its four.
    var listPlace: String {
        let zip = postal.wholeMatch(of: #/\d{5}-\d{4}/#) != nil ? String(postal.prefix(5)) : postal
        let town = Self.postalFirst.contains(country.lowercased()) ? [zip, city] : [city, zip]
        let place = town.filter { !$0.isEmpty }.joined(separator: " ")
        return [organization.isEmpty ? listParts.building : organization, place]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
    /// "Anna K.", the name as a list says it when its addresses are more
    /// than one person's.
    var shortName: String {
        let words = name.split(separator: " ")
        guard words.count > 1, let initial = words.last?.first else { return name }
        return "\(words[0]) \(initial)."
    }

    private static let postalFirst: Set<String> = [
        "de", "germany", "fr", "france", "nl", "netherlands", "es", "spain", "it", "italy", "at", "austria",
        "ch", "switzerland", "se", "sweden", "dk", "denmark", "no", "norway", "fi", "finland", "pl", "poland",
        "be", "belgium", "pt", "portugal",
    ]
    private static let american: Set<String> = ["", "us", "usa", "united states", "united states of america"]
    private static let unitWord = #/(?i)^(apt\.?|apartment|unit|suite|ste\.?|#|fl\.?|floor|room|rm\.?|bldg\.?|building)(\s|$|(?=\d))/#
    private static let short: [String: String] = [
        "street": "St", "avenue": "Ave", "boulevard": "Blvd", "road": "Rd", "drive": "Dr", "lane": "Ln",
        "place": "Pl", "court": "Ct", "highway": "Hwy", "parkway": "Pkwy", "terrace": "Ter", "square": "Sq",
        "north": "N", "south": "S", "east": "E", "west": "W",
        "northeast": "NE", "northwest": "NW", "southeast": "SE", "southwest": "SW",
    ]

    private var listParts: (building: String, street: String, unit: String) {
        let lines = street.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var parts = (lines.first ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // "Azure, 690 Long Bridge Street": a name before the number.
        var building = ""
        if parts.count > 1, !parts[0].contains(where: \.isNumber), parts[1].first?.isNumber == true {
            building = parts.removeFirst()
        }
        var units: [String] = Array(lines.dropFirst())
        var road: [String] = []
        for part in parts {
            if part.contains(Self.unitWord) { units.append(part) } else { road.append(part) }
        }
        // Long words short only in an American street, where the post
        // office spells them so: Place Vendôme stays as it is.
        var said = road.joined(separator: ", ")
        if Self.american.contains(country.lowercased()) {
            let words = said.split(separator: " ", omittingEmptySubsequences: true)
            said = words.enumerated().map { (index: Int, word: Substring) -> String in
                let bare = word.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters)
                guard index > 0, let short = Self.short[bare] else { return String(word) }
                return short + (word.last == "," ? "," : "")
            }.joined(separator: " ")
        }
        // Only the last of them is kept whole, the apartment or the suite:
        // a building before it may be cut with the street.
        var unit = units.map(Self.unitSaid)
        let last = unit.popLast() ?? ""
        said = ([said] + unit).filter { !$0.isEmpty }.joined(separator: ", ")
        return said.isEmpty ? ("", building, last) : (building, said, last)
    }

    /// "Apt. 1210" as "Apt 1210", "suite 400" as "Suite 400", "#4" as it is.
    private static func unitSaid(_ unit: String) -> String {
        let plain = unit.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let match = plain.firstMatch(of: unitWord) else { return plain }
        let word = String(match.output.1)
        let rest = plain[match.range.upperBound...].trimmingCharacters(in: CharacterSet.whitespaces)
        let said: String
        switch word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
        case "#": return "#" + rest
        case "apt", "apartment": said = "Apt"
        case "ste": said = "Ste"
        case "fl", "floor": said = "Fl"
        case "rm", "room": said = "Rm"
        case "bldg", "building": said = "Bldg"
        default: said = word.capitalized
        }
        return rest.isEmpty ? said : "\(said) \(rest)"
    }

    /// A city and a state the page wrote into the street ("500 Brannan St,
    /// San Francisco, CA"), moved down to their own boxes, so a list and a
    /// form get each in its place. Nothing moves unless it is plainly that.
    func tidied() -> StreetAddress {
        var lines = street.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { return self }
        var parts = first.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3, let state = parts.last, state.wholeMatch(of: #/[A-Z]{2}/#) != nil,
              !parts[parts.count - 2].contains(where: \.isNumber),
              city.isEmpty || Self.key(city) == Self.key(parts[parts.count - 2]),
              region.isEmpty || Self.key(region) == Self.key(state)
        else { return self }
        var tidy = self
        tidy.region = state
        parts.removeLast()
        tidy.city = parts.removeLast()
        lines[0] = parts.joined(separator: ", ")
        tidy.street = lines.joined(separator: "\n")
        return tidy
    }

    /// Two addresses are the same place when the street and the postal code
    /// say so, however each was spelled; with no postal code, the city.
    func same(as other: StreetAddress) -> Bool {
        Self.key(line1) == Self.key(other.line1) && Self.key(postal) == Self.key(other.postal)
            && (!postal.isEmpty || Self.key(city) == Self.key(other.city))
            && Self.key(name) == Self.key(other.name)
    }

    private static func key(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

enum Wallet {
    /// A test run keeps its own, as Vault does.
    private static let label = Store.name
    private static let service = Bundle.main.bundleIdentifier.map { "\(label) · autofill · \($0)" } ?? "\(label) · autofill"

    private enum Kind: String { case card, address }

    /// Cards and addresses kept under the name the app had inside before it
    /// was Yab (Store.oldName), moved under its own. Only from Vault.adopt,
    /// off the main thread.
    static func adopt() -> Bool {
        let old = Store.oldName
        let oldService = Bundle.main.bundleIdentifier.map { "\(old) · autofill · \($0)" } ?? "\(old) · autofill"
        guard oldService != service else { return true }
        return Vault.carry(
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: oldService, kSecAttrLabel as String: old],
            into: [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrLabel as String: label],
            keeping: [kSecAttrAccount, kSecAttrDescription, kSecAttrGeneric]
        )
    }

    private static func mine(_ kind: Kind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrLabel as String: label,
            kSecAttrDescription as String: kind.rawValue,
        ]
    }

    // MARK: - cards

    /// Every card, newest used first, without its number.
    static func cards() -> [SavedCard] {
        rows(.card).compactMap { row -> SavedCard? in
            guard let id = row[kSecAttrAccount as String] as? String,
                  let facts = (row[kSecAttrGeneric as String] as? Data).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            else { return nil }
            return card(id: id, facts: facts, saved: row[kSecAttrCreationDate as String] as? Date)
        }
        .sorted { ($0.used ?? $0.saved ?? .distantPast) > ($1.used ?? $1.saved ?? .distantPast) }
    }

    /// References only, from attributes. Never asks for card secret data.
    static func billingAddressIDs() -> Set<String> {
        Set(rows(.card).compactMap { row in
            (row[kSecAttrGeneric as String] as? Data)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["billing"] as? String
        }.filter { !$0.isEmpty })
    }
    static var hasAddresses: Bool { !rows(.address).isEmpty }

    /// A card as its item's attributes say it, no number: one kept here,
    /// or one another device kept in sync's card shape (AssistantWallet).
    static func card(id: String, facts: [String: Any], saved: Date? = nil) -> SavedCard {
        SavedCard(
            id: id, number: "",
            last4: facts["last4"] as? String ?? "",
            brand: facts["brand"] as? String ?? "Card",
            name: facts["name"] as? String ?? "",
            month: facts["month"] as? Int ?? 0,
            year: facts["year"] as? Int ?? 0,
            used: (facts["used"] as? Double).map(Date.init(timeIntervalSince1970:)),
            saved: saved,
            nickname: facts["nickname"] as? String ?? "",
            source: facts["source"] as? String ?? "",
            usedOn: facts["usedOn"] as? String ?? "",
            issuer: facts["issuer"] as? String ?? "",
            level: facts["level"] as? String ?? "",
            billing: facts["billing"] as? String ?? "",
            keepsCode: facts["code"] as? Bool ?? false
        )
    }

    /// A card's secret as it is kept: its number and its code.
    static func secret(of data: Data) -> (number: String?, code: String?) {
        let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (record?["number"] as? String, (record?["csc"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// One card's number. Read off the main thread: the keychain answers
    /// one caller at a time.
    static func number(of id: String) -> String? {
        guard let data = secret(.card, id) else { return nil }
        return secret(of: data).number
    }

    /// One card's security code, if one was kept with it. Off the main
    /// thread, as `number(of:)`.
    static func securityCode(of id: String) -> String? {
        guard let data = secret(.card, id) else { return nil }
        return secret(of: data).code
    }

    /// The card kept with this number, if one is.
    static func card(numbered digits: String) -> SavedCard? {
        let last4 = String(digits.suffix(4))
        return cards().first { $0.last4 == last4 && number(of: $0.id) == digits }
    }

    @discardableResult
    static func save(_ card: SavedCard) -> Bool {
        let digits = card.number.filter(\.isNumber)
        guard luhn(digits) else { return false }
        let bank = Bins.lookup(digits)
        var facts: [String: Any] = [
            "last4": String(digits.suffix(4)), "brand": brand(of: digits), "name": card.name,
            "month": card.month, "year": card.year,
            "nickname": card.nickname, "source": card.source, "usedOn": card.usedOn,
            "issuer": bank?.issuer ?? "", "level": bank?.level ?? "", "billing": card.billing,
        ]
        if let used = card.used { facts["used"] = used.timeIntervalSince1970 }
        let code = card.csc.filter(\.isNumber)
        facts["code"] = (3...4).contains(code.count)
        var record = ["number": digits]
        if (3...4).contains(code.count) { record["csc"] = code }
        // Sorted, so the same card is the same bytes on every Mac (sync compares its secret as they are).
        guard let secret = try? JSONSerialization.data(withJSONObject: record, options: .sortedKeys),
              let generic = try? JSONSerialization.data(withJSONObject: facts, options: .sortedKeys)
        else { return false }
        return write(.card, card.id, secret: secret, generic: generic)
    }

    /// Just used, on that site: lists put it first from now on. The number
    /// stays as it is.
    static func touch(card id: String, on site: String = "") {
        guard var card = cards().first(where: { $0.id == id }), let digits = number(of: id) else { return }
        card.number = digits
        card.csc = securityCode(of: id) ?? ""
        card.used = Date()
        if !site.isEmpty { card.usedOn = site }
        save(card)
    }

    static func forget(card id: String) { remove(.card, id) }

    /// A card kept again with its number and code as they are and one thing
    /// changed: its code, or the address it is billed to.
    @discardableResult
    static func update(card id: String, _ change: (inout SavedCard) -> Void) -> Bool {
        guard var card = cards().first(where: { $0.id == id }), let digits = number(of: id) else { return false }
        card.number = digits
        card.csc = securityCode(of: id) ?? ""
        change(&card)
        return save(card)
    }

    /// The address a card is billed to: the one linked to it, or else the
    /// one a form gets unasked (preferredAddress), as a form's ZIP beside
    /// the card was taken before.
    static func billing(of card: SavedCard, among addresses: [StreetAddress]) -> StreetAddress? {
        addresses.first { $0.id == card.billing }
            ?? addresses.first { $0.used != nil } ?? addresses.first { ($0.source ?? "").hasSuffix("home") } ?? addresses.first
    }

    // MARK: - addresses

    static func addresses() -> [StreetAddress] {
        rows(.address).compactMap { row -> StreetAddress? in
            guard let id = row[kSecAttrAccount as String] as? String,
                  let data = secret(.address, id),
                  var address = Wallet.address(of: data)
            else { return nil }
            address.id = id
            address.saved = row[kSecAttrCreationDate as String] as? Date
            // What was kept before tidied() as it is kept now.
            return address.tidied()
        }
        .sorted { ($0.used ?? $0.saved ?? .distantPast) > ($1.used ?? $1.saved ?? .distantPast) }
    }

    /// An address's secret as it is kept, here or by another device in
    /// sync's address shape (AssistantWallet).
    static func address(of data: Data) -> StreetAddress? {
        try? JSONDecoder().decode(StreetAddress.self, from: data)
    }

    /// An address as its secret is kept, here and in its record. Its keys
    /// sorted: an encoder lists them in another order on each run, and two
    /// Macs that kept the same address in two orders took each other's for
    /// a change, forever.
    static func addressData(_ address: StreetAddress) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(address)
    }

    /// The address a form or a checkout gets without being asked which:
    /// the one the person used last, and failing that the home one getting
    /// to know them found, never simply the one saved last (work, kept a
    /// second after home, or one a page talked an agent into).
    static func preferredAddress() -> StreetAddress? {
        let all = addresses()
        return all.first { $0.used != nil } ?? all.first { ($0.source ?? "").hasSuffix("home") } ?? all.first
    }

    @discardableResult
    static func save(_ address: StreetAddress, origin: ContextOrigin = .unknown) -> Bool {
        ContextPrivacy.shared.saveAddress(address, origin: origin, write: writeAddress)
    }

    static let contextKeys = ["name", "organization", "street", "city", "region", "postal", "country", "phone", "email", "source", "found"]
    static func contextCells(_ address: StreetAddress) -> [String: ContextPrivacy.Cell] {
        Dictionary(uniqueKeysWithValues: contextKeys.map { ($0, ContextPrivacy.Cell(value: address.contextValue($0))) })
    }

    private static func writeAddress(_ address: StreetAddress) -> Bool {
        var kept = address.tidied()
        kept.saved = nil
        guard let data = addressData(kept) else { return false }
        return write(.address, address.id, secret: data, generic: nil)
    }

    static func touch(address id: String, on site: String = "") {
        ContextPrivacy.shared.transaction {
            guard var address = addresses().first(where: { $0.id == id }) else { return }
            address.used = Date()
            if !site.isEmpty { address.usedOn = site }
            save(address, origin: .usage)
        }
    }

    /// Cards and addresses from another browser, or from Contacts: only
    /// what isn't kept already, a card by its number, an address by where
    /// it is, and the security code a kept card came without. Keychain work, so never on the main thread. How many came.
    static func take(cards incoming: [SavedCard], addresses places: [StreetAddress]) -> (cards: Int, addresses: Int) {
        var kept = (cards: 0, addresses: 0)
        var known: [String: String] = [:]
        for card in cards() { if let digits = number(of: card.id) { known[digits] = card.id } }
        var seen = Set(known.keys)
        for card in incoming where luhn(card.number) {
            // One here already: only its security code, if it came without.
            if let id = known[card.number] {
                if !card.csc.isEmpty, securityCode(of: id) == nil, update(card: id, { $0.csc = card.csc }) {
                    kept.cards += 1
                }
                continue
            }
            guard !seen.contains(card.number) else { continue }
            seen.insert(card.number)
            if save(card) { kept.cards += 1 }
        }
        var have = addresses()
        for place in places.map({ $0.tidied() }) where place.whole && !have.contains(where: { $0.same(as: place) }) {
            have.append(place)
            if save(place, origin: .manual(Set(contextKeys))) { kept.addresses += 1 }
        }
        return kept
    }

    static func forget(address id: String) { remove(.address, id) }

    // MARK: - the keychain

    private static func rows(_ kind: Kind) -> [[String: Any]] {
        list(kind) ?? []
    }

    /// The same, nil when the keychain couldn't be asked.
    private static func list(_ kind: Kind) -> [[String: Any]]? {
        if AgentFixture.requested { return [] }
        var query = mine(kind)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        let status = Vault.quietly { Keychain.copyMatching(query as CFDictionary, &out) }
        guard status == errSecSuccess, let rows = out as? [[String: Any]] else {
            if status != errSecItemNotFound {
                NSLog("Wallet: keychain list failed (%d)", status)
                return nil
            }
            return []
        }
        return rows
    }

    // MARK: - for sync

    /// Each card's or address's id and when it last changed, no secret
    /// read; nil when the keychain couldn't be asked (SyncWallet).
    static func listed(cards: Bool) -> [(id: String, modified: Date?)]? {
        list(cards ? .card : .address)?.compactMap { row in
            (row[kSecAttrAccount as String] as? String).map { ($0, row[kSecAttrModificationDate as String] as? Date) }
        }
    }

    /// One item as it is kept: its secret, and for a card what is said of
    /// it beside it.
    static func kept(card: Bool, _ id: String) -> (secret: Data, facts: Data?)? {
        let kind: Kind = card ? .card : .address
        guard let secret = secret(kind, id) else { return nil }
        guard card else { return (secret, nil) }
        var query = mine(kind)
        query[kSecAttrAccount as String] = id
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        _ = Vault.quietly { Keychain.copyMatching(query as CFDictionary, &out) }
        return (secret, (out as? [String: Any])?[kSecAttrGeneric as String] as? Data)
    }

    /// Kept exactly as another device has it, in its record stamped
    /// `record` (the wall of its latest change).
    @discardableResult
    static func put(card: Bool, _ id: String, secret: Data, facts: Data?, from record: Int64? = nil) -> Bool {
        write(card ? .card : .address, id, secret: secret, generic: facts, from: record)
    }

    static func remove(card: Bool, _ id: String, from record: Int64? = nil) { remove(card ? .card : .address, id, from: record) }

    private static func secret(_ kind: Kind, _ id: String) -> Data? {
        if AgentFixture.requested { return nil }
        var query = mine(kind)
        query[kSecAttrAccount as String] = id
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = Vault.quietly { Keychain.copyMatching(query as CFDictionary, &out) }
        guard status == errSecSuccess else {
            if status != errSecItemNotFound { NSLog("Wallet: keychain read failed (%d)", status) }
            return nil
        }
        return out as? Data
    }

    /// Bumped at every change to the cards and addresses kept here: a reader
    /// that saw this count before knows nothing changed since, without
    /// asking the keychain (KnowRelay).
    static var changes: Int { changed.withLock { $0 } }
    private static let changed = OSAllocatedUnfairLock(initialState: 0)

    /// Counted once the write is in, as Vault.writing marks it: a reader
    /// that saw the new count read what the keychain holds since.
    private static func write(_ kind: Kind, _ id: String, secret: Data, generic: Data?, from record: Int64? = nil) -> Bool {
        if AgentFixture.requested { return false }
        defer { changed.withLock { $0 += 1 } }
        return Vault.writing("\(kind.rawValue)/\(id)", from: record) { () -> Bool in
            var item = mine(kind)
            item[kSecAttrAccount as String] = id
            var fields: [String: Any] = [kSecValueData as String: secret]
            if let generic { fields[kSecAttrGeneric as String] = generic }
            let status = Vault.quietly { Keychain.update(item as CFDictionary, fields as CFDictionary) }
            if status == errSecSuccess { return true }
            guard status == errSecItemNotFound else { return false }
            item.merge(fields) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            return Vault.quietly { Keychain.add(item as CFDictionary, nil) } == errSecSuccess
        }
    }

    private static func remove(_ kind: Kind, _ id: String, from record: Int64? = nil) {
        if AgentFixture.requested { return }
        defer { changed.withLock { $0 += 1 } }
        Vault.removing("\(kind.rawValue)/\(id)", from: record) {
            var item = mine(kind)
            item[kSecAttrAccount as String] = id
            _ = Vault.quietly { Keychain.delete(item as CFDictionary) }
        }
    }

    // MARK: - proving

    /// A card goes into a page, or shows in Autofill's place, only after the
    /// Mac's owner says so: Touch ID, the watch, or the Mac's password, every
    /// time, whatever Settings says about passwords. A Mac that can't ask
    /// at all (no password set) has nothing to prove with, as for passwords.
    static func prove(_ reason: String, _ done: @escaping (Vault.Proven) -> Void) {
        if Store.testing, let answer = benchAnswer {
            DispatchQueue.main.asyncAfter(deadline: .now() + benchDelay) { done(answer) }
            return
        }
        let context = LAContext()
        var trouble: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &trouble) else {
            done(trouble?.code == LAError.passcodeNotSet.rawValue ? .yes : .cannot)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { done(ok ? .yes : .no) }
        }
    }

    /// A test run answers the question itself (Bench `autofill`), so no
    /// Touch ID comes up in front of whoever is at the Mac.
    static var benchAnswer: Vault.Proven?
    /// How long that answer takes, to see what shows while it is asked.
    static var benchDelay: TimeInterval = 0

    // MARK: - never back to an agent

    /// Card numbers yab has put into a page since launch, in memory only:
    /// whatever an agent reads back, a snapshot, a script's value, a page's
    /// text, has them as the last four digits and nothing more (`hide`).
    @MainActor static var filled = Set<String>()

    /// `value` with every number yab filled, however it is spaced, as
    /// "•••• 4242". Walks dictionaries and arrays; leaves the rest.
    @MainActor static func hide(_ value: Any) -> Any {
        guard !filled.isEmpty else { return value }
        switch value {
        case let text as String:
            var out = text
            for number in filled where number.count >= 12 {
                let pattern = number.map { String($0) }.joined(separator: "[\\s\\-]?")
                out = out.replacingOccurrences(of: pattern, with: "•••• " + number.suffix(4), options: .regularExpression)
            }
            return out
        case let map as [String: Any]:
            return map.mapValues { hide($0) }
        case let list as [Any]:
            return list.map { hide($0) }
        default:
            return value
        }
    }

    // MARK: - what a card number says about itself

    /// The check digit every card number carries.
    static func luhn(_ digits: String) -> Bool {
        guard (12...19).contains(digits.count), digits.allSatisfy(\.isNumber) else { return false }
        var sum = 0
        for (index, char) in digits.reversed().enumerated() {
            var digit = Int(String(char)) ?? 0
            if index % 2 == 1 {
                digit *= 2
                if digit > 9 { digit -= 9 }
            }
            sum += digit
        }
        return sum % 10 == 0
    }

    /// The network, from the number's first digits.
    static func brand(of digits: String) -> String {
        func starts(_ low: Int, _ high: Int, _ length: Int) -> Bool {
            guard digits.count >= length, let head = Int(digits.prefix(length)) else { return false }
            return (low...high).contains(head)
        }
        if digits.hasPrefix("4") { return "Visa" }
        if starts(51, 55, 2) || starts(2221, 2720, 4) { return "Mastercard" }
        if digits.hasPrefix("34") || digits.hasPrefix("37") { return "American Express" }
        if digits.hasPrefix("6011") || digits.hasPrefix("65") || starts(644, 649, 3) { return "Discover" }
        if starts(3528, 3589, 4) { return "JCB" }
        if digits.hasPrefix("62") { return "UnionPay" }
        if digits.hasPrefix("36") || starts(300, 305, 3) || digits.hasPrefix("38") { return "Diners Club" }
        if digits.hasPrefix("50") || starts(56, 69, 2) { return "Maestro" }
        return "Card"
    }

    /// A year as a page writes it, "28" or "2028", as four digits; none
    /// stays none.
    static func fullYear(_ year: Int) -> Int {
        year > 0 && year < 100 ? 2000 + year : year
    }
}

// Content ownership excludes usage timestamps and billing/card secrets.
extension StreetAddress {
    func contextValue(_ key: String) -> String {
        switch key {
        case "name": return name; case "organization": return organization; case "street": return street
        case "city": return city; case "region": return region; case "postal": return postal; case "country": return country
        case "phone": return phone; case "email": return email; case "source": return source ?? ""; case "found": return found ?? ""
        default: return ""
        }
    }
    mutating func setContext(_ key: String, _ value: String) {
        switch key {
        case "name": name = value; case "organization": organization = value; case "street": street = value
        case "city": city = value; case "region": region = value; case "postal": postal = value; case "country": country = value
        case "phone": phone = value; case "email": email = value; case "source": source = value.isEmpty ? nil : value; case "found": found = value.isEmpty ? nil : value
        default: break
        }
    }
}
