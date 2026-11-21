import SwiftUI

/// Settings › Shortcuts: one search and two independent filters above the
/// existing table. Browser groups come first and Mail comes last. Drawn as
/// the Form's groups are, but as one lazy list: a Form keeps every row of a
/// 12,000 point page alive and works them all out as it scrolls.
@MainActor
struct ShortcutsPage: View {
    @ObservedObject var selection: ShortcutFilter.Selection
    @StateObject private var changes = ShortcutFilter.Changes()
    @AppStorage(MailExperiment.key, store: Store.settings) private var mailExperiment = false
    @ObservedObject private var snippets = MailSnippets.shared
    @ObservedObject private var here = ExtensionsHere.shared

    /// What a row of the list holds.
    private enum Cell {
        case shortcut(Shortcut.Item)
        case command(Command)
        case snippet(MailSnippet)
        case extensionCommand(Extensions.CommandEntry, Installed)
        case nothing
    }

    /// One line of the list. Its id is the row's anchor, so the search can
    /// bring a row into view before it has been built.
    private enum Line: Identifiable {
        case head(String, first: Bool)
        case note(String)
        case row(id: String, Cell, first: Bool, last: Bool)

        var id: String {
            switch self {
            case .head(let title, _): return "head:" + title
            case .note(let words): return "note:" + words
            case .row(let id, _, _, _): return id
            }
        }
    }

    var body: some View {
        let _ = changes
        let groups = Shortcut.all.filter { mailExperiment || $0.title != "Mail" }
        let entries = ShortcutFilter.catalog(groups: groups, snippets: snippets.ordered)
        let visible = ShortcutFilter.visible(entries, search: selection.search, modifications: selection.modifications,
                                             categories: selection.chosen)
        let ids = Set(visible.map(\.id))
        ThreadScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines(groups, ids: ids, none: visible.isEmpty)) { line in
                    view(of: line)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 20)
        }
        .onChange(of: ShortcutFilter.categories(entries), initial: true) { _, categories in selection.categories = categories }
        .onChange(of: ShortcutFilter.counts(entries), initial: true) { _, counts in selection.counts = counts }
    }

    private func lines(_ groups: [Shortcut.Group], ids: Set<String>, none: Bool) -> [Line] {
        var lines: [Line] = []
        func part(_ title: String?, _ cells: [(id: String, cell: Cell)]) {
            guard !cells.isEmpty else { return }
            if let title { lines.append(.head(title, first: lines.isEmpty)) }
            for (index, row) in cells.enumerated() {
                lines.append(.row(id: row.id, row.cell, first: index == 0, last: index == cells.count - 1))
            }
        }
        func core(_ groups: [Shortcut.Group]) {
            for group in groups {
                part(group.title, group.items.filter { ids.contains($0.id) }.map { ("key:" + $0.id, .shortcut($0)) })
            }
        }
        core(groups.filter { !$0.title.hasPrefix("Mail") })
        part("Commands", CommandHotkeys.commands.filter { ids.contains($0.shortcutID) }.map { ("key:" + $0.shortcutID, .command($0)) })
        part(SettingsWords.text("Snippets"), snippets.ordered.filter { ids.contains("snippet." + $0.id) }
            .map { ("key:snippet." + $0.id, .snippet($0)) })
        let extensions = here.current.commandGroups().compactMap { group -> (Installed, String, [Extensions.CommandEntry])? in
            let commands = group.commands.filter { ids.contains("ext." + $0.id) }
            return commands.isEmpty ? nil : (group.item, group.short, commands)
        }
        for (item, short, commands) in extensions {
            part(short, commands.map { ("key:ext." + $0.id, .extensionCommand($0, item)) })
        }
        if !extensions.isEmpty { lines.append(.note("Aliases run commands from ⌘T. Hotkeys work while Yab is active.")) }
        core(groups.filter { $0.title.hasPrefix("Mail") })
        if none { lines.append(.row(id: "none", .nothing, first: true, last: true)) }
        return lines
    }

    @ViewBuilder private func view(of line: Line) -> some View {
        switch line {
        case .head(let title, let first):
            Text(title)
                .font(.system(size: 13, weight: FormGroupRow<EmptyView>.headWeight))
                .padding(.horizontal, 10)
                .padding(.top, first ? 0 : 24)
                .padding(.bottom, 10)
        case .note(let words):
            SettingsNote(words)
                .padding(.horizontal, 10)
                .padding(.top, 8)
        case .row(let id, let cell, let first, let last):
            FormGroupRow(first: first, last: last) {
                switch cell {
                case .shortcut(let item): ShortcutRow(item: item).settingsAnchor(id)
                case .command(let command):
                    CommandShortcutRow(command: command, slot: Keymap.shared.slot(for: command)).settingsAnchor(id)
                case .snippet(let snippet): SnippetShortcutRow(snippet: snippet).settingsAnchor(id)
                case .extensionCommand(let entry, let item):
                    ExtensionCommandRow(entry: entry, icon: icon(item.id), extensions: here.current).settingsAnchor(id)
                case .nothing:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No shortcuts found").foregroundStyle(.secondary)
                        Button("Clear filters", action: selection.clear).settingsButton()
                    }
                }
            }
        }
    }

    private func icon(_ id: String) -> NSImage? {
        here.current.buttons.first { $0.id == id }?.icon ?? here.current.icon(for: id, side: 16)
    }

    /// A complete chord is exact; modifier-only filters mean all those
    /// modifiers, even when another modifier sits between them on screen.
    /// Values only: the caller supplies the current/custom or fixed caps.
    nonisolated static func keysMatch(_ caps: [[String]], _ keys: String, whole: Bool) -> Bool {
        guard !keys.isEmpty else { return false }
        let keys = keys.lowercased()
        return caps.contains { caps in
            let printed = caps.joined().lowercased()
            return whole ? printed == keys : keys.allSatisfy { printed.contains($0) }
        }
    }

    /// Every word typed somewhere in what the key does, in any order:
    /// "keep tab" finds "Keep tab, or release it" as "tab keep" does.
    nonisolated static func says(_ does: String, _ needle: String) -> Bool {
        let words = does.lowercased()
        let typed = needle.lowercased().split(whereSeparator: \.isWhitespace)
        return !typed.isEmpty && typed.allSatisfy { words.contains($0) }
    }
}

