import Foundation
import SyncKit

// Chats with Claude and ChatGPT that sync, and words for them from another
// device (docs/sync.md, "Chats and words from the iPhone"). There are no
// chats of sync's own: each is a chat that runs on one Mac, an agent's
// (Chats), told to the account
// with the turns it has had. Another device reads it and can say something
// in it: the words go up as a `send` record for the Mac that runs the chat,
// which says them in the chat the moment it hears them, as if typed there,
// and marks the record taken.

enum SyncChats {
    static let chat = SyncCollection.chat, item = SyncCollection.chatItem, send = SyncCollection.send
    /// A file's pieces for a send (SyncSendFile): written by the iPhone
    /// before the send and removed by it, only ever read here.
    static let part = SyncCollection.sendPart
    /// How far back chats sync, and how many turns' worth of steps.
    static let days: TimeInterval = 14 * 86_400
    static let itemsKept = SyncChatItem.kept

    /// A chat's record id: its kind and its own id.
    static func id(agent chat: String) -> String { "a:" + chat }

    // MARK: Out

    /// The chat's head: what a list of chats shows (SyncChat.fields).
    @MainActor
    /// `live` is whether an agent works on it now; tests say so themselves.
    static func head(_ chat: Chat, kind: String, device: String, live: Bool? = nil) -> [String: Value] {
        // The model and effort it is on now, as its column's model line says.
        let session = Agents.shared.session(chat.id)
        // Saved going with no agent at it now (Yab quit mid-turn, the agent
        // was stopped from outside): it isn't working, whatever it last said.
        let state = SyncChat.going.contains(chat.state) && !(live ?? (session?.state.live == true)) ? "stopped" : chat.state
        var head = SyncChat(id: id(agent: chat.id), kind: kind, device: device, title: chat.title, state: state, answer: chat.answer,
                            cli: chat.cli, model: session?.model ?? chat.model, started: chat.started.timeIntervalSince1970,
                            updated: chat.updated.timeIntervalSince1970, pinned: chat.pinned, archived: chat.archived == true,
                            unread: chat.unread == true, origin: chat.source, routine: chat.routine)
        // What it asks you to pick from, for the iPhone's card over its field.
        head.choices = Agents.shared.pick(for: chat.id)?.choices ?? []
        head.effort = session?.effort
        head.project = chat.project
        return head.fields
    }

    /// Its last steps, each a record, in order by `n`.
    static func items(_ chat: Chat, record: String) -> [String: [String: Value]] {
        var out: [String: [String: Value]] = [:]
        let kept = chat.items.suffix(itemsKept)
        let first = chat.items.count - kept.count
        for (offset, item) in kept.enumerated() {
            let id = record + "/" + item.id
            out[id] = SyncChatItem(id: id, chat: record, n: first + offset, kind: item.kind.rawValue, name: item.name,
                                   detail: item.detail, text: item.text, state: item.state.rawValue,
                                   began: item.began?.timeIntervalSince1970, ended: item.ended?.timeIntervalSince1970).fields
        }
        return out
    }

    /// The commands this Mac takes from the iPhone, said in its record of
    /// collection `commandcap` (OpenOnMac.capability), id this Mac's id: a
    /// phone offers a command only to a Mac that names its version here.
    /// `open`: Open on Mac. `chatAgent`: a new chat with the agent chosen
    /// there. `chatMetadata`: Pin, Unread, Archive
    /// and Rename made there are taken here (R4). And `atLogin`: Yab opens
    /// at login here (OpenAtLogin), which an iPhone says only then.
    /// `taskRecords` and `taskReadOnly` with this run's `taskReadOnlyEpoch`:
    /// tasks from the iPhone run here, read-only (SyncTasks); a phone sends
    /// one only with the epoch the Mac says now. `attachments`: photos and
    /// files with the words (SyncSendFile). `modelPick` with `models`: the
    /// models a chat can be on here, for the iPhone's picker (ModelPick).
    static func capability(device: String, atLogin: Bool = false, taskEpoch: String? = nil,
                           models: [SyncMacModel] = []) -> [String: Value] {
        let fields: [String: Value] = ["device": .string(device),
         "platform": .string("macos"), AndroidSyncCompatibility.field: .number(Double(AndroidSyncCompatibility.version)),
         "open": .number(Double(OpenOnMac.version)),
         "chatAgent": .number(Double(ChatAgent.version)),
         "questionGeneration": .null,
         "chatMetadata": .number(Double(ChatMetadata.version)),
         "chatControl": .number(Double(ChatControl.version)),
         OpensAtLogin.field: OpensAtLogin.value(atLogin),
         "taskRecords": taskEpoch == nil ? .null : .number(Double(TaskRecords.version)),
         "taskReadOnly": taskEpoch == nil ? .null : .number(Double(TaskRecords.readOnlyVersion)),
         "taskReadOnlyEpoch": Value(taskEpoch),
         AssistantApprovalRecords.field: .number(Double(AssistantApprovalRecords.version)),
         SyncSendFile.capability: .number(Double(SyncSendFile.version)),
         ChatProjects.field: .number(Double(ChatProjects.version))]
        return fields.merging(ModelPick.fields(models)) { _, picked in picked }
    }

