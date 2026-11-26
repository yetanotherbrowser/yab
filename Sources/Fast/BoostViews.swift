import AppKit
import SwiftUI

/// A boost being tried in this tab: the Keep card's look (KeepCard), in the
/// page's corner so the change stays in view. Nothing is kept until Keep ⌘↩;
/// ⌥ turns it into Keep for Every Site where the boost allows it. Quiet while
/// the page checks pass: only a failure or a problem says anything. An
/// agent's boost comes here only once it passed (Boosts.fit).
struct BoostTrialView: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var boosts = Boosts.shared
    @ObservedObject private var option = OptionKey.shared
    @State private var keeping = false
    @State private var reviewing = false

    static let width: CGFloat = 400

    var body: some View {
        if let trial = boosts.trials[tab.id] {
            VStack(alignment: .leading, spacing: 0) {
                well(trial.package).padding(.bottom, 12)
                Text(trial.package.name)
                    .font(CardFrame.title)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                // A quiet trial's result says where it was checked; a
                // tried one, that it stays in this tab.
                Text(trial.fitted ? ([trial.package.permission] + [trial.checked].compactMap { $0 }).joined(separator: " ")
                     : trial.package.permission + " Only this tab until you keep it.")
                    .font(CardFrame.detail)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                if let trouble = trouble(trial) {
                    Text(trouble)
                        .font(CardFrame.detail)
                        .foregroundStyle(ButtonCSS.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                foot(trial).padding(.top, CardFrame.buttonGap)
            }
            .frame(width: Self.width - CardFrame.inset * 2, alignment: .leading)
            .cardFrame()
            .padding(16)
            .sheet(isPresented: $reviewing) { BoostCodeView(package: trial.package) }
        }
    }

    private func trouble(_ trial: Boosts.Trial) -> String? {
        if let problem = trial.problem { return problem }
        guard let checks = trial.report["checks"] as? [[String: Any]] else { return nil }
        let failed = checks.filter { $0["state"] as? String == "fail" }.count
        return failed == 0 ? nil : failed == 1 ? "1 page check still fails." : "\(failed) page checks still fail."
    }

    private func well(_ package: BoostPackage) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        let host = package.sites.first ?? tab.address?.host() ?? ""
        return shape.fill(Palette.ink.opacity(0.05))
            .overlay(shape.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5))
            .overlay { Symbol(package.rung == .look ? "colorpalette" : "puzzlepiece.extension", size: 16).foregroundStyle(Palette.ink) }
            .frame(width: CardFrame.well, height: CardFrame.well)
            .notched(true, side: 15, radius: 4, offset: 5)
            .overlay(alignment: .bottomTrailing) {
                Mark(icon: Favicons.shared.cached(host) ?? tab.icon, letter: Browser.site(host).first.map { String($0).uppercased() } ?? "•", size: 15)
                    .offset(x: 5, y: 5)
            }
    }

    private func foot(_ trial: Boosts.Trial) -> some View {
        let everywhere = option.down && trial.package.canApplyEverywhere && !trial.package.allSites
        return HStack(spacing: 6) {
            Button("Review Code") { reviewing = true }
                .buttonStyle(.yab(.quiet, CardFrame.button))
                .fixedSize()
            Spacer(minLength: 8)
            press("Undo", .secondary, key: "esc") { Task { await boosts.undo(on: tab) } }
                .disabled(keeping)
            Button { keep(trial, everywhere: everywhere) } label: {
                label(keeping ? "Keeping…" : everywhere ? "Keep for Every Site" : "Keep")
            }
            .buttonStyle(.yab(.primary, CardFrame.button))
            .fixedSize()
            .disabled(!trial.ready || trial.problem != nil || keeping)
        }
    }

    private func label(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            KeyGlyphs(keys: "⌘↩", size: CardFrame.words, tint: nil, rest: 0.6)
                .transaction { $0.animation = nil }
        }
    }

    private func press(_ title: String, _ kind: ButtonKind, key: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 6) {
                Text(title)
                KeyGlyphs(keys: key, size: CardFrame.words, tint: nil, rest: 0.6)
                    .transaction { $0.animation = nil }
            }
        }
        .buttonStyle(.yab(kind, CardFrame.button))
        .fixedSize()
    }

    private func keep(_ trial: Boosts.Trial, everywhere: Bool) {
        keeping = true
        Task { await boosts.keep(trial.id, on: tab, everywhere: everywhere); keeping = false }
    }
}

