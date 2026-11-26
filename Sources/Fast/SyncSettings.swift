import AppKit
import SwiftUI
import SyncKit
import UniformTypeIdentifiers

/// Settings › Sync (docs/sync.md), a basic: how Yab keeps itself, not a
/// thing of its own. Off, it is a way in (SyncArrival). On, it opens
/// straight onto the Macs, as General opens onto its rows, each saying in
/// words how it is; what syncs and the way out are a page further in each.
/// It says how the line is only when something needs doing about it, and
/// then on this Mac's own row.
struct SyncPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var sync = SyncCenter.shared

    var body: some View {
        Group {
            switch model.opened {
            case SyncPlace.what: SyncWhatPage()
            case SyncPlace.off: SyncOffPage(model: model)
            default: home
            }
        }
        // The numbers here are counted only while they are on screen.
        .onAppear {
            sync.showCounts(true)
            sync.lookForSeparate()
        }
        .onDisappear { sync.showCounts(false) }
    }

    // MARK: On

    /// Plain rows from the top, as General is: a basic opens straight
    /// onto what it holds.
    @ViewBuilder private var home: some View {
        if let recovery = sync.recovery {
            Section { RecoveryCard(key: recovery) }
        }
        if let found = sync.separate {
            Section { SeparateRow(name: found.name, keep: true) }
        }
        Section {
            ForEach(devices, id: \.id) { device in
                deviceRow(device)
            }
            // Until a phone is among them: the way to get one in.
            if PhoneBeta.waiting { PhoneBetaRow() }
            SyncOpenRow(action: { model.open(.sync, item: SyncPlace.add) }) {
                DeviceWell(symbol: "plus")
                Text("Add a Device").frame(maxWidth: .infinity, alignment: .leading)
                SettingsChevron()
            }
            .settingsAnchor("sync-devices")
        }
        Section {
            SyncOpenRow(action: { model.open(.sync, item: SyncPlace.what) }) {
                VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's gap under a title
                    Text("What Syncs")
                    Text("Spaces, tabs, bookmarks, settings, chats, routines and what agents remember")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(SyncWhatPage.kinds.reduce(0) { $0 + (sync.counts[$1.collection] ?? 0) })")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                SettingsChevron()
            }
            SettingsRow("History of the last two weeks", detail: "Older history stays on each Mac.") {
                Text("\(sync.counts[SyncShapes.visit] ?? 0)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Toggle(SettingsWords.text("History"), isOn: $sync.history)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("sync-history")
            SettingsRow("Passwords, cards and addresses", detail: "Includes two-factor keys. Each secret is encrypted separately for your devices.") {
                Text("\((sync.counts[SyncWallet.login] ?? 0) + (sync.counts[SyncWallet.card] ?? 0))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Toggle(SettingsWords.text("Passwords"), isOn: $sync.passwords)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("sync-passwords")
            SettingsRow("Extensions and plugins", detail: "Sync Chrome Web Store extensions and saved plugins. Unpacked extensions stay on their Mac.") {
                Text("\(sync.counts[SyncAddons.ext] ?? 0)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Toggle(SettingsWords.text("Extensions and plugins"), isOn: $sync.addons)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("sync-addons")
        }
        Section {
            SyncOpenRow(action: { model.open(.sync, item: SyncPlace.off) }) {
                Text("Turn Off Sync…").frame(maxWidth: .infinity, alignment: .leading)
                SettingsChevron()
            }
        }
    }

    private var devices: [SyncClient.Listed] {
        // This Mac first, whatever the server's order.
        sync.devices.sorted { ($0.id == sync.thisDevice ? 0 : 1, $0.name) < ($1.id == sync.thisDevice ? 0 : 1, $1.name) }
    }

    private func deviceRow(_ device: SyncClient.Listed) -> some View {
        let here = device.id == sync.thisDevice
        let status = here ? hereStatus : seen(device)
        return HStack(spacing: 12) {
            DeviceWell(symbol: DeviceWell.symbol(model: device.model))
            VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's gap under a title
                HStack(spacing: 6) {
                    Text(device.name)
                    if here {
                        Text("This Mac")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Palette.wash, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                    }
                }
                if !status.words.isEmpty {
                    Text(status.words)
                        .font(.callout)
                        .foregroundStyle(status.tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !here {
                SettingsMoreMenu("More for \(device.name)", entries: { [.destructive("Remove from Sync…") { remove(device) }] }) {
                    Symbol("ellipsis", size: 13).foregroundStyle(.secondary).contentShape(Rectangle())
                }
                .fixedSize()
            }
        }
    }

    /// This Mac in words. Trouble with the line is said here, on its own
    /// row, rather than in a group of its own over the page.
    private var hereStatus: (words: String, tint: Color?) {
        switch sync.state {
        case .live: return ("Up to date", .green)
        case .connecting: return ("Connecting…", nil)
        case .waiting(let why):
            return ("Not syncing: " + why.prefix(1).lowercased() + why.dropFirst() + " Sends what changed here once it can.", .orange)
        case .refused(let why):
            return (why + " Turn sync off and on again to join with a code or the Recovery Key.", .orange)
        case .off: return ("", nil)
        }
    }

    private func seen(_ device: SyncClient.Listed) -> (words: String, tint: Color?) {
        let words = Self.seen(device.lastSeen, now: Date())
        return (words, words == Self.syncingNow ? .green : nil)
    }

    static let syncingNow = "Syncing now"

    /// Another device in words: up in the last two minutes, or when it last was.
    static func seen(_ lastSeen: Date?, now: Date) -> String {
        guard let date = lastSeen else { return "" }
        if now.timeIntervalSince(date) < 120 { return syncingNow }
        let ago = RelativeDateTimeFormatter()
        ago.locale = When.words
        return "Last synced " + ago.localizedString(for: date, relativeTo: now)
    }

    /// The four digits, spaced as the iPhone shows them.
    static func spaced(_ check: String) -> String { check.map(String.init).joined(separator: " ") }

    private func remove(_ device: SyncClient.Listed) {
        Task {
            guard await Questions.shared.ask(Question(
                title: "Remove \(device.name) from sync?",
                detail: "It stops getting changes from your other devices and keeps what it has.",
                glyph: DeviceWell.symbol(model: device.model), yes: "Remove", danger: true, place: .settings)) else { return }
            sync.remove(device: device.id)
        }
    }
}

/// The pages further in, as `SettingsModel.opened`.
enum SyncPlace {
    static let add = "add"
    static let what = "what"
    static let off = "off"
}

/// A whole row that opens something, the way FeatureRow's does.
private struct SyncOpenRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) { content() }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Another account on this Apple ID (docs/sync.md, "Two accounts"): Sync's
/// page says so at its top, Add a Device once it was kept apart.
struct SeparateRow: View {
    let name: String
    /// Still undecided: Keep Separate is there too.
    let keep: Bool
    @ObservedObject var sync = SyncCenter.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 12) {
                DeviceWell(symbol: "laptopcomputer")
                VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's gap under a title
                    Text(verbatim: "\(name) syncs separately")
                    Text(keep ? "Both are on your Apple ID, but they don’t share tabs or bookmarks." : "You chose to keep it separate.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !keep { button }
            }
            if keep { HStack(spacing: 8) { button } }
        }
    }

    @ViewBuilder private var button: some View {
        if sync.joiningAccounts {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Joining…").foregroundStyle(.secondary)
            }
        } else {
            if keep {
                Button("Keep Separate") { sync.keepSeparate() }.buttonStyle(.yab(.quiet))
            }
            Button("Join") { sync.joinSeparate() }.settingsButton(keep ? .primary : .secondary)
        }
    }
}

/// A Mac's shape in a gray well, as a basic's glyph sits in the sidebar.
struct DeviceWell: View {
    let symbol: String

    var body: some View {
        Symbol(symbol, size: 15)
            .frame(width: 28, height: 28)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .accessibilityHidden(true)
    }

    /// From `hw.model`. Apple silicon laptops and desktops alike say
    /// "Mac15,3", so a name without its kind is drawn as a laptop, the
    /// Mac most people have.
    static func symbol(model: String) -> String {
        if model.hasPrefix("Macmini") { return "macmini" }
        if model.hasPrefix("iMac") { return "desktopcomputer" }
        if model.hasPrefix("MacPro") { return "macpro.gen3" }
        if model.hasPrefix("iPhone") || SyncPhones.isAndroid(model) { return "iphone" }
        return "laptopcomputer"
    }
}

/// The top of a page further in: Sync's tile, its own name and line.
private struct SyncSubHero: View {
    let title: String
    let detail: String

    var body: some View {
        Section {} header: {
            VStack(spacing: 0) {
                PenTileView(page: .sync).frame(width: 56, height: 56)
                    .padding(.bottom, 12)
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                Text(detail)
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
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: What syncs

struct SyncWhatPage: View {
    @ObservedObject var sync = SyncCenter.shared

    struct Kind {
        let title: String
        let icon: String
        let tint: NSColor
        let collection: String
        var category: SyncCategory {
            switch collection {
            case SyncShapes.space: return .spaces
            case SyncShapes.tab: return .tabs
            case SyncShapes.bookmark: return .bookmarks
            case SyncShapes.setting: return .settings
            case SyncShapes.file: return .files
            case SyncChats.chat: return .chats
            case SyncShapes.routine: return .routines
            default: return .memory
            }
        }
    }

    /// Each kind wears the tile of its own page where it has one.
    static var kinds: [Kind] { [
        Kind(title: "Spaces", icon: SettingsPage.spaces.icon, tint: .systemGreen, collection: SyncShapes.space),
        Kind(title: "Tabs, pins and folders", icon: SettingsPage.tabs.icon, tint: .systemGray, collection: SyncShapes.tab),
        Kind(title: "Bookmarks", icon: "bookmark", tint: .systemBlue, collection: SyncShapes.bookmark),
        Kind(title: "Settings", icon: SettingsPage.general.icon, tint: .systemGray, collection: SyncShapes.setting),
        Kind(title: "Search, commands, forms and icons", icon: SettingsPage.search.icon, tint: .systemGray, collection: SyncShapes.file),
        Kind(title: "Chats with Claude and ChatGPT", icon: SettingsPage.ai.icon, tint: .systemPurple, collection: SyncChats.chat),
        Kind(title: "Routines", icon: SettingsPage.agentRoutines.icon, tint: .systemPink, collection: SyncShapes.routine),
        Kind(title: "What agents remember", icon: SettingsPage.agentMemory.icon, tint: .systemBrown, collection: SyncShapes.memory),
    ] }

    var body: some View {
        SyncSubHero(title: "What Syncs", detail: "Choose what syncs with this Mac.")
        Section {
            ForEach(Self.kinds, id: \.collection) { kind in
                HStack(spacing: 10) {
                    PenTileView(symbol: kind.icon, tint: kind.tint).frame(width: 28, height: 28)
                    Text(kind.title).frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(sync.counts[kind.collection] ?? 0)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Toggle(kind.title, isOn: Binding(
                        get: { sync.syncs(kind.category) },
                        set: { sync.setSync(kind.category, enabled: $0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel("Sync \(kind.title)")
                        .accessibilityIdentifier("sync.category.\(kind.category.rawValue)")
                }
            }
        } footer: {
            Text("Turning off a category stops sending and receiving it on this Mac. Existing data is kept.")
        }
    }
}

// MARK: The way out

struct SyncOffPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var sync = SyncCenter.shared

    var body: some View {
        SyncSubHero(title: "Turn Off Sync", detail: "Stop syncing this Mac or all devices.")
        Section {
            if sync.canUndoJoining {
                SettingsRow("Undo Joining", detail: "Stop sync on this Mac and restore its spaces, tabs and bookmarks from before joining.") {
                    Button("Undo") { sync.undoJoining(); leave() }
                        .settingsButton()
                }
            }
            SettingsRow("Turn Off on This Mac", detail: "Keep local data and continue syncing on other devices.") {
                Button("Turn Off") { sync.turnOff(handOver: true); leave() }
                    .settingsButton()
            }
            SettingsRow("Delete Sync Data", detail: "Stop sync on all devices and delete server data. Local data is kept on each device.") {
                Button("Delete…") { delete() }
                    .buttonStyle(.yab(.quiet, .regular, tint: ButtonCSS.danger))
            }
        }
    }

    private func leave() { model.leave(SyncPlace.off, to: .sync) }

    private func delete() {
        Task {
            guard await Questions.shared.ask(Question(
                title: "Delete sync data for every device?",
                detail: "Your devices keep their tabs, bookmarks and settings, and stop syncing.",
                glyph: "trash", yes: "Delete Sync Data", danger: true, place: .settings)) else { return }
            sync.turnOff(everywhere: true)
            leave()
        }
    }
}

// MARK: Off

/// Sync off: not a form but a way in, in the middle of the pane, as Spaces
/// is. What goes with it, the one button, and the other way in for a Mac
/// joining an account another one already has.
struct SyncArrival: View {
    @ObservedObject var sync = SyncCenter.shared
    /// Asked to join: the code shows, and waits.
    @State private var asking = false
    /// The code another Mac shows under Add a Device, typed here.
    @State private var typed = ""

    private static var shown: [(icon: String, name: String, tint: NSColor)] { [
        (SettingsPage.spaces.icon, "Spaces", .systemGreen),
        (SettingsPage.tabs.icon, "Tabs", .systemGray),
        ("bookmark", "Bookmarks", .systemBlue),
        (SettingsPage.ai.icon, "Chats", .systemPurple),
        (SettingsPage.history.icon, "History", .systemOrange),
    ] }

    var body: some View {
        Group {
            switch sync.arrival {
            case .nobody where !asking:
                ArrivalPage(page: .sync, title: "Is This Your First Device?", blurb: "Yab didn’t find another device on this Apple ID.") {
                    Button("Start Syncing") { sync.startSyncing() }
                        .buttonStyle(.yab(.primary, .large))
                        .padding(.top, 20)
                    alreadySyncing.padding(.top, 8)
                }
            case .offline where !asking:
                ArrivalPage(page: .sync, title: "You’re Offline", blurb: "Yab needs a connection to look for your other devices.") {
                    Button("Try Again") { sync.turnOn() }
                        .buttonStyle(.yab(.primary, .large))
                        .padding(.top, 20)
                    Button(SettingsWords.text("Cancel")) { sync.stopLooking() }
                        .buttonStyle(.yab(.quiet, .small))
                        .padding(.top, 8)
                }
            default:
                ways
            }
        }
        .onDisappear { sync.stopLooking() }
    }

    private var alreadySyncing: some View {
        Button("Already syncing on another device?") {
            sync.stopLooking()
            asking = true
            typed = ""
            sync.askToJoin()
        }
        .buttonStyle(.yab(.quiet, .small))
    }

    private var ways: some View {
        ArrivalPage(page: .sync, title: "Sync", blurb: SettingsPage.sync.blurb ?? "") {
            if let joining = sync.joining, asking {
                if let check = sync.joiningCheck {
                    invited(check)
                } else {
                    waiting(joining.code)
                }
            } else {
                start
            }
        }
        // Settings closed or another page: the code stops being read.
        .onDisappear {
            guard asking else { return }
            asking = false
            sync.stopAsking()
        }
    }

    @ViewBuilder private var trouble: some View {
        if let trouble = sync.joinTrouble {
            Text(trouble)
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
        }
    }

    @ViewBuilder private var start: some View {
        HStack(spacing: 6) {
            ForEach(Self.shown, id: \.name) { kind in
                HStack(spacing: 6) {
                    PenTileView(symbol: kind.icon, tint: kind.tint, side: 16).frame(width: 16, height: 16)
                    Text(kind.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                .padding(.horizontal, 8)
                .frame(height: Door.side)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
        }
        .padding(.top, 16)
        .accessibilityHidden(true)
        if sync.arrival == .looking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for your other devices…").foregroundStyle(.secondary)
            }
            .padding(.top, 20)
            Button(SettingsWords.text("Cancel")) { sync.stopLooking() }
                .buttonStyle(.yab(.quiet, .small))
                .padding(.top, 4)
                .padding(.bottom, 26) // design: the page stays where Turn On Sync left it
        } else {
            Button("Turn On Sync") { sync.turnOn() }
                .buttonStyle(.yab(.primary, .large))
                .padding(.top, 20)
            Text("Macs using the same Apple ID connect automatically.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 12)
            alreadySyncing.padding(.top, 4)
        }
        if asking { trouble }
    }

    @ViewBuilder private func waiting(_ code: String) -> some View {
        Text("Type this code on a Mac that syncs")
            .font(.system(size: 13, weight: .semibold))
            .padding(.top, 20)
        CodePlates(code: code)
            .padding(.top, 12)
        Text("Choose Add a Device in Settings › Sync on that Mac, then enter this code.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 340)
            .padding(.top, 12)
        // The other way round: the code that Mac's Add a Device shows.
        Text("Or enter the code your other Mac shows under Add a Device")
            .font(.system(size: 13, weight: .semibold))
            .padding(.top, 20)
        CodeGroupsField(code: Binding(get: { typed }, set: { typed = CodeGroupsField.clean($0) }),
                        autofocus: false, onSubmit: joinInvite)
            .accessibilityIdentifier("sync-join-invite-code")
            .frame(maxWidth: 340)
            .padding(.top, 8)
        trouble
        HStack(spacing: 8) {
            Button(SettingsWords.text("Cancel")) {
                asking = false
                sync.stopAsking()
            }
            .buttonStyle(.yab(.quiet))
            Button("Use Recovery Key…") { useRecovery() }
                .settingsButton()
            Button("Join") { joinInvite() }
                .settingsButton(.primary)
                .disabled(typed.count != CodeGroupsField.length)
        }
        .padding(.top, 16)
    }

    /// Waiting under the other Mac's code: the digits it asks about.
    @ViewBuilder private func invited(_ check: String) -> some View {
        Text("Let This Mac In on Your Other Mac")
            .font(.system(size: 13, weight: .semibold))
            .padding(.top, 20)
        Text("Choose Let In there if it shows these digits.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.top, 8)
        Text(SyncPage.spaced(check))
            .font(.system(size: 22, weight: .semibold, design: .monospaced))
            .accessibilityIdentifier("sync-join-check")
            .padding(.top, 12)
        Button(SettingsWords.text("Cancel")) {
            typed = ""
            sync.askToJoin()
        }
        .buttonStyle(.yab(.quiet))
        .padding(.top, 16)
    }

    private func joinInvite() {
        guard typed.count == CodeGroupsField.length else { return }
        sync.askToJoin(invite: typed)
    }

    private func useRecovery(_ wrong: Bool = false) {
        let field = Question.Field("", prompt: "XXXX-XXXX-…")
        Task {
            guard await Questions.shared.ask(Question(
                title: "Use the Recovery Key",
                detail: wrong ? "That isn't a Recovery Key. Check each group of four." : "The key Yab showed, or the one in Yab Recovery Key.pdf, from when sync was first turned on.",
                glyph: "key", yes: "Join", place: .settings, field: field)) else { return }
            if sync.join(recovery: field.trimmed) { asking = false } else { useRecovery(true) }
        }
    }
}

/// A code or key in groups of four, each on a plate of its own, so it is
/// read and typed a group at a time; a long key in two lines.
private struct CodePlates: View {
    let code: String
    var size: CGFloat = 17

    var body: some View {
        let groups = Self.groups(code)
        let line = max(1, groups.count <= 4 ? groups.count : (groups.count + 1) / 2)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(stride(from: 0, to: groups.count, by: line)), id: \.self) { start in
                HStack(spacing: 6) {
                    ForEach(start..<min(start + line, groups.count), id: \.self) { at in
                        Text(groups[at])
                            .font(.system(size: size, weight: .semibold, design: .monospaced))
                            .fixedSize()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Palette.wash, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                    }
                }
            }
        }
        .fixedSize()
        .textSelection(.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(code)
    }

    static func groups(_ code: String) -> [String] {
        let chars = code.filter { $0.isLetter || $0.isNumber }
        return stride(from: 0, to: chars.count, by: 4).map {
            let start = chars.index(chars.startIndex, offsetBy: $0)
            return String(chars[start..<chars.index(start, offsetBy: min(4, chars.count - $0))])
        }
    }
}

// MARK: The Recovery Key

/// Right after sync is turned on: the key, and ways to keep it somewhere
/// other than this Mac. Done takes the card away.
private struct RecoveryCard: View {
    let key: String
    @ObservedObject var sync = SyncCenter.shared
    @State private var saved: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PenTileView(symbol: "key", tint: .systemGray).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's gap under a title
                    Text("Recovery Key")
                    Text("Recover synced data if you lose all devices. Save this key now; Yab cannot show it again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            CodePlates(code: key, size: 15)
                .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                if let saved {
                    Button(saved.lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                        .buttonStyle(.yab(.quiet, .small))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                }
                .settingsButton()
                Button("Download…") { saved = RecoveryKit.save(key) ?? saved }
                    .settingsButton()
                Button(SettingsWords.text("Done")) { sync.recovery = nil }
                    .settingsButton(.primary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Yab Recovery Key.pdf: one page with the key, where and when it was
/// made, and how to get back in with it. Drawn on this Mac; nothing of it
/// goes anywhere.
enum RecoveryKit {
    @MainActor
    static func save(_ key: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Yab Recovery Key.pdf"
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return write(key, to: url) ? url : nil
    }

    @MainActor
    static func write(_ key: String, to url: URL) -> Bool {
        let page = CGSize(width: 595, height: 842) // A4 in points
        let renderer = ImageRenderer(content: RecoveryKitPage(key: key, device: SyncCenter.device.name, made: Date())
            .frame(width: page.width, height: page.height))
        var made = false
        renderer.render { _, draw in
            var box = CGRect(origin: .zero, size: page)
            guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
            made = true
        }
        return made
    }
}

/// The page itself, always light, as paper is.
private struct RecoveryKitPage: View {
    let key: String
    let device: String
    let made: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Yab Recovery Key").font(.system(size: 22, weight: .bold))
                    Text("For sync between your devices").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            heading("Your key")
            CodePlates(code: key, size: 20)
            heading("Made")
            Text("On \(device), \(made.englishFormatted(date: .long, time: .omitted))")
            heading("To get back in")
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Install Yab from yetanotherbrowser.com.")
                Text("2. Open Settings › Sync and choose Already syncing on another device?")
                Text("3. Choose Use Recovery Key… and type the key above.")
            }
            heading("Keep it safe")
            Text("Anyone with this key can read your synced spaces, tabs, bookmarks and chats. Print it or keep it in a password manager, away from your Mac.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text("Yab never sends this key anywhere.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .foregroundStyle(.black)
        .padding(48) // design: a printed page's margin
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private func heading(_ words: String) -> some View {
        Text(words.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }
}