    // MARK: Models

    /// The models this Mac's own picker lists for a chat: its agents',
    /// those left out of the lists (Models in lists) left out here too.
    @MainActor
    static func offered() -> [SyncMacModel] {
        let hidden = ModelDefaults.shared.hidden
        return every().filter { AgentModels.here($0.cli) && !hidden.contains($0.id) }
    }

    /// Every model a chat may be put on, hidden or not.
    @MainActor
    static func every() -> [SyncMacModel] {
        (AgentModels.claude + AgentModels.codex() + OpenCodeRunner.models).map {
            SyncMacModel(cli: $0.cli, model: $0.model, name: $0.name, about: $0.about, efforts: $0.efforts)
        }
    }

    /// A picked model and effort as this Mac can take them: a model it
    /// doesn't have (or of another agent than `cli`) is none, so the chat
    /// keeps its own; an effort the model lacks becomes the most it takes
    /// short of it (as ModelFit), else none. A model picks its agent when
    /// none was asked for.
    static func fit(cli: String?, model: String?, effort: String?, among models: [SyncMacModel])
        -> (cli: String?, model: String?, effort: String?) {
        let found = model.flatMap { asked in models.first { $0.model == asked && (cli == nil || $0.cli == cli) } }
        let cli = cli ?? found?.cli
        guard let effort else { return (cli, found?.model, nil) }
        let ladder = ModelFit.ladder
        let takes = found?.efforts ?? models.filter { $0.cli == cli }.flatMap(\.efforts)
        if takes.contains(effort) { return (cli, found?.model, effort) }
        guard let rank = ladder.firstIndex(of: effort), !takes.isEmpty else { return (cli, found?.model, nil) }
        let below = takes.filter { (ladder.firstIndex(of: $0) ?? .max) <= rank }
        let closest = below.max { (ladder.firstIndex(of: $0) ?? 0) < (ladder.firstIndex(of: $1) ?? 0) }
        return (cli, found?.model, closest)
    }

    // MARK: In

    struct Metadata: Equatable {
        var title: String?
        var pinned: Bool?
        var archived: Bool?
        var unread: Bool?
        /// Moved on another device: into a project (`project`), or out of
        /// one (`moved` with no project).
        var moved = false
        var project: String?
        var stamps: [String: Stamp] = [:]

        var isEmpty: Bool { title == nil && pinned == nil && archived == nil && unread == nil && !moved }

        /// Only choices made elsewhere override the agent's generated
        /// values. Reading this Mac's own head must not freeze its unread.
        init(_ record: SyncKit.Record, device: String) {
            func foreign(_ field: String) -> Bool {
                guard let stamp = record.stamps[field], stamp.device != device else { return false }
                return record.deleted.map { stamp > $0 } ?? true
            }
            if foreign("title"), let name = record["title"]?.string, !name.isEmpty { title = name }
            if foreign("pinned") { pinned = record["pinned"]?.bool == true }
            if foreign("archived") { archived = record["archived"]?.bool == true }
            if foreign("unread") { unread = record["unread"]?.bool == true }
            if foreign("project") {
                let asked = record["project"]?.string
                if asked == nil || ChatProjects.valid(asked) { moved = true; project = asked }
            }
            for field in ["title", "pinned", "archived", "unread", "project"] where foreign(field) {
                stamps[field] = record.stamps[field]
            }
        }

