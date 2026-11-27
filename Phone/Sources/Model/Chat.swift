import Foundation
import SyncKit

/// A chat with the agent: the same list as on the Mac. A task is a chat too.
/// Chats are never deleted, only archived, and found again by search.
struct Chat: Identifiable, Codable, Hashable, Sendable {
    typealias ID = String

    var id: ID
    var title: String
    var pinned: Bool
    var unread: Bool
    var archived: Bool
    /// Where it sorts in Your Chats: Pinned first, then Today, Yesterday, Earlier.
    var day: DateBucket
    /// What the row says for when: "18:31", "Mon", "Aug 14".
    var time: String
    /// Who answers it: Claude on the Mac, or the model on this iPhone.
    var by: Answerer
    /// Accepted send/head metadata, never a guess from the current preference.
    var macCLI: String?

    var macAgentName: String? {
        switch macCLI {
        case "claude": "Claude"
        case "codex": "ChatGPT"
        case "cursor": "Cursor"
        case "gemini": "Gemini"
        case "opencode": "OpenCode"
        default: nil
        }
    }
    /// A task's chat: its words come from the task's run.
    var task: TaskRun.ID?
    /// Worked like a task (a list checked on many sites) though asked as a question.
    var taskLike: Bool
    var messages: [Message]
    /// Who began it on the Mac when not the person: "agent" (an outside
    /// agent's task), "routine" or "cli" (SyncChat.Origin); nil, the person.
    var origin: String?
    /// The routine whose run it is: one row per routine.
    var routine: String?
    /// The project it is in (ChatProject's id, `prj-…`), nil for a chat on its own.
    var project: String?
    /// The person's own: not a task an agent, a routine or a command began.
    var isYours: Bool { origin == nil }
    /// Still answering on the Mac.
    var working: Bool { messages.last?.role == .typing }
    /// What its agent on the Mac waits for you to pick from now, its
    /// question its last message: a card over the field, as on the Mac
    /// (SyncChat.choices). Not encoded: it is the Mac's, read as it syncs.
    var choices: [String] = []
    /// A quick answer never continued, or a new chat nothing was asked in:
    /// not in Your Chats, its count or search, and letting it go leaves
    /// nothing. Not encoded: it lives only on this iPhone until it is kept.
    var ephemeral = false

    enum DateBucket: String, Codable, CaseIterable, Sendable {
        case today, yesterday, earlier
    }

    enum Answerer: String, Codable, Sendable {
        /// Claude, on the Mac.
        case claude
        /// Apple Intelligence, on this iPhone.
        case iphone
    }

    init(id: ID, title: String, pinned: Bool = false, unread: Bool = false, archived: Bool = false, day: DateBucket = .today,
         time: String = "", by: Answerer = .claude, macCLI: String? = nil, task: TaskRun.ID? = nil, taskLike: Bool = false, messages: [Message] = [],
         origin: String? = nil, routine: String? = nil, project: String? = nil) {
        self.id = id
        self.title = title
        self.pinned = pinned
        self.unread = unread
        self.archived = archived
        self.day = day
        self.time = time
        self.by = by
        self.macCLI = macCLI
        self.task = task
        self.taskLike = taskLike
        self.messages = messages
        self.origin = origin
        self.routine = routine
        self.project = project
    }

    enum CodingKeys: String, CodingKey { case id, title, pinned, unread, archived, day, time, by, macCLI, task, taskLike, messages, origin, routine, project }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        day = try c.decodeIfPresent(DateBucket.self, forKey: .day) ?? .today
        time = try c.decodeIfPresent(String.self, forKey: .time) ?? ""
        by = try c.decodeIfPresent(Answerer.self, forKey: .by) ?? .claude
        macCLI = try c.decodeIfPresent(String.self, forKey: .macCLI)
        task = try c.decodeIfPresent(TaskRun.ID.self, forKey: .task)
        taskLike = try c.decodeIfPresent(Bool.self, forKey: .taskLike) ?? false
        messages = try c.decodeIfPresent([Message].self, forKey: .messages) ?? []
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        routine = try c.decodeIfPresent(String.self, forKey: .routine)
        project = try c.decodeIfPresent(String.self, forKey: .project)
    }

    /// The last answer, for the row's second line and a held chat's preview.
    var lastAnswer: Message? { messages.last { $0.role == .answer || $0.role == .pick } }
}