/// Site Controls' Boosts: the ones kept for this site, each a row as the
/// site's own settings are (on or off in a word, its menu at the end), then
/// what the Store has for the site, with Try. Add in the heading opens
/// creation, the Store and file import; a `.user.js` can also be dropped here.
struct BoostSiteBlock: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject private var boosts = Boosts.shared
    @ObservedObject private var catalog = StoreCatalog.shared
    @ObservedObject private var installs = SyncInstalls.shared
    @State private var deleting: BoostRecord?
    @State private var history: BoostRecord?

    private typealias Setting = SiteControlsView.Setting

    var body: some View {
        if let url = tab.address, ["http", "https"].contains(url.scheme ?? ""), !tab.shy {
            let mine = boosts.on(url, in: AddonProfiles.of(tab))
            // Another Mac's, on their way here (sync), in words.
            let arriving = installs.plugins(on: url.host).filter { item in !boosts.records.contains { $0.id == item.item } }
            let popular = popular(url, mine: mine)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Boosts").sidebarFont(size: 12, weight: .semibold).foregroundStyle(Palette.ink)
                    Spacer(minLength: 0)
                    BoostAddButton(browser: browser, tab: tab)
                }
                .padding(.horizontal, 6)
                .padding(.top, 12)
                .padding(.bottom, 4)
                VStack(spacing: 1) {
                    ForEach(mine) { record in SiteControlsView.SettingRow(row: setting(record)) }
                    // Userscripts kept for this site, beside the boosts (docs/userscripts.md).
                    UserscriptSiteRows(browser: browser, tab: tab)
                    ForEach(arriving) { item in
                        SiteControlsView.SettingRow(row: Setting(symbol: item.rung == BoostPackage.Rung.look.rawValue ? "colorpalette" : "puzzlepiece.extension",
                                                                 title: item.name, said: item.state.words))
                    }
                    ForEach(popular) { item in SiteControlsView.SettingRow(row: offer(item)) }
                }
            }
            .userscriptDrop { file in
                ExtensionPanel.shared.close()
                Userscripts.shared.add(file, browser: browser, tab: tab)
            }
            .alert("Delete boost?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Cancel", role: .cancel) { deleting = nil }
                Button("Delete", role: .destructive) { if let record = deleting { Task { await boosts.delete(record.id, in: AddonProfiles.of(tab)) } }; deleting = nil }
            } message: { Text(deleting?.name ?? "") }
            .sheet(item: $history) { record in BoostHistoryView(record: record) }
        }
    }

    /// What the Store has for this site and isn't kept here yet: two, by Kept.
    private func popular(_ url: URL, mine: [BoostRecord]) -> [StoreCatalog.Item] {
        let kept = Set(mine.map(\.id))
        return catalog.on(url.host()).filter { item in
            let shared = item.revision.map { "shared-" + $0.prefix(16) }
            return !kept.contains(item.id) && shared.map(kept.contains) != true && catalog.keptPackage(item.id) == nil
        }.prefix(2).map { $0 }
    }

    private func setting(_ record: BoostRecord) -> Setting {
        let broken = boosts.packages[record.id] == nil
        // A Store update that asks for more: off until its Keep.
        if !broken, catalog.pending(record.id) != nil {
            return Setting(symbol: record.rung == .look ? "colorpalette" : "puzzlepiece.extension", title: record.name,
                           said: "New version asks for more", on: record.enabled, live: true,
                           act: { Task { await boosts.setEnabled(record.id, !record.enabled, in: AddonProfiles.of(tab)) } },
                           end: AnyView(HStack(spacing: 6) {
                               Button("Review") { ExtensionPanel.shared.close(); catalog.review(record.id, in: browser) }
                                   .buttonStyle(.yab(.secondary, .small))
                                   .fixedSize()
                                   .focusable(false)
                               menu(record)
                           }))
        }
        let said = broken ? "Could not load. Restore a version in Show Changes." : record.failures >= 2 ? "Stopped working" : record.enabled ? "On" : "Off"
        return Setting(symbol: record.rung == .look ? "colorpalette" : "puzzlepiece.extension", title: record.name, said: said,
                       on: record.enabled && !broken, live: broken || record.failures >= 2,
                       act: { Task { await boosts.setEnabled(record.id, !record.enabled, in: AddonProfiles.of(tab)) } },
                       end: AnyView(menu(record)))
    }

    /// A Store listing: what people found, with the rung's word first for
    /// code; the whole rights, as the Keep card will say them, on Try.
    private func offer(_ item: StoreCatalog.Item) -> Setting {
        let found = catalog.kept(item).map { "Kept by " + $0 } ?? catalog.checked(item)
        let said = ([item.plugin ? item.rung : nil, found].compactMap { $0 }).joined(separator: " · ")
        return Setting(symbol: item.plugin ? "puzzlepiece.extension" : "colorpalette", title: item.name, said: said,
                       end: AnyView(Button("Try") { ExtensionPanel.shared.close(); catalog.tryOn(item, in: browser) }
                        .buttonStyle(.yab(.secondary, .small))
                        .fixedSize()
                        .focusable(false)
                        .keyTip(item.rights)))
    }

    private func menu(_ record: BoostRecord) -> some View {
        Menu {
            if let package = boosts.packages[record.id], let url = BoostApp.url(package) {
                Button("Open App") { ExtensionPanel.shared.close(); browser.open(url, foreground: true) }
            }
            Button("Change…") { ask("Change boost \(record.id): ") }
            if record.failures >= 2 { Button("Fix…") { ask("Fix boost \(record.id) from its original request. Its page checks failed. Read boost_read and try a repair.") } }
            Button("Show Changes…") { history = record }
            Divider()
            if record.rung == .look, !record.id.hasPrefix("shared-"), BoostCatalog.entries.first(where: { $0.id == record.id }) == nil {
                Button("Share to Store…") { shareToStore(record) }
            }
            if record.rung == .look { Button("Export Boost…") { export(record) } }
            Button("Share Recipe…") { share(record) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([boosts.library.folder(record.id)]) }
            Button("Open Original Chat") {
                ExtensionPanel.shared.close()
                if let chat = Chats.shared.chat(record.session) { browser.keepChat(chat.id); browser.showChat(chat.id) }
            }
            Divider()
            Button("Delete…", role: .destructive) { deleting = record }
        } label: {
            Symbol("ellipsis", size: 10, weight: .medium)
                .foregroundStyle(Palette.muted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
    }

    /// The boost goes to the Store as a pull request the person's agent
    /// opens from their GitHub account, after the card says so.
    private func shareToStore(_ record: BoostRecord) {
        Task {
            let question = Question(title: "Share \(record.name) to the Store?",
                                    detail: "\(browser.chatName) writes the listing and opens a pull request to yab-plugins from your GitHub account. Yab takes the pictures and checks it before anyone merges.",
                                    lines: [], yes: "Share", no: "Not Now", place: .plain)
            guard await Questions.shared.ask(question) else { return }
            let folder = boosts.library.folder(record.id).path
            ask("""
            Share my boost "\(record.name)" (\(record.id)) to the Yab Store. Its files are in \(folder) (manifest.json, BOOST.md, style.css).
            Follow docs/store.md "yab-plugins": with my GitHub account (gh), fork yetanotherbrowser/yab-plugins, add boosts/\(record.id)/ with manifest.json, BOOST.md (keep my words and its checks), page/style.css and listing.json {name, intent, host, by: my GitHub handle, preview}, run `npm run validate` there, and open a pull request titled "Add \(record.name) for \(record.sites.first.map(Browser.site) ?? "")". Do not change anything else. Post the pull request's link here.
            """)
        }
    }

    private func ask(_ words: String) {
        ExtensionPanel.shared.close()
        browser.startBoost(words, about: tab)
    }
    private func export(_ record: BoostRecord) {
        guard let package = boosts.packages[record.id] else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = record.id + ".boost"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try BoostShare.export(package).write(to: url, options: .atomic) }
        catch { browser.announce(error.localizedDescription, mark: "exclamationmark.triangle") }
    }
    private func share(_ record: BoostRecord) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = record.id + ".boost.md"
        guard panel.runModal() == .OK, let url = panel.url,
              let recipe = try? boosts.library.files(record.id)["BOOST.md"] else { return }
        do { try recipe.write(to: url, atomically: true, encoding: .utf8) }
        catch { browser.announce(error.localizedDescription, mark: "exclamationmark.triangle") }
    }
}