        /// A head may arrive again because some other field changed. Do not
        /// reapply a read/rename that this store has already consumed.
        func after(_ saved: [String: Stamp]?) -> Metadata {
            var fresh = self
            fresh.stamps = stamps.filter { field, stamp in
                guard let old = saved?[field] else { return true }
                return stamp > old
            }
            if fresh.stamps["title"] == nil { fresh.title = nil }
            if fresh.stamps["pinned"] == nil { fresh.pinned = nil }
            if fresh.stamps["archived"] == nil { fresh.archived = nil }
            if fresh.stamps["unread"] == nil { fresh.unread = nil }
            if fresh.stamps["project"] == nil { fresh.moved = false; fresh.project = nil }
            return fresh
        }
    }

    /// Resolved heads for chats owned by this Mac. No session is started,
    /// stopped or resumed, and heads of other Macs remain read-only here.
    @MainActor
    @discardableResult
    static func adopt(_ records: [SyncKit.Record], device: String, chats: Chats) -> Set<String> {
        var changed = Set<String>()
        for record in records where record.collection == chat && record.alive() && record["device"]?.string == device {
            let metadata = Metadata(record, device: device)
            guard !metadata.isEmpty else { continue }
            if record["kind"]?.string == "agent", record.id.hasPrefix("a:"),
               chats.adoptSynced(String(record.id.dropFirst(2)), metadata: metadata) { changed.insert(record.id) }
        }
        return changed
    }

    /// Words from another device, as a Mac reads them.
    struct Words: Equatable {
        var id: String
        /// The chat they go into; nil for a new one.
        var chat: String?
        var text: String
        /// For a new chat: "agent".
        var kind: String
        var project: String?
        /// An answer to the chat's question by number, instead of words.
        var choice: Int?
        var at: Date
        /// Invalid choices are failed, never treated as ordinary words.
        var invalidChoice = false
        var cli: String? = nil
        var invalidAgent = false
        /// Stop or Delete the chat instead of saying words (ChatControl).
        var action: SyncSend.Action? = nil
        /// Photos and files with the words, their bytes in `sendpart` records.
        var files: [SyncSendFile] = []
        /// Files named in a way an iPhone never writes: failed, not dropped.
        var invalidFiles = false
        /// The model and effort picked on the iPhone (ModelPick).
        var model: String? = nil
        var effort: String? = nil
    }

    static let filesUnreadable = "Yab couldn't read the attached files. Send them again."
    static let filesBroken = "A file didn't arrive whole. Send it again."
    static let filesUnsaved = "Yab couldn't save the attached files on this Mac."

    /// Where a send's files are kept: a folder of its own, under Yab's.
    static var inbox: URL { Store.file("agent/inbox") }

    /// Words whose files' parts aren't all here yet: left waiting, to be
    /// taken when the last part comes, unless the send is already past its
    /// 12 hours (then it is taken, to be marked expired).
    static func awaitingParts(_ record: SyncKit.Record, device: String, now: Date = Date(),
                              part: (String) -> SyncKit.Record?) -> Bool {
        guard let words = waiting([record], device: device).first, !words.files.isEmpty, !words.invalidFiles,
              now.timeIntervalSince(words.at) <= ChatCommand.lifetime else { return false }
        return !words.files.allSatisfy { $0.arrived(part) }
    }

    /// The send's files put together, checked and written in its folder
    /// under `folder`, or why they couldn't be.
    static func gather(_ words: Words, into folder: URL = inbox,
                       part: (String) -> SyncKit.Record?) -> (files: [URL], reason: String?) {
        guard !words.invalidFiles else { return ([], filesUnreadable) }
        guard !words.files.isEmpty else { return ([], nil) }
        var bytes: [(SyncSendFile, Data)] = []
        for file in words.files {
            guard case .data(let data) = file.assembled(part) else { return ([], filesBroken) }
            bytes.append((file, data))
        }
        let manager = FileManager.default
        let room = folder.appendingPathComponent(safe(words.id), isDirectory: true)
        do {
            try manager.createDirectory(at: room, withIntermediateDirectories: true)
            var urls: [URL] = []
            for (file, data) in bytes {
                let url = unique(safe(file.name), in: room, taken: Set(urls.map(\.lastPathComponent)))
                try data.write(to: url, options: .withoutOverwriting)
                urls.append(url)
            }
            return (urls, nil)
        } catch {
            NSLog("sync: a send's files were not saved: %@", String(describing: error))
            return ([], filesUnsaved)
        }
    }