/// A snippet's hotkey, its recorder and a way to take the key off.
private struct SnippetShortcutRow: View {
    let snippet: MailSnippet

    var body: some View {
        HStack(spacing: 12) {
            Text(";" + snippet.name)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            ShortcutRecorder(
                current: Hotkey(stored: snippet.hotkey),
                clash: { MailSnippets.shared.clash($0, for: snippet.id) },
                save: { key in
                    var now = snippet
                    now.hotkey = key?.stored ?? ""
                    MailSnippets.shared.change(now)
                }
            )
        }
        .contextMenu {
            Button(SettingsWords.text("Remove")) {
                var now = snippet
                now.hotkey = ""
                MailSnippets.shared.change(now)
            }
        }
    }
}

/// One shortcut: what it does, and its key in the Hotkey column. A key the
/// monitor keeps to itself has its caps and no cell to record in.
private struct ShortcutRow: View {
    let item: Shortcut.Item

    var body: some View {
        if let action = item.action {
            ShortcutActionRow(does: item.does, action: action, slot: Keymap.shared.slot(action))
        } else {
            HStack(spacing: 12) {
                Text(item.does)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    ForEach(Array(item.fixed.enumerated()), id: \.offset) { _, caps in
                        HotkeyCaps(symbols: caps, fontSize: 10, snug: true)
                    }
                }
                .accessibilityLabel(item.fixed.map { $0.joined() }.joined(separator: ", "))
                .modifier(TableCell(width: TableCell.column))
            }
        }
    }
}

/// A row whose key can be changed, watching that action's key alone.
struct ShortcutActionRow: View {
    let does: String
    let action: Shortcut.Action
    @ObservedObject var slot: KeySlot
    /// Raycast's hotkey row: the keys on a filled button, and a reset
    /// button beside it while they are not the default.
    var pill = false

