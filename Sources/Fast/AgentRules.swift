import Foundation

// What you told agents once, so they don't ask again: exceptions to the mode,
// and money.
//
// Nothing here is filled in ahead. An exception is made on the card that
// asked, Always here beside the yes, Never here with ⌥ on Not now, for that
// press on that site; Settings › Agents lists them once there are any, each
// with its ×, and adds none. Paying is never an exception: it has its own
// line, a threshold under which an agent pays without asking, off unless set,
// and a month's total ten times that threshold, past which every payment
// asks again until the month turns. A payment whose amount the page doesn't
// say always asks. In Bypass nothing asks at all, as the mode says.

@MainActor
final class AgentRules: ObservableObject {
    static let shared = AgentRules()

    enum Verdict: String, Codable { case always, never }

    struct Rule: Codable, Identifiable, Equatable {
        /// The site, as its registrable domain: mail.google.com is google.com.
        let site: String
        /// The press, in the page's own words: Send, Post, Upload.
        let verb: String
        let verdict: Verdict
        var id: String { site + "|" + verb.lowercased() }
    }

    /// The thresholds a person can pick, in dollars; 0 is off.
    static let limits = [0, 20, 50, 100]

    @Published private(set) var rules: [Rule] = []
    @Published var payLimit: Int {
        didSet { store.set(payLimit, forKey: "agents.pay-limit") }
    }
    /// Paid without asking or with a yes, this month, in dollars.
    @Published private(set) var paidThisMonth: Double = 0

    private var store: UserDefaults { Store.settings }

    private init() {
        payLimit = Store.settings.integer(forKey: "agents.pay-limit")
        if let data = Store.settings.data(forKey: "agents.exceptions"), let kept = try? JSONDecoder().decode([Rule].self, from: data) { rules = kept }
        paidThisMonth = spent[Self.month] ?? 0
    }

    // MARK: - exceptions

    /// What the site's rule says of this press, if it has one. Paying has none.
    func verdict(site: String, label: String) -> Verdict? {
        guard !Self.paying(label) else { return nil }
        return rules.first { $0.site == site && $0.verb.lowercased() == Self.verb(label).lowercased() }?.verdict
    }

    func set(site: String, label: String, _ verdict: Verdict) {
        guard !site.isEmpty, !Self.paying(label) else { return }
        let rule = Rule(site: site, verb: Self.verb(label), verdict: verdict)
        rules.removeAll { $0.id == rule.id }
        rules.append(rule)
        keep()
    }

    func remove(_ rule: Rule) {
        rules.removeAll { $0.id == rule.id }
        keep()
    }

    private func keep() {
        if let data = try? JSONEncoder().encode(rules) { store.set(data, forKey: "agents.exceptions") }
    }

    /// A press by its first word, the way the rule is kept and shown:
    /// "Send now" and "Send" are the same Send.
    static func verb(_ label: String) -> String {
        let first = label.split(separator: " ").first.map(String.init) ?? label
        return first.prefix(1).uppercased() + first.dropFirst().lowercased()
    }

    /// Whether a press spends money: those never become exceptions. In
    /// the languages the words that ask are in (AgentPage.commits).
    nonisolated static func paying(_ label: String) -> Bool {
        // A bare Transfer or Withdraw is GitHub's Transfer repository or
        // Withdraw invitation: asked like any commit, not as a payment.
        // "Purchase orders", a table or a field's name in a business app,
        // is a record, not a press that buys (register 1762): as in
        // AgentPage.commits.
        let purchase = #"purchase(?! (?:orders?|requisitions?|requests?|histor(?:y|ies)|invoices?|records?)(?![\p{L}\p{N}]))"#
        let english = "pay|pay now|buy|buy now|place (your )?order|order now|" + purchase + "|complete (purchase|order|payment)|confirm (and pay|payment|purchase|order|transfer)|submit (payment|order)|transfer (money|funds|now)|withdraw (money|funds|now)|send money|donate"
        let others = "bezahlen|jetzt (kaufen|bezahlen)|kaufen|bestellen|zahlungspflichtig bestellen|überweisen|spenden"
            + "|payer|acheter|commander|valider (la|ma) commande|confirmer (le paiement|la commande)|faire un don"
            + "|pagar|comprar|realizar pedido|finalizar (compra|pedido)|confirmar (pago|pagamento|pedido|compra)|donar|doar"
            + "|paga|acquista|ordina|conferma (pagamento|ordine|acquisto)|dona"
        let pattern = "^(" + english + "|" + others + #")(?![\p{L}\p{N}])"#
        return label.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func site(_ url: URL?) -> String {
        guard let host = url?.host()?.lowercased() else { return "" }
        return Vault.registrable(host)
    }

    // MARK: - money

    /// An amount as a page writes it, "$42.10" or "US$42.10", read as
    /// dollars; nil for another currency or none. The page script keeps the
    /// letters before the sign, so A$, C$, R$ (reais), HK$ and the other
    /// dollars and pesos aren't taken for US dollars, and the number is read
    /// the way it is written, "$1,234.56" or "$1.234,56" (Calc.digits).
    nonisolated static func dollars(_ amount: String) -> Double? {
        let text = amount.filter { !$0.isWhitespace }
        guard let sign = text.firstIndex(of: "$"), ["", "US"].contains(text[..<sign].uppercased()),
              let digits = Calc.digits(String(text[text.index(after: sign)...])) else { return nil }
        return Double(digits)
    }

    /// Whether an agent may pay this without asking.
    func mayPay(_ amount: String) -> Bool {
        guard payLimit > 0, let value = Self.dollars(amount) else { return false }
        refreshMonth()
        return value <= Double(payLimit) && paidThisMonth + value <= Double(payLimit * 10)
    }

    func spend(_ amount: String) {
        guard let value = Self.dollars(amount) else { return }
        refreshMonth()
        var all = spent
        all[Self.month, default: 0] += value
        // This month and the last are all anyone looks at.
        all = all.filter { $0.key >= Self.month(offset: -1) }
        store.set(all, forKey: "agents.paid")
        paidThisMonth = all[Self.month] ?? 0
    }

    private var spent: [String: Double] {
        store.dictionary(forKey: "agents.paid") as? [String: Double] ?? [:]
    }

    private func refreshMonth() {
        paidThisMonth = spent[Self.month] ?? 0
    }

    private static var month: String { month(offset: 0) }

    private static func month(offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .month, value: offset, to: Date()) ?? Date()
        let parts = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
}