    /// A name that stays one name in a folder: no slashes, no leading dot.
    static func safe(_ name: String) -> String {
        var out = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasPrefix(".") { out.removeFirst() }
        return out.isEmpty ? "file" : String(out.prefix(200))
    }

    /// `name`, or "name 2.ext", "name 3.ext"… when it is there already.
    static func unique(_ name: String, in folder: URL, taken: Set<String> = []) -> URL {
        let manager = FileManager.default
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = name, n = 1
        while taken.contains(candidate) || manager.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            n += 1
            candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
        }
        return folder.appendingPathComponent(candidate)
    }

    /// A requested provider cannot silently use the default or affect an existing chat.
    static func startAgent(_ words: Words, start: (String, String?, Bool) -> String) -> (reason: String?, made: String?) {
        guard !words.invalidAgent, words.kind == "agent", words.chat == nil,
              words.choice == nil, !words.invalidChoice else { return (ChatAgent.invalid, nil) }
        if let cli = words.cli, ChatAgent(rawValue: cli) == nil { return (ChatAgent.invalid, nil) }
        return (nil, id(agent: start(words.text, words.cli, words.cli != nil)))
    }

    /// Stop or Delete from the iPhone, as the Mac's own menu does them: a
    /// chat still working isn't deleted (stop it first), and a task from
    /// the iPhone is its task record's, not a chat's.
    @MainActor
    static func control(_ action: SyncSend.Action, chat: String?, text: String) -> (reason: String?, made: String?) {
        guard text.isEmpty, let chat, chat.hasPrefix("a:") else { return ("Yab doesn’t know that kind of request.", nil) }
        let id = String(chat.dropFirst(2))
        let agents = Agents.shared
        guard Chats.shared.chat(id) != nil || agents.session(id) != nil else { return ("That chat isn't on this Mac any more.", nil) }
        guard agents.remoteTaskOrigin(id) == nil else { return (RemoteTaskBoundary.unavailable, nil) }
        let live = agents.session(id)?.state.live == true
        switch action {
        case .stop:
            if live { _ = agents.stop(id) }
        case .delete:
            if live { return ("It's still working. Stop it first.", nil) }
            for browser in BrowserWindows.shared.browsers where browser.chatPinned == id { browser.chatPinned = nil }
            Chats.shared.remove(id)
        }
        return (nil, nil)
    }

    /// The sends waiting for this Mac: addressed to it and not yet taken.
    static func waiting(_ records: [SyncKit.Record], device: String) -> [Words] {
        records.filter { $0.alive() && $0["device"]?.string == device && $0["state"] == nil }.compactMap { record in
            let explicitAgent = record["agentText"]
            let text = explicitAgent?.string ?? record["text"]?.string ?? ""
            let field = record["choice"]
            let choice = SyncChoice.index(field)
            let invalidChoice = (field != nil && choice == nil) || record["answerIndex"] != nil || record["choiceQuestion"] != nil
            let requestedCLI = record["cli"]?.string.flatMap(ChatAgent.init(rawValue:))
            // Files are something to say on their own, words or none.
            let files = SyncSendFile.read(record["files"], send: record.id)
            let hasFiles = record["files"]?.array?.isEmpty == false
            let invalidAgent = record["cli"] != nil && requestedCLI == nil
                || (record["cli"] != nil && explicitAgent == nil)
                || (explicitAgent != nil && (requestedCLI == nil || explicitAgent?.string == nil || (text.isEmpty && !hasFiles)
                    || record["text"] != nil || record["chat"] != nil || field != nil
                    || (record["project"] != nil && !ChatProjects.valid(record["project"]?.string))
                    || record["kind"]?.string != "agent"))
            let action = record["action"]?.string.flatMap(SyncSend.Action.init(rawValue:))
            guard !text.isEmpty || choice != nil || invalidChoice || invalidAgent || action != nil || hasFiles else { return nil }
            return Words(id: record.id, chat: record["chat"]?.string, text: text, kind: record["kind"]?.string ?? "agent",
                         project: record["project"]?.string, choice: choice,
                         at: Date(timeIntervalSince1970: record["at"]?.number ?? Date().timeIntervalSince1970), invalidChoice: invalidChoice,
                         cli: record["cli"]?.string,
                         invalidAgent: invalidAgent, action: action, files: files ?? [], invalidFiles: files == nil,
                         model: record["model"]?.string, effort: record["effort"]?.string)
        }.sorted { $0.at < $1.at }
    }
}