    var body: some View {
        HStack(spacing: pill ? 6 : 12) {
            Group {
                if action == .newSmallWindow {
                    GlobalKeyWords(does: does, key: LinkWindow.globalKey,
                                   off: "Disabled in Small Window settings. Record a hotkey to enable it.")
                } else if action == .showYab {
                    GlobalKeyWords(does: does, key: ShowYab.globalKey)
                } else {
                    Text(does).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ShortcutRecorder(
                current: slot.keys,
                clash: { Keymap.shared.clash($0, for: action) },
                save: { Keymap.shared.set($0, for: action) },
                allowPlain: Shortcut.byAction[action]?.key?.flags.intersection([.command, .option, .control]).isEmpty == true,
                lit: slot.pointed,
                listen: slot.asked,
                heard: { slot.asked = false },
                pill: pill
            )
            if pill && !slot.isDefault {
                Button { Keymap.shared.reset(action) } label: {
                    Symbol("arrow.counterclockwise", size: 11, weight: .semibold)
                }
                .buttonStyle(.yab(.secondary, .small, icon: .square))
                .keyTip(SettingsWords.text("Reset to Default"))
                .accessibilityLabel(SettingsWords.text("Reset to Default"))
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reset to Default") { Keymap.shared.reset(action) }
                .disabled(slot.isDefault)
            Button(SettingsWords.text("Remove")) { Keymap.shared.set(nil, for: action) }
                .disabled(slot.keys == nil)
        }
    }
}

/// Command rows use the same recorder, conflict confirmation and reset menu.
private struct CommandShortcutRow: View {
    let command: Command
    @ObservedObject var slot: KeySlot

    var body: some View {
        HStack(spacing: 12) {
            Text(command.shortcutTitle).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            ShortcutRecorder(current: slot.keys,
                             clash: { Keymap.shared.clash($0, forCommand: command) },
                             save: { Keymap.shared.set($0, forCommand: command) })
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reset to Default") { Keymap.shared.reset(command: command) }.disabled(slot.isDefault)
            Button(SettingsWords.text("Remove")) { Keymap.shared.set(nil, forCommand: command) }.disabled(slot.keys == nil)
        }
    }
}

/// A key heard from any app, the small window's or Show Yab's: said under
/// its words when it is off, or another app has it, since its key alone
/// would look as if it worked.
struct GlobalKeyWords: View {
    let does: String
    @ObservedObject var key: GlobalKey
    /// What is said while it is off; nil where off only means no key yet.
    var off: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(does).lineLimit(1)
            if let note = Self.note(key.state, off: off) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    static func note(_ state: GlobalKey.State, off: String?) -> String? {
        switch state {
        case .heard: return nil
        case .off: return off
        case .taken: return "Hotkey used by another app. Close that app or choose another hotkey."
        }
    }
}

// MARK: - the tables' cells

/// A cell of a settings table, Raycast's: its words bare at rest, as wide
/// as its column whatever they are; a hairline round it under the pointer,
/// a firmer one while it has the keys. It never takes a color: whether what
/// was put in it took is said by the card over it (KeySheet).
struct TableCell: ViewModifier {
    static let inset: CGFloat = 6
    static let height: CGFloat = 24
    /// The width of the column the tables keep their cells in: a hotkey's,
    /// a site's alias's, an extension's keys'.
    static let column: CGFloat = 144

    let width: CGFloat
    var hovering = false
    var active = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        return content
            .padding(.horizontal, Self.inset)
            .frame(width: width, height: Self.height, alignment: .leading)
            // Raycast's: a soft plate under the pointer, an outline with the keys.
            .background(shape.fill(Color(nsColor: .quaternarySystemFill)).opacity(hovering && !active ? 1 : 0))
            .overlay(shape.strokeBorder(Color.primary.opacity(active ? 0.35 : 0), lineWidth: 1))
            .contentShape(shape)
    }
}

/// A cell that is one of a few choices, in the tables' column: the choice
/// with ⌄ after it, a plate under it under the pointer, and the choices in
/// Raycast's list on a click (DropMenu).
struct MenuCell<Value: Hashable>: View {
    let title: String
    let options: [(title: String, value: Value)]
    @Binding var selection: Value
    /// The column's width: a table whose words run longer than a hotkey's
    /// (a routine's "Weekdays 9:00 AM") keeps a wider one.
    var width: CGFloat = TableCell.column
    /// The choice at the column's right edge, its list hung from there.
    var trailing = false

    var body: some View {
        DropMenu(title, options: options, selection: $selection, inset: TableCell.inset, trailing: trailing)
            .frame(maxWidth: width, alignment: trailing ? .trailing : .leading)
            .frame(width: width, alignment: trailing ? .trailing : .leading)
    }
}

/// What the card over a cell says of what was put in: it took, or it
/// didn't.
enum Glow {
    case good, bad

    var color: Color {
        switch self {
        case .good: return .green
        case .bad: return ButtonCSS.danger
        }
    }

    /// How long it stays lit before it goes out. The bench holds it
    /// longer, for a picture of it.
    @MainActor static var hold: Double = 0.14
}

/// The card a key is recorded in, and an alias refused in:
/// what was pressed or typed at full size, a line under it, and how to
/// close it. Its top lights green in the moment a key lands and red in the
/// moment one is refused, up fast and out slowly, once.
struct KeySheet<Top: View>: View {
    let glow: Glow?
    var overwrite: (() -> Void)? = nil
    @ViewBuilder let top: () -> Top

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) { top() }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
                .padding(.bottom, 10)
                .padding(.horizontal, 12)
                .background(
                    LinearGradient(colors: [(glow?.color ?? .clear).opacity(glow == nil ? 0 : 0.3), .clear],
                                   startPoint: .top, endPoint: .bottom)
                )
            Divider()
            HStack(spacing: 6) {
                Spacer(minLength: 8)
                Text(SettingsWords.text("Close")).font(.system(size: 11)).foregroundStyle(.secondary)
                HotkeyKeyCap(symbol: "esc", fontSize: 10)
                if let overwrite {
                    Button(action: overwrite) {
                        HStack(spacing: 6) {
                            Text(SettingsWords.text("Overwrite")).font(.system(size: 11, weight: .semibold))
                            HotkeyKeyCap(symbol: "↩", fontSize: 10)
                        }
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(SettingsWords.text("Overwrite"))
                    .padding(.leading, 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 252)
    }
}

/// Lights a card's top for a moment: at once, then out slowly. One
/// animation, not a repeating one, and no fade under Reduce Motion.
@MainActor
func light(_ glow: Binding<Glow?>, _ what: Glow, reduceMotion: Bool) {
    glow.wrappedValue = what
    Task {
        try? await Task.sleep(for: .seconds(Glow.hold))
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.38)) { glow.wrappedValue = nil }
    }
}