/// One turn of a chat.
struct Message: Codable, Hashable, Sendable {
    enum Role: String, Codable, Sendable {
        /// What the person wrote.
        case you
        /// The answer; `text` may carry <b>bold</b>.
        case answer
        /// A pick from a list checked on many sites.
        case pick
        /// A quiet line in the chat.
        case note
        /// Claude is answering.
        case typing
        /// Waits for the Mac, asleep.
        case wait
        /// The question before it wasn't sent; `text` says why. Shown as
        /// Messages' Not Delivered: a red ! by the bubble, Not Sent under it.
        case failed
        /// What a turn did on the Mac with no answer to stand under: its
        /// thoughts, its subagents, a turn stopped or failed (TurnWork).
        case work
    }

    var role: Role
    var text: String
    /// Who answered, for answers.
    var by: Chat.Answerer?
    var pick: Pick?
    /// What its turn did on the Mac: under an answer, its line of actions;
    /// on a `.work` message, the rest (TurnWork).
    var work: TurnWork?
    /// Photos and files sent with your words (ChatAttachments).
    var files: [File] = []
    /// A row of Now handed to the agent on the Mac (Do It), over your
    /// "Do It": the same card the Mac's chat shows (HandedCard).
    var handed: Handed?
    /// Your words waiting for a Mac that is down, and the wait row under
    /// them (docs/mac-asleep-status.md): the send to take back, another Mac
    /// that is up, or a send that expired.
    var mac: MacWait?
    /// What its turn made on the Mac, a card each under the answer: pages
    /// found, a comparison, an event, a reminder, a watch, a routine, a
    /// folder (ResultCard, ResultCardsView).
    var cards: [ResultCard] = []

    init(role: Role, text: String = "", by: Chat.Answerer? = nil, pick: Pick? = nil,
         work: TurnWork? = nil, files: [File] = [], handed: Handed? = nil, mac: MacWait? = nil, cards: [ResultCard] = []) {
        self.role = role
        self.text = text
        self.by = by
        self.pick = pick
        self.work = work
        self.files = files
        self.handed = handed
        self.mac = mac
        self.cards = cards
    }

    enum CodingKeys: String, CodingKey { case role, text, by, pick, work, files, handed, mac, cards }

    struct MacWait: Codable, Hashable, Sendable {
        /// The waiting send: Don't Send and Ask on another Mac take it back.
        var send: String?
        /// A Mac that is up and runs the chat's agent, for "Ask on Mac mini".
        var offerID: String?
        var offerName: String?
        /// The send expired before its Mac took it: Send Again.
        var expired = false
        /// Its Mac's name, for the expired row.
        var name: String?
    }

    /// The row handed over: its site, its words, the gray line under them
    /// and where it came from (SyncHanded on the Mac).
    struct Handed: Codable, Hashable, Sendable {
        var host: String
        var title: String
        var detail: String
        var from: String
    }

    /// A photo or file sent with words: what the send said of it; its
    /// picture, for a photo, is kept here by its digest.
    struct File: Codable, Hashable, Sendable {
        var name: String
        var type: String
        var size: Int
        var digest: String
        var isImage: Bool { type.hasPrefix("image/") }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        by = try c.decodeIfPresent(Chat.Answerer.self, forKey: .by)
        pick = try c.decodeIfPresent(Pick.self, forKey: .pick)
        work = try c.decodeIfPresent(TurnWork.self, forKey: .work)
        files = try c.decodeIfPresent([File].self, forKey: .files) ?? []
        handed = try c.decodeIfPresent(Handed.self, forKey: .handed)
        mac = try c.decodeIfPresent(MacWait.self, forKey: .mac)
        cards = try c.decodeIfPresent([ResultCard].self, forKey: .cards) ?? []
    }

    /// The text without its markup.
    var plain: String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    /// The best of a list: its head, why, the rows and what was skipped.
    struct Pick: Codable, Hashable, Sendable {
        var head: String
        var why: String
        var rows: [[String]]
        var foot: String
    }

}