// MARK: - The Mac's side

extension SyncCenter {
    /// Called by the receive path after records have merged in the journal.
    func adoptChats(_ records: [SyncKit.Record]) {
        SyncChats.adopt(records, device: Self.deviceID, chats: Chats.shared)
    }

    /// Every chat of this Mac that syncs, as heads; the steps of those that
    /// changed since the last time.
    func flushChats() throws {
        guard let journal else { return }
        let device = Self.deviceID
        // What this Mac takes from another device, so an iPhone offers it.
        try journal.change(.init(collection: OpenOnMac.capability, id: device),
                           SyncChats.capability(device: device, atLogin: OpenAtLogin.shared.on,
                                                taskEpoch: taskReader == nil ? nil : SyncCenter.taskEpoch,
                                                models: SyncChats.offered()))
        guard syncs(.chats) else { return }
        let since = Date().addingTimeInterval(-SyncChats.days)
        var heads: [String: [String: Value]] = [:]
        var changed: [String: Chat] = [:]
        // When each changed chat last moved, as it is compared next time.
        var moves: [String: Date] = [:]

        // A chat with Gmail's data in it stays on this Mac (Chat.withMail);
        // one sent before mail went into it is taken back with the rest. A
        // task from the iPhone goes back as its task record (SyncTasks),
        // not as a chat that would take words it can't.
        for chat in Chats.shared.all where (chat.updated > since || chat.pinned || chat.archived == true) && !chat.withMail
            && chat.remoteTask == nil {
            let id = SyncChats.id(agent: chat.id)
            heads[id] = SyncChats.head(chat, kind: "agent", device: device)
            if chatsSent[id] != chat.updated { changed[id] = chat; moves[id] = chat.updated }
        }
        // Only this Mac's chats are this Mac's to remove.
        try journal.reconcile(SyncChats.chat, heads, within: { $0.fields["device"]?.string == device })
        var items: [String: [String: Value]] = [:]
        for (id, chat) in changed { items.merge(SyncChats.items(chat, record: id)) { a, _ in a } }
        let gone = Set(chatsSent.keys).subtracting(heads.keys)
        let touched = Set(changed.keys).union(gone)
        if !touched.isEmpty {
            // A step's id begins with its chat's (`items`): only the steps
            // of the chats that moved are read, not every chat's. A step
            // that goes takes its words with it (blank): the account's
            // 50 MB once filled with removed steps and stopped all sync.
            try journal.reconcile(SyncChats.item, items, within: { touched.contains($0.fields["chat"]?.string ?? "") },
                                  under: Set(touched.map { $0 + "/" }), blank: true)
        }
        for (id, moved) in moves { chatsSent[id] = moved }
        for id in gone { chatsSent[id] = nil }
    }

