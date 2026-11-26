import Foundation
import CryptoKit
import SyncKit

/// A conversation with an agent, whichever it is and wherever it began: a
/// command on a selection, a task Here, a task in tabs of its own. What
/// its column and the history show, and what is kept of it once its
/// session is gone from memory.
struct Chat: Codable, Identifiable, Equatable {
    enum Began: String, Codable { case field, here, newTabs, other }

    /// A subagent of its, by the name it was given.
    struct Sub: Codable, Equatable, Identifiable {
        let id: String
        var name: String
        var state: String
    }

    /// A tab it opened, or one of its subagents did (`by`).
    struct TabRef: Codable, Equatable, Identifiable {
        let id: String
        var url: String
        var title: String
        var by: String?
    }

    /// The id of its root session.
    let id: String
    var title: String
    var began: Began
    var cli: String
    var model: String?
    /// Codex's thread id or Claude Code's session id, to carry on from.
    var thread: String?
    var items: [ChatItem]
    var subagents: [Sub] = []
    var tabs: [TabRef] = []
    var pinned = false
    /// Put away: out of the list, in Archived Chats, kept for good. Optional,
    /// so chats written before it read as they were.
    var archived: Bool?
    /// A task's answer not opened yet: a dot in the list, until it is.
    var unread: Bool?
    /// A name and read state chosen on another device, kept when a live
    /// session next tells the chat its generated title and task state.
    var titleOverride: String?
    var unreadOverride: Bool?
    var unreadGeneration: String?
    var metadataStamps: [String: Stamp]?
    /// The session's state as it was last seen: running, done, failed.
    var state: String
    var answer: String
    var started: Date
    var updated: Date
    /// Get to Know's run: its answer leads to its notebook (yab://you).
    /// Optional, so chats written before it read as they were.
    var knowing: Bool?
    /// Keep automatic provider cleanup when this Yab chat is resumed later.
    var providerBackground: Bool? = nil
    /// Mail began it or went into it with nothing on its steps to say so:
    /// a task from mail, a routine on a split's mail. Optional, so chats
    /// written before it read as they were.
    var mail: Bool? = nil

    /// A task sent from the iPhone (SyncTaskRead): kept with its chat, so a
    /// chat brought back after a relaunch still only reads. Local, never
    /// synced, never a permission.
    var remoteTask: RemoteTaskOrigin? = nil

    /// Who began it, when not the person: an outside agent's task
    /// (`agent`), a routine's run (`routine`) or a command (`cli`), as
    /// SyncChat.Origin says; nil for the person's own and older chats.
    var source: String? = nil
    /// The routine whose run it is.
    var routine: String? = nil
    /// The project it is in (Projects), none for a chat on its own.
    /// Optional, so chats written before it read as they were.
    var project: String? = nil
    /// Gemini never revives with Mac access; retain a text chat's narrower boundary.
    /// nil is a record from before this field existed.
    var textOnly: Bool? = nil
    /// Gemini's explicit reasoning choice, kept with its model across relaunch.
    var effort: String? = nil
    /// Stopped, or its next message still owes the agent the stop note
    /// (Agents.stoppedLine), when last kept: a chat brought back after a
    /// relaunch says so too (#964). Optional, so chats written before it
    /// read as they were.
    var afterStop: Bool? = nil

    /// Gmail's data is in it: mail began it, an email or a list was given,
    /// or a mail tool ran. Such a chat stays on this Mac: sync never sends
    /// it (docs/casa.md, Sync).
    var withMail: Bool { mail == true || Chat.mail(in: items) }

    static func mail(in items: [ChatItem]) -> Bool {
        items.contains { item in
            item.kind == .tool && item.name.hasPrefix("mail_")
                || item.kind == .asked && item.detail.split(separator: "\n").contains { $0.hasPrefix("m:") }
        }
    }

    /// Put away into Archived Chats this long after it was last touched,
    /// as tabs are tidied (Tidy): Settings › Agents, a month unless changed.
    static let archiveKey = "chats.archive"
    static var archiveAfter: Tidy {
        (Store.settings.object(forKey: archiveKey) as? Int).flatMap(Tidy.init) ?? .month
    }

    /// Gone that long untouched, and neither pinned nor put away already.
    func stale(now: Date = Date(), after wait: TimeInterval?) -> Bool {
        guard let wait else { return false }
        return !pinned && archived != true && now.timeIntervalSince(updated) >= wait
    }

