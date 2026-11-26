import AppKit
import SwiftUI

// Settings › Assistants › an assistant: a page further in, as Mail's
// account is, not a sheet. Where it works and what it may use, the sites it
// may or may not open as one table, what it did lately in words, and
// Disconnect at the end. Every change is kept as it is made.

extension AssistantPlace {
    /// One assistant's page: the prefix and its id.
    static let detail = "assistant:"
}

struct AssistantDetailPage: View {
    let id: String
    @ObservedObject var browser: Browser
    @ObservedObject var model: SettingsModel
    @ObservedObject private var assistants = Assistants.shared
    @ObservedObject private var agents = Agents.shared
    @ObservedObject private var approvals = AssistantApprovals.shared
    @State private var journal: [AssistantHost.Entry] = []
    @State private var journalSaid: String?

    private var grant: AssistantGrant? { assistants.grant(id) }

    private func binding<T>(_ path: WritableKeyPath<AssistantGrant, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { assistants.grant(id)?[keyPath: path] ?? fallback },
                set: { value in assistants.update(id) { $0[keyPath: path] = value } })
    }

    private var spaceSelection: Binding<UUID?> {
        Binding(get: { assistants.grant(id)?.selectedSpace(in: browser.spaces) },
                set: { choice in assistants.update(id) { $0.selectSpace(choice) } })
    }

    var body: some View {
        if let grant {
            hero(grant)
            Section {
                AssistantSpaceRow(spaces: browser.spaces, selection: spaceSelection)
                MenuRow("Asks first", options: [(title: "Before sending, paying, deleting", value: AgentAsking.auto),
                                                (title: "Also before signing in", value: AgentAsking.ask)],
                        selection: binding(\.mode, .auto))
                SettingsRow("Paused", detail: "Prevent this assistant from opening tabs until resumed.") {
                    Toggle("Paused", isOn: binding(\.paused, false)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            } footer: {
                if grant.allSpaces == true { SettingsNote("Access all spaces using each space's sign-ins.") }
            }
            Section {
                SettingsRow("Mail", detail: "Search, read and draft mail. Sending requires approval.") {
                    Toggle("Mail", isOn: binding(\.mail, false)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(!MailCenter.shared.connected)
                }
                SettingsRow("Codes from Messages") {
                    Toggle("Codes from Messages", isOn: binding(\.messages, false)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingsRow("Saved cards and addresses", detail: "Each use requires approval.") {
                    Toggle("Saved cards and addresses", isOn: binding(\.cards, false)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            } header: {
                Text("May Use").foregroundStyle(.secondary)
            }
            sites(grant)
            lately
            Section {
                SettingsRow("Disconnect \(grant.name)", detail: "Revoke access immediately. Existing tabs stay open.") {
                    Button("Disconnect\u{2026}") { disconnect(grant) }
                        .buttonStyle(.yab(.secondary, .regular, tint: .red))
                }
            }
        }
    }

    // MARK: the top

    private func hero(_ grant: AssistantGrant) -> some View {
        Section {} header: {
            VStack(spacing: 0) {
                AssistantBotIcon(client: grant.client, side: 56)
                    .padding(.bottom, 12)
                Text(grant.name)
                    .font(.system(size: 22, weight: .bold))
                Text("\(status(grant)) · connected \(grant.made.formatted(.relative(presentation: .named).locale(AppDates.locale)))")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4) // design: PageHero's gap under the name
                    .padding(.horizontal, 24)
            }
            .foregroundStyle(.primary)
            .textCase(nil)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 16) // design: PageHero's air above the first group
            .contextMenu { Button("Rename\u{2026}") { rename(grant) } }
            .accessibilityElement(children: .combine)
        }
    }

    /// What it is doing, in words.
    func status(_ grant: AssistantGrant) -> String {
        Self.status(grant, agents: agents, approvals: approvals)
    }

    static func status(_ grant: AssistantGrant, agents: Agents, approvals: AssistantApprovals) -> String {
        if grant.paused { return "Paused" }
        if approvals.records.values.contains(where: { $0.assistant == grant.id && $0.state == .open }) { return "Needs you" }
        if let task = agents.sessions.first(where: { $0.assistantID == grant.id && $0.task && $0.state.live }) {
            return task.now.isEmpty ? task.title ?? "Working" : task.now
        }
        return "Ready"
    }

    // MARK: sites

    /// One table for the sites it may or may not open: each with what it
    /// is, Never, Allowed or Only, changed in place; Remove on a right
    /// click. Banks and government sites are one row, as the consent offered.
    @ViewBuilder private func sites(_ grant: AssistantGrant) -> some View {
        let guarded = Set(Assistants.guarded).isSubset(of: Set(grant.never))
        let own = rows(grant)
        Section {
            SettingsRow("Banks, payment apps and government sites", detail: "Never opened.") {
                Toggle("Banks, payment apps and government sites", isOn: Binding(get: { guarded }, set: { on in
                    assistants.update(id) { grant in
                        grant.never.removeAll { Assistants.guarded.contains($0) }
                        if on { grant.never = Assistants.guarded + grant.never }
                    }
                }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            ForEach(own, id: \.site) { row in
                HStack(spacing: 9) { // design: the same gap as Search's site rows, which this table matches
                    HostMark(host: row.site)
                    Text(row.site).lineLimit(1)
                    Spacer(minLength: 4)
                    MenuCell(title: row.kind.word, options: SiteKind.allCases.map { (title: $0.word, value: $0) },
                             selection: Binding(get: { row.kind }, set: { set(row.site, $0) }))
                }
                .contextMenu { Button("Remove") { set(row.site, nil) } }
            }
            if own.isEmpty {
                Text(grant.only.isEmpty ? "Opens any other site." : "Opens only the sites above.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 8) {
                Text("Sites").foregroundStyle(.secondary)
                Spacer()
                Button("Add Site\u{2026}") { addSite() }
                    .settingsButton()
            }
            .textCase(nil)
        }
    }

    enum SiteKind: CaseIterable, Hashable {
        case never, allowed, only
        var word: String { switch self {
            case .never: return "Never"
            case .allowed: return "Allowed"
            case .only: return "Only"
        } }
    }

    private func rows(_ grant: AssistantGrant) -> [(site: String, kind: SiteKind)] {
        grant.never.filter { !Assistants.guarded.contains($0) }.map { ($0, .never) }
            + (grant.allowedSites ?? []).map { ($0, .allowed) }
            + grant.only.map { ($0, .only) }
    }

    /// A site moved to another kind, or out of the table with nil.
    private func set(_ site: String, _ kind: SiteKind?) {
        assistants.update(id) { grant in
            grant.never.removeAll { $0 == site }
            grant.allowedSites?.removeAll { $0 == site }
            grant.only.removeAll { $0 == site }
            switch kind {
            case .never: grant.never.append(site)
            case .allowed: grant.allowedSites = (grant.allowedSites ?? []) + [site]
            case .only: grant.only.append(site)
            case nil: break
            }
        }
    }

    private func addSite() {
        let field = Question.Field("", prompt: "bank.com")
        Task {
            guard await Questions.shared.ask(Question(
                title: "Keep a Site Away",
                detail: "\(grant?.name ?? "It") never opens it. Change it to Allowed or Only in the table.",
                glyph: "globe", yes: "Add", place: .settings, field: field)) else { return }
            var site = field.trimmed.lowercased()
            if let host = URL(string: site.contains("://") ? site : "https://" + site)?.host() { site = host }
            if site.hasPrefix("www.") { site = String(site.dropFirst(4)) }
            guard !site.isEmpty, !(grant.map(rows) ?? []).contains(where: { $0.site == site }) else { return }
            set(site, .never)
        }
    }

    // MARK: lately

    @ViewBuilder private var lately: some View {
        Section {
            if journal.isEmpty {
                Text(journalSaid ?? "Nothing yet.").foregroundStyle(.secondary)
            }
            ForEach(journal.prefix(12)) { entry in
                HStack(spacing: 12) {
                    Text(Self.words(entry))
                        .foregroundStyle(entry.outcome == "ok" ? .primary : .secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(entry.at.englishFormatted(date: .omitted, time: .shortened))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Lately").foregroundStyle(.secondary)
        }
        .task(id: id) {
            do { journal = try await AssistantHost.shared.journal(id) } catch { journalSaid = "Couldn\u{2019}t read what it did: \(error.localizedDescription)" }
        }
    }

    /// A journal line in words: what it did, and how that went unless it did it.
    static func words(_ entry: AssistantHost.Entry) -> String {
        let did = entry.tool.replacingOccurrences(of: "_", with: " ").capitalized(with: nil)
        let how: String? = switch entry.outcome {
        case "ok": nil
        case "needs_user": "waited for you"
        case "mac_offline": "Mac was away"
        case "denied": "you said no"
        case "refused_site", "refused_tool": "not allowed"
        case "paused": "paused"
        case "timeout": "took too long"
        case "too_many": "too many at once"
        default: entry.outcome.replacingOccurrences(of: "_", with: " ")
        }
        return how.map { "\(did) · \($0)" } ?? did
    }

    // MARK: name and leaving

    private func rename(_ grant: AssistantGrant) {
        let field = Question.Field(grant.name, prompt: grant.name)
        Task {
            guard await Questions.shared.ask(Question(
                title: "Rename \(grant.name)", detail: "Name shown in settings and on assistant tabs.",
                glyph: "pencil", yes: "Rename", place: .settings, field: field)), !field.trimmed.isEmpty else { return }
            assistants.update(id) { $0.name = field.trimmed }
        }
    }

    private func disconnect(_ grant: AssistantGrant) {
        Task {
            guard await Questions.shared.ask(Question(
                title: "Disconnect \(grant.name)?",
                detail: "Revoke access immediately. Reconnect to restore access.",
                glyph: "xmark", yes: "Disconnect", danger: true, place: .settings)) else { return }
            assistants.remove(id)
            model.leave(AssistantPlace.detail + id, to: .assistants)
        }
    }
}