    /// Words from another device for this Mac's chats, said in them now.
    func takeSends() {
        guard let journal else { return }
        takeOpenRequests()
        guard let client, client.journal === journal, state == .live else { return }
        let account = client.seal.account
        let device = Self.deviceID
        // A file's parts, as the iPhone wrote them; never written or removed here.
        let part: (String) -> SyncKit.Record? = { journal.record(.init(collection: SyncChats.part, id: $0)) }
        for record in journal.all(SyncChats.send) {
            // Its files not all here yet: taken once their last part comes.
            if SyncChats.awaitingParts(record, device: device, part: part) { continue }
            do {
                try ChatCommand.consume(record, in: journal, account: account, device: device) { request in
                    guard let words = SyncChats.waiting([request], device: device).first else { return .failed(ChatCommand.invalid) }
                    let gathered = SyncChats.gather(words, part: part)
                    if let reason = gathered.reason { return .failed(reason) }
                    let result = say(words, files: gathered.files)
                    if let reason = result.reason {
                        if let room = gathered.files.first?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: room) }
                        return .failed(reason)
                    }
                    return .taken(chat: result.made)
                }
            } catch Journal.ChatRefusal.missingReceipt {
                // An unclaimed remote processing record cannot execute or block
                // independent requests. Leave its claimed outcome untouched.
                continue
            } catch {
                // Keep the consumed receipt. A later pass reports interruption
                // instead of repeating an effect whose final write failed.
                NSLog("sync: chat receipt did not reach a safe terminal state")
                break
            }
        }
        client.kick()
    }

    /// Why it couldn't be said, if it couldn't; the chat it started, for
    /// words that start one. `files`: the send's files, saved on this Mac
    /// (SyncChats.gather), attached as the Mac's own field attaches one.
    func say(_ words: SyncChats.Words, files: [URL] = []) -> (reason: String?, made: String?) {
        guard !words.invalidChoice else { return (SyncChoice.invalidReason, nil) }
        guard !words.invalidFiles else { return (SyncChats.filesUnreadable, nil) }
        // Files named but not handed over can't be said without them.
        guard files.count == words.files.count else { return (SyncChats.filesBroken, nil) }
        guard !words.invalidAgent, words.cli == nil || (words.kind == "agent" && words.chat == nil && words.choice == nil) else {
            return (ChatAgent.invalid, nil)
        }
        guard words.kind == "agent" else {
            return ("Yab doesn’t know that kind of request.", nil)
        }
        if words.choice != nil { return (SyncChoice.targetReason, nil) }
        let agents = Agents.shared
        if let action = words.action {
            guard files.isEmpty else { return ("Yab doesn’t know that kind of request.", nil) }
            return SyncChats.control(action, chat: words.chat, text: words.text)
        }
        let attached = files.map(ChatAttachment.file)
        if let chat = words.chat {
            if chat.hasPrefix("a:") {
                let id = String(chat.dropFirst(2))
                guard Chats.shared.chat(id) != nil || agents.session(id) != nil else { return ("That chat isn't on this Mac any more.", nil) }
                // A task from the iPhone takes no more words.
                guard agents.remoteTaskOrigin(id) == nil else { return (RemoteTaskBoundary.unavailable, nil) }
                // A model picked there: the chat goes on on it, as when it
                // is picked in its column (ChatModelLine.pick); one this
                // Mac lacks leaves the chat on its own.
                if words.model != nil || words.effort != nil, let session = agents.session(id) ?? agents.revive(id) {
                    let fitted = SyncChats.fit(cli: session.cli, model: words.model, effort: words.effort, among: SyncChats.every())
                    if fitted.model != nil || fitted.effort != nil {
                        if let model = fitted.model { session.model = model }
                        if let effort = fitted.effort { session.effort = effort }
                        Chats.shared.keep(agents.chat(of: session))
                        agents.objectWillChange.send()
                    }
                }
                // Asked to pick: a pick or words of its own answer it, as
                // the Mac's field does (ChatComposer), never a follow-up.
                if let asking = agents.pick(for: id), !words.text.isEmpty, attached.isEmpty {
                    agents.choose(asking, words.text)
                    return (nil, nil)
                }
                agents.followUp(id, words.text, with: attached)
                return (nil, nil)
            }
            return ("Yab doesn't know that kind of chat.", nil)
        }
        // A model picked there, if this Mac has it; it picks the agent too
        // when none was named.
        var fitted: (cli: String?, model: String?, effort: String?) = (words.cli, nil, nil)
        if words.model != nil || words.effort != nil {
            // An effort alone is for the agent a new chat starts on by default.
            let agent = words.cli ?? (words.model == nil ? ModelDefaults.shared.pick(.tasks).cli : nil)
            fitted = SyncChats.fit(cli: agent, model: words.model, effort: words.effort, among: SyncChats.every())
        }
        // A new chat in a project: one this Mac has.
        if let project = words.project {
            guard words.chat == nil, Projects.shared.project(project) != nil else { return (ChatProjects.missing, nil) }
        }
        return SyncChats.startAgent(words) { text, cli, strict in
            // Files are said in the prompt; the chat shows only your words,
            // the files named over them (ChatComposer.begin).
            let said = files.isEmpty ? "" : ChatAttachment.said(tabs: [], files: files)
            let prompt = [text, said].filter { !$0.isEmpty }.joined(separator: "\n\n")
            let session = agents.run(prompt: prompt, cli: cli ?? fitted.cli, model: fitted.model, effort: fitted.effort,
                                     access: "browser", resume: nil, strict: strict, project: words.project)
            // Its chat goes back to the phone: no mail in it (docs/casa.md, Sync).
            session.fromPhone = true
            if !files.isEmpty {
                session.saying.append(text)
                session.carrying.append(ChatAttachment.labels(tabs: [], files: files))
                session.attaching.append(files.map(ChatAttachment.file))
                if text.isEmpty { session.title = files.map(\.lastPathComponent).joined(separator: ", ") }
            }
            return session.id
        }
    }
}