    /// Its turns: each what was asked and all that came of it. Steps before
    /// the first question (none, usually) make a turn of their own.
    var turns: [[ChatItem]] {
        var out: [[ChatItem]] = []
        for item in items where !item.isInternalContinuation {
            // Words steered into a turn stay in it.
            if item.kind == .asked && item.name != "steer" || out.isEmpty { out.append([item]) } else { out[out.count - 1].append(item) }
        }
        return out
    }

    /// How long a turn's work went on, from its first step to its last,
    /// less the time it waited on you.
    static func worked(_ turn: [ChatItem]) -> TimeInterval? {
        let starts = turn.compactMap(\.began)
        let ends = turn.compactMap { $0.ended ?? $0.began }
        guard let first = starts.min(), let last = ends.max(), last > first else { return nil }
        return max(1, last.timeIntervalSince(first) - waited(turn, now: last))
    }

    /// The tools that wait on the person: a question, a request handed over,
    /// leave to use the Mac.
    static let asking: Set<String> = ["ask", "AskUserQuestion", "handoff", "computer_access", "folder_access"]

    /// How long a turn waited on you, those tools' time put together.
    static func waited(_ turn: [ChatItem], now: Date = Date()) -> TimeInterval {
        turn.filter { $0.kind == .tool && asking.contains($0.name) }.reduce(0) { sum, item in
            guard let began = item.began else { return sum }
            return sum + max(0, (item.ended ?? now).timeIntervalSince(began))
        }
    }

    /// What went wrong, in plain words, from what the agent said: the
    /// server, the plan's room, the connection, or it stopping.
    static func failure(_ raw: String, agent: String) -> String {
        ChatProblem(raw, agent: agent).title
    }

    /// Some CLIs repeat an API error as an assistant message. Keep real
    /// partial answers, but render that diagnostic only in the failure card.
    static func visibleMessage(_ item: ChatItem, failed: Bool, failure: String) -> Bool {
        guard item.kind == .message, !item.isAside, !item.text.isEmpty else { return false }
        guard failed, item.text == failure else { return true }
        // "You've hit your weekly limit": the card and Yab's line say it.
        let problem = ChatProblem(failure, agent: "")
        if problem.kind == .quota { return false }
        return item.state != .failed && !problem.isEnvelope &&
            !failure.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("api error:")
    }

    private var problem: ChatProblem {
        ChatProblem(answer, agent: AgentPlan.of(cli)?.name ?? "Your agent")
    }

