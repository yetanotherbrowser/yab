import Foundation

/// The Mac's commands in the field (Sources/Fast/Query.swift's Command): a
/// menu action found by its name or another word for it. Its name typed
/// whole leads every other row; begun, it stands under the first.
struct CommandCandidate: Equatable, Sendable {
    /// What runs it (BrowserKey's token).
    let token: String
    let title: String
    var aliases: [String] = []
    /// The keys that do it, for the row's end ("⇧⌘R").
    var shortcut = ""
}

extension Words {
    static func commandRows(_ typed: String, commands: [CommandCandidate]) -> (exact: [WordRow], begun: [WordRow]) {
        let text = name(typed)
        guard !text.isEmpty else { return ([], []) }
        var exact: [WordRow] = [], begun: [WordRow] = []
        for command in commands {
            let names = [name(command.title)] + command.aliases.map(name)
            let row = WordRow(action: .command(command.token), icon: .settings, title: command.title.replacingOccurrences(of: "…", with: ""),
                              subtitle: command.shortcut.isEmpty ? "Yab" : "Yab · \(command.shortcut)", key: .go, group: .yab)
            if names.contains(text) { exact.append(row) }
            else if text.count >= 3, names.contains(where: { begins($0, text) }) { begun.append(row) }
        }
        return (exact, Array(begun.prefix(2)))
    }

    /// The rows with the commands among them: whole names first, begun ones second.
    static func withCommands(_ rows: [WordRow], typed: String, commands: [CommandCandidate]) -> [WordRow] {
        let found = commandRows(typed, commands: commands)
        var rows = rows
        rows.insert(contentsOf: found.begun, at: min(1, rows.count))
        rows.insert(contentsOf: found.exact, at: 0)
        return rows
    }

    private static func name(_ text: String) -> String {
        text.replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The name, or one of its words, begins with the words typed.
    private static func begins(_ name: String, _ text: String) -> Bool {
        name.hasPrefix(text) || name.split(separator: " ").contains { $0.hasPrefix(text) }
    }
}
