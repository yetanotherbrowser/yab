import AppKit
import Foundation
import SQLite3

// Messages for an agent: your chats read from the Mac's own Messages
// database, and a message sent through Messages.app.
//
// Reading goes through the same one switch as the texted codes, Settings ›
// Agents › Messages, and the same Full Disk Access; a task kept to the
// browser gets none of it. Sending is a press that can't be taken back: it
// waits for your yes, the whole text on the card, ⌘Return, as a Send in a
// page does, unless the mode is Bypass.

enum AgentMessages {
    struct Line {
        let when: Date
        let mine: Bool
        let from: String
        let text: String
    }

    private static var path: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path
    }

    /// The chats with the most recent first: who, and the last thing said.
    static func chats(limit: Int) -> Result<[String], AgentFiles.Trouble> {
        read { db in
            let sql = """
            SELECT c.chat_identifier, IFNULL(c.display_name, ''), m.text, m.attributedBody, m.is_from_me, m.date
            FROM chat c
            JOIN chat_message_join j ON j.chat_id = c.ROWID
            JOIN message m ON m.ROWID = j.message_id
            WHERE m.date = (SELECT MAX(m2.date) FROM chat_message_join j2 JOIN message m2 ON m2.ROWID = j2.message_id WHERE j2.chat_id = c.ROWID)
            ORDER BY m.date DESC LIMIT ?
            """
            var out: [String] = []
            each(db, sql, bind: [limit]) { row in
                let id = column(row, 0)
                let name = column(row, 1)
                let text = body(row, 2, 3)
                let mine = sqlite3_column_int(row, 4) == 1
                let when = date(sqlite3_column_double(row, 5))
                out.append("\(name.isEmpty ? id : "\(name) (\(id))") · \(ago(when)) · \(mine ? "you: " : "")\(text.prefix(120))")
            }
            return out
        }
    }

    /// One chat's last messages, oldest first, by its identifier (a phone
    /// number or an address, as `chats` gives it) or its name.
    static func thread(_ chat: String, limit: Int) -> Result<[String], AgentFiles.Trouble> {
        read { db in
            let sql = """
            SELECT m.text, m.attributedBody, m.is_from_me, m.date, IFNULL(h.id, '')
            FROM chat c
            JOIN chat_message_join j ON j.chat_id = c.ROWID
            JOIN message m ON m.ROWID = j.message_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE c.chat_identifier = ?1 OR c.display_name = ?1 OR c.chat_identifier LIKE '%' || ?1
            ORDER BY m.date DESC LIMIT ?2
            """
            var lines: [String] = []
            each(db, sql, bind: [chat, limit]) { row in
                let text = body(row, 0, 1)
                guard !text.isEmpty else { return }
                let mine = sqlite3_column_int(row, 2) == 1
                let when = date(sqlite3_column_double(row, 3))
                let from = mine ? "you" : column(row, 4)
                lines.append("\(ago(when)) · \(from): \(text)")
            }
            return lines.reversed()
        }
    }

    // MARK: - sending

    /// Through Messages.app, to a phone number or an address: iMessage if
    /// they have it, else a text. Nil when it went.
    @MainActor
    static func send(_ text: String, to handle: String) -> String? {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let source = """
        tell application "Messages"
            try
                set target to participant \(quoted(handle)) of (1st account whose service type = iMessage)
                send \(quoted(text)) to target
            on error
                set target to participant \(quoted(handle)) of (1st account whose service type = SMS)
                send \(quoted(text)) to target
            end try
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { return error[NSAppleScript.errorMessage] as? String ?? "Messages didn't send it" }
        return nil
    }

    // MARK: - the database

    private static func read(_ work: (OpaquePointer) -> [String]) -> Result<[String], AgentFiles.Trouble> {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return .failure(.access)
        }
        defer { sqlite3_close(db) }
        // Without Full Disk Access the file opens and every query fails.
        var probe: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM chat LIMIT 1", -1, &probe, nil) == SQLITE_OK else { return .failure(.access) }
        sqlite3_finalize(probe)
        return .success(work(db))
    }

    private static func each(_ db: OpaquePointer, _ sql: String, bind: [Any], row: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bind.enumerated() {
            if let number = value as? Int { sqlite3_bind_int(statement, Int32(index + 1), Int32(number)) }
            if let text = value as? String { sqlite3_bind_text(statement, Int32(index + 1), text, -1, transient) }
        }
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }

    private static func column(_ row: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(row, index).map { String(cString: $0) } ?? ""
    }

    /// A message's words: `text`, or, since macOS 13 often only that, the
    /// string inside its archived `attributedBody`.
    private static func body(_ row: OpaquePointer, _ textColumn: Int32, _ blobColumn: Int32) -> String {
        let text = column(row, textColumn)
        if !text.isEmpty { return text.replacingOccurrences(of: "\n", with: " ") }
        guard let bytes = sqlite3_column_blob(row, blobColumn) else { return "" }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, blobColumn)))
        return archived(data).replacingOccurrences(of: "\n", with: " ")
    }

    /// The NSString in a typedstream archive: after its class name, five
    /// bytes, then a length (one byte, or 0x81 and two little-endian bytes).
    static func archived(_ data: Data) -> String {
        guard let mark = data.range(of: Data("NSString".utf8)) else { return "" }
        var at = mark.upperBound + 5
        guard at < data.count else { return "" }
        var length = Int(data[at])
        at += 1
        if length == 0x81, at + 1 < data.count {
            length = Int(data[at]) | Int(data[at + 1]) << 8
            at += 2
        }
        guard length > 0, at + length <= data.count else { return "" }
        return String(decoding: data[at..<at + length], as: UTF8.self)
    }

    private static func date(_ raw: Double) -> Date {
        // Nanoseconds since 2001 now; seconds in databases older than 2017.
        Date(timeIntervalSinceReferenceDate: raw > 1e12 ? raw / 1_000_000_000 : raw)
    }

    static func ago(_ when: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(when) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        if minutes < 48 * 60 { return "\(minutes / 60) h ago" }
        return AppDates.string(from: when, dateStyle: .medium, timeStyle: .none)
    }
}