private struct BoostHistoryView: View {
    let record: BoostRecord
    @Environment(\.dismiss) private var dismiss
    @State private var restoring = false
    @State private var inspecting: BoostRevision?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(record.name).font(.headline)
            ThreadScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Boosts.shared.library.history(record.id)) { revision in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(revision.intent).font(.system(size: 12)).lineLimit(4)
                                Text(revision.date.formatted(AppDates.dateTime)).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Compare") { inspecting = revision }
                            if revision.id == record.revision { Text("Current").font(.caption) }
                            else {
                                Button("Restore") {
                                    restoring = true
                                    Task { await Boosts.shared.restore(revision, record: record); dismiss() }
                                }.disabled(restoring)
                            }
                        }
                        Divider()
                    }
                }
            }.frame(maxHeight: 300)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 540)
            .sheet(item: $inspecting) { revision in BoostDiffView(record: record, revision: revision) }
    }
}

struct BoostDiffView: View {
    let record: BoostRecord
    let revision: BoostRevision
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let current = Boosts.shared.packages[record.id]?.files ?? [:]
        let changed = Set(current.keys).union(revision.files.keys).sorted().filter { current[$0] != revision.files[$0] }
        VStack(alignment: .leading, spacing: 12) {
            Text("Changes since " + revision.date.formatted(AppDates.dateTime)).font(.headline)
            Text("Removed lines are prefixed with −, added lines with +.").font(.caption).foregroundStyle(.secondary)
            ThreadScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if changed.isEmpty { Text("This version matches the current files.") }
                    ForEach(changed, id: \.self) { path in
                        DisclosureGroup(path) {
                            Text(diff(revision.files[path] ?? "", current[path] ?? ""))
                                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(24).frame(width: 680, height: 540)
    }
    private func diff(_ old: String, _ new: String) -> String {
        let before = old.components(separatedBy: .newlines), after = new.components(separatedBy: .newlines)
        return after.difference(from: before).map { change in
            switch change {
            case .remove(let offset, let line, _): return "− \(offset + 1): " + line
            case .insert(let offset, let line, _): return "+ \(offset + 1): " + line
            }
        }.joined(separator: "\n")
    }
}

private struct BoostCodeView: View {
    let package: BoostPackage
    @State private var reviewing = false
    @State private var notes: String?
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(package.name).font(.headline)
            Text(package.permission).font(.caption)
            HStack {
                Button(reviewing ? "Reviewing…" : "Ask My Agent to Review…") {
                    reviewing = true; failure = nil
                    Task {
                        do { notes = try await BoostReview.run(package) }
                        catch { failure = error.localizedDescription }
                        reviewing = false
                    }
                }.disabled(reviewing)
                Text("You choose whether to share these files.").font(.caption).foregroundStyle(.secondary)
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            ThreadScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let notes {
                        Text("Agent review").font(.headline)
                        Text(notes).font(.system(size: 12)).textSelection(.enabled)
                        Divider()
                    }
                    ForEach(package.files.keys.sorted(), id: \.self) { path in
                        DisclosureGroup(path) { Text(package.files[path] ?? "").font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }
            }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(24).frame(width: 680, height: 540)
    }
}