    /// History and copying use the same readable error as the transcript.
    var preview: String { state == "failed" ? problem.title : Self.plain(answer) }
    var copyTitle: String { state == "failed" ? "Copy Error" : "Copy Answer" }
    var copiedAnswer: String {
        guard state == "failed" else { return Self.plain(answer) }
        let error = problem
        return [error.title, error.detail, error.code, error.diagnostics].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// "1m 12s", "40s": how long, as the divider says it.
    static func span(_ seconds: TimeInterval) -> String {
        let whole = max(1, Int(seconds.rounded()))
        if whole < 60 { return "\(whole)s" }
        if whole < 3600 { return whole % 60 == 0 ? "\(whole / 60)m" : "\(whole / 60)m \(whole % 60)s" }
        return "\(whole / 3600)h \(whole % 3600 / 60)m"
    }

    /// An answer in one plain line: its links' words, no marks.
    static func plain(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"[*_`#]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Its heading in a list of chats: Pinned when pinned (kept for good), else Today,
    /// Yesterday or Earlier, by when it was last touched.
    func section(now: Date = Date(), calendar: Calendar = .current) -> String {
        if pinned { return "Pinned" }
        if calendar.isDate(updated, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(updated, inSameDayAs: yesterday) { return "Yesterday" }
        return "Earlier"
    }

    /// Chats in the order their sections go: those kept for good first,
    /// then the rest, the newest first within each.
    static func listed(_ chats: [Chat]) -> [Chat] {
        chats.sorted { $0.pinned == $1.pinned ? $0.updated > $1.updated : $0.pinned }
    }

    /// What its words are found in: its title, what was asked, the answer.
    var words: String {
        ([title, answer] + items.filter { $0.kind == .asked && !$0.isInternalContinuation }.map(\.text)).joined(separator: " ")
    }

    /// A few words for a chat with no title of its own: the start of what
    /// was first asked.
    static func title(from asked: String) -> String {
        let line = asked.split(whereSeparator: \.isNewline).first.map(String.init) ?? asked
        let words = line.trimmingCharacters(in: .whitespaces)
        return words.count > 60 ? String(words.prefix(59)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : words
    }

    func keepingMetadata(from old: Chat?) -> Chat {
        guard let old else { return self }
        var chat = self
        chat.pinned = old.pinned
        chat.archived = old.archived
        chat.titleOverride = old.titleOverride
        chat.metadataStamps = old.metadataStamps
        if let origin = old.remoteTask { chat.remoteTask = origin }
        if chat.cli == "gemini", old.cli == chat.cli, chat.textOnly == nil { chat.textOnly = old.textOnly }
        chat.unreadOverride = old.unreadOverride
        chat.unreadGeneration = old.unreadGeneration
        if old.unreadOverride == false, old.unreadGeneration != chat.readGeneration {
            chat.unreadOverride = nil
            chat.unreadGeneration = nil
        }
        if let title = old.titleOverride { chat.title = title }
        if let unread = chat.unreadOverride { chat.unread = unread ? true : nil }
        return chat
    }

    /// Rendering/metadata timestamps move without a new answer. A read
    /// applies to this turn and answer, including repeated identical words
    /// in a later turn, rather than to the lifetime of the conversation.
    var readGeneration: String {
        Self.readGeneration([items.last { $0.kind == .asked && !$0.isInternalContinuation && $0.name != "steer" }?.id ?? "",
                             items.last { $0.kind == .message }?.id ?? "", answer])
    }

    static func readGeneration(_ parts: [String]) -> String {
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Every chat kept, newest first. Read once from `chats/` in the app's
/// folder, written a moment after each change, off the main thread.
@MainActor
final class Chats: ObservableObject {
    static let shared = Chats()

    @Published private(set) var all: [Chat] = []
    private(set) var loaded = false
    private var waiting: [String: Chat] = [:]
    private var writing = false
    private static let disk = DispatchQueue(label: "yab.chats", qos: .utility)
    private let storage: URL

    nonisolated static var folder: URL { Store.file("chats") }

    /// The projects its chats are in (Chat.project); a test gives its own.
    var projects: Projects { ownProjects ?? .shared }
    private var ownProjects: Projects?

    init(folder: URL = Chats.folder, projects: Projects? = nil) {
        storage = folder
        ownProjects = projects
    }

    func chat(_ id: String?) -> Chat? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// The chats on disk; those gone untouched past the setting put away.
    func load() {
        guard !loaded else { return }
        loaded = true
        let folder = storage
        Chats.disk.async {
            let found = Chats.read(folder)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Anything kept since loading began is newer than the disk.
                    var merged = self.all
                    for chat in found where !merged.contains(where: { $0.id == chat.id }) { merged.append(chat) }
                    self.all = merged.sorted { $0.updated > $1.updated }
                    self.archiveOld()
                }
            }
        }
    }

    nonisolated static func read(_ folder: URL, now: Date = Date()) -> [Chat] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var out: [Chat] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let chat = try? decoder.decode(Chat.self, from: data) else { continue }
            out.append(chat)
        }
        return out.sorted { $0.updated > $1.updated }
    }

    /// A chat as it is now, first in the list, on disk a moment later.
    func keep(_ chat: Chat) {
        let chat = chat.keepingMetadata(from: self.chat(chat.id))
        if let index = all.firstIndex(where: { $0.id == chat.id }) {
            guard all[index] != chat else { return }
            all.remove(at: index)
        }
        all.insert(chat, at: 0)
        save(chat)
    }

    @discardableResult
    func adoptSynced(_ id: String, metadata: SyncChats.Metadata) -> Bool {
        // Sync can arrive before the asynchronous chat list has loaded.
        // Only an existing local file can supply a head missing in memory.
        if !all.contains(where: { $0.id == id }), let found = Chats.read(id, from: storage) {
            all.append(found)
        }
        guard let index = all.firstIndex(where: { $0.id == id }) else { return false }
        var chat = all[index]
        let metadata = metadata.after(chat.metadataStamps)
        if let title = metadata.title { chat.title = title; chat.titleOverride = title }
        if let pinned = metadata.pinned { chat.pinned = pinned }
        if let archived = metadata.archived { chat.archived = archived ? true : nil }
        // Moved there: into a project this Mac has, or out of one.
        if metadata.moved, metadata.project == nil || projects.project(metadata.project) != nil {
            chat.project = metadata.project
            Agents.shared.session(id)?.project = metadata.project
        }
        if let unread = metadata.unread {
            chat.unread = unread ? true : nil
            chat.unreadOverride = unread
            chat.unreadGeneration = chat.readGeneration
        }
        if !metadata.stamps.isEmpty {
            chat.metadataStamps = (chat.metadataStamps ?? [:]).merging(metadata.stamps) { _, new in new }
        }
        guard chat != all[index] else { return false }
        all[index] = chat
        save(chat)
        return true
    }

    nonisolated private static func read(_ id: String, from folder: URL) -> Chat? {
        guard !id.isEmpty, !id.contains("/"), !id.contains("\\") else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(id + ".json")),
              let chat = try? decoder.decode(Chat.self, from: data), chat.id == id else { return nil }
        return chat
    }

    /// Opened: its dot goes, and its task's answer counts as read.
    func read(_ id: String) {
        if let session = Agents.shared.session(id), session.task {
            session.read = true
            // A row of Now handed to it: its answer, opened.
            if session.state == .done { Hints.shared.opened(session.id, by: "chat") }
        }
        guard let index = all.firstIndex(where: { $0.id == id }),
              all[index].unread == true || all[index].unreadOverride == true else { return }
        all[index].unread = nil
        all[index].unreadOverride = false
        all[index].unreadGeneration = all[index].readGeneration
        save(all[index])
    }

    func rename(_ id: String, _ title: String) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].title = title
        all[index].titleOverride = title
        save(all[index])
    }

    /// Every chat gone untouched past Settings › Agents' wait, into
    /// Archived Chats. At load and whenever Yab comes to the front; never a
    /// chat at work.
    func archiveOld(now: Date = Date()) {
        let wait = Chat.archiveAfter.seconds
        for index in all.indices where all[index].stale(now: now, after: wait) && Agents.shared.session(all[index].id)?.state.live != true {
            all[index].archived = true
            save(all[index])
        }
    }

    /// Put away, or back in the list.
    func archive(_ id: String, _ on: Bool) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].archived = on ? true : nil
        save(all[index])
    }

    func pin(_ id: String, _ on: Bool) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].pinned = on
        save(all[index])
    }

    /// Into a project, or out of one (`nil`), its session with it so the
    /// next turn is told the project's brief. Its place in the list stays.
    func move(_ ids: [String], to project: String?) {
        for id in ids {
            Agents.shared.session(id)?.project = project
            guard let index = all.firstIndex(where: { $0.id == id }), all[index].project != project else { continue }
            all[index].project = project
            save(all[index])
        }
        if let project, !ids.isEmpty { projects.touch(project) }
    }

    /// The chats of a project, newest first.
    func of(project id: String) -> [Chat] {
        all.filter { $0.project == id && $0.archived != true }
    }

    func remove(_ id: String) {
        all.removeAll { $0.id == id }
        waiting[id] = nil
        let file = storage.appendingPathComponent(id + ".json")
        Chats.disk.async {
            try? FileManager.default.removeItem(at: file)
            // The pages its agent published, Yab's copies of them.
            ArtifactPages.forget(chat: id)
        }
    }

    private func save(_ chat: Chat) {
        waiting[chat.id] = chat
        guard !writing else { return }
        writing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let batch = Array(self.waiting.values)
            self.waiting = [:]
            self.writing = false
            let folder = self.storage
            Chats.disk.async { Chats.write(batch, to: folder) }
        }
    }

    /// Wait for changes already kept in memory to reach this store's folder.
    func flush() async {
        let batch = Array(waiting.values)
        waiting = [:]
        let folder = storage
        await withCheckedContinuation { continuation in
            Chats.disk.async {
                Chats.write(batch, to: folder)
                continuation.resume()
            }
        }
    }

    nonisolated static func write(_ chats: [Chat], to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        for chat in chats {
            guard let data = try? encoder.encode(chat) else { continue }
            try? data.write(to: folder.appendingPathComponent(chat.id + ".json"), options: .atomic)
        }
    }
}

extension Chat {
    /// Its place in a list: kept for good or not is part of it.
    var listed: String { id + (pinned ? ".kept" : "") }
}
