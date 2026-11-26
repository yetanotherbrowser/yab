import Foundation
import SQLite3

// One mail account on this Mac (docs/mail.md, The engine): Gmail's threads
// and messages as the last sync left them, the bodies fetched so far, what
// you did that Gmail hasn't heard yet, and a word index to search it all.
//
// A cache of Gmail with a few columns of our own. A file of an older shape
// is brought up to date in place by the migrations below, never synced
// again for it: a mailbox takes minutes of Gmail's quota to come back, and
// drafts, snoozes and the journal are the person's work. Only a change of
// `reset` empties what came from Gmail, and even then those stay. One
// serial queue owns the file; every call waits on it and answers, which is
// right for the sync and the ops, both off the main thread. The page reads
// through the same calls from a queue of its own.

/// A person as a mail header names them: "Anna Lindqvist <anna@fold.studio>".
public struct MailPerson: Equatable, Hashable {
    public var name: String
    public var address: String

    /// Every person in a header, in order.
    public static func list(_ header: String) -> [MailPerson] {
        var out: [MailPerson] = []
        var current = ""
        var quoted = false, angled = false
        for char in header {
            if char == "\"" { quoted.toggle() }
            if char == "<" { angled = true }
            if char == ">" { angled = false }
            if char == ",", !quoted, !angled {
                if let one = one(current) { out.append(one) }
                current = ""
            } else {
                current.append(char)
            }
        }
        if let one = one(current) { out.append(one) }
        return out
    }

    public static func one(_ text: String) -> MailPerson? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            let address = String(text[text.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            let name = String(text[..<open]).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            return MailPerson(name: name, address: address.lowercased())
        }
        return MailPerson(name: "", address: text.lowercased())
    }

    /// As a list shows them: the name, or the address when there is none.
    public var said: String { name.isEmpty ? address : name }

    public var header: String { name.isEmpty ? address : "\"\(name)\" <\(address)>" }

    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }
}

/// One message as the store keeps it.
public struct MailMessage: Equatable {
    public var id: String
    public var thread: String
    public var from: MailPerson
    public var to: [MailPerson] = []
    public var cc: [MailPerson] = []
    public var subject = ""
    public var snippet = ""
    public var date: Date
    public var labels: Set<String> = []
    /// Its Message-ID, and what it answers: a reply needs both.
    public var rfcID = ""
    public var inReplyTo = ""
    public var references = ""
    public var listUnsubscribe = false
    /// Who a reply goes to when it isn't the sender: none for most mail,
    /// nil when not known yet (kept before the store had it, MailStore.late).
    public var replyTo: [MailPerson]?
    /// List-Unsubscribe and List-Unsubscribe-Post as the list sent them, for
    /// ⌘U (MailUnsubscribe): "" when it has none, nil when not known yet.
    /// Mail without List-Unsubscribe is known to have neither.
    public var unsubscribe: String?
    var unsubscribePost: String?
    /// Its words, once the body is fetched; nil until then.
    public var text: String?
    public var html: String?
    /// Its files, as its parts said when it came whole (MailFile); nil
    /// while they aren't known: mail kept by its headers, or kept before
    /// the store kept files.
    public var files: [MailFile]? = nil
    /// It carries files of its own, beside any picture its words draw:
    /// known from its parts, or from Gmail's search (has:attachment) for
    /// mail kept by its headers; nil, not known.
    public var attached: Bool? = nil
    /// The invitation it carries, an iCalendar object as it came (a
    /// text/calendar part, RFC 6047): from its parts when they held its
    /// words, else once fetched as a file (MailInvites); nil for none, or
    /// not read yet.
    public var calendar: String? = nil

    public init(id: String, thread: String, from: MailPerson, to: [MailPerson] = [], cc: [MailPerson] = [], subject: String = "", snippet: String = "", date: Date, labels: Set<String> = [], rfcID: String = "", inReplyTo: String = "", references: String = "", listUnsubscribe: Bool = false, replyTo: [MailPerson]? = nil, unsubscribe: String? = nil, unsubscribePost: String? = nil, text: String? = nil, html: String? = nil, files: [MailFile]? = nil, attached: Bool? = nil, calendar: String? = nil) {
        self.id = id
        self.thread = thread
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.snippet = snippet
        self.date = date
        self.labels = labels
        self.rfcID = rfcID
        self.inReplyTo = inReplyTo
        self.references = references
        self.listUnsubscribe = listUnsubscribe
        self.replyTo = replyTo
        self.unsubscribe = unsubscribe
        self.unsubscribePost = unsubscribePost
        self.text = text
        self.html = html
        self.files = files
        self.attached = attached
        self.calendar = calendar
    }
}

/// A thread as a list shows it.
public struct MailThread: Equatable {
    public var id: String
    public var subject: String
    public var snippet: String
    public var last: Date
    public var labels: Set<String>
    public var unread: Bool
    /// Who wrote in it, newest first, you left out.
    public var people: [MailPerson]
    public var count: Int
    /// The last message is yours.
    public var lastIsMine: Bool
    /// Sent to a list: someone else's message carries List-Unsubscribe.
    public var bulk = false
    /// You were done waiting on it (E in Waiting) and nothing came in it
    /// since: out of Waiting until a new message does.
    public var doneWaiting = false
    /// Muted (⇧M): in no list of the inbox, and new mail in it is put
    /// away as it comes.
    public var muted = false
    /// Your last mail in it comes back if nobody answers it (⇧⌘H,
    /// MailFollowups): waiting for its time, or come due. Only while your
    /// mail is the last.
    public var followup: MailFollowup?
    /// A date it names for something to be done (MailSense).
    public var due: Date?
    /// A file in it of its own (MailMessage.attached): a clip on its row.
    public var attached = false
    /// Mail of it came by a search of Gmail, older than the sync keeps:
    /// a search's row says Gmail.
    public var backfilled = false

    /// The line a list shows, from what was worked out about it.
    public func with(_ sensed: MailSensed) -> MailThread {
        var out = self
        out.snippet = sensed.gist
        out.due = sensed.due
        return out
    }
}

/// A mail being written: a reply or a forward in a thread, or a new one
/// (thread "").
public struct MailDraft: Equatable {
    public var id = UUID().uuidString
    public var thread = ""
    public var to: [MailPerson] = []
    public var cc: [MailPerson] = []
    /// In the message as it goes out; Gmail takes it off what To and Cc get.
    public var bcc: [MailPerson] = []
    public var subject = ""
    public var body = ""
    public var inReplyTo = ""
    public var references = ""
    /// Set when it is written, so a send that timed out can be looked for
    /// in Sent before it is sent again.
    public var messageID = ""
    /// The mail it answers or forwards, as it goes under the words
    /// ("On …, Anna wrote:" and its lines marked, or the forwarded block):
    /// made when the reply is, so it outlives the mail it came from.
    public var quote = ""
    /// The mail it forwards, by Gmail's id: its files go with it, as chips
    /// that can be taken off (MailAttach).
    public var forwarded = ""
    /// Back if nobody answers it by then (⇧⌘H), and when that was chosen:
    /// a send that goes later keeps the reminder as far from it
    /// (MailFollowups.sent). Nil: no reminder.
    public var remind: Date?
    public var remindSet: Date?
    /// The files it carries, in the order their chips stand (`draft_files`).
    public var files: [MailDraftFile] = []
    /// Its words' HTML when they carry a mark (MailRich): `body` is the same
    /// words as plain text. "" for plain words, which go as text alone.
    public var html = ""
    /// The address it goes from (MailSendAs); "" for the account's default.
    public var from = ""
    /// It carries the signature of the address it goes from: a new mail
    /// always, a reply or a forward as Settings › Mail says.
    public var signed = false

    public init(id: String = UUID().uuidString, thread: String = "", to: [MailPerson] = [], cc: [MailPerson] = [], bcc: [MailPerson] = [], subject: String = "", body: String = "", inReplyTo: String = "", references: String = "", messageID: String = "", quote: String = "", forwarded: String = "", remind: Date? = nil, remindSet: Date? = nil, files: [MailDraftFile] = [], html: String = "", from: String = "", signed: Bool = false) {
        self.id = id
        self.thread = thread
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.inReplyTo = inReplyTo
        self.references = references
        self.messageID = messageID
        self.quote = quote
        self.forwarded = forwarded
        self.remind = remind
        self.remindSet = remindSet
        self.files = files
        self.html = html
        self.from = from
        self.signed = signed
    }
}

/// A label of the mailbox as Gmail lists it (labels.list): the person's own
/// ("Work/Clients") or Gmail's (INBOX, STARRED, CATEGORY_UPDATES), with how
/// many threads carry it and how many of those are unread once labels.get
/// was asked (MailLabels, for the column).
public struct MailLabel: Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// "user", the person's own; "system", Gmail's.
    public var type = "user"
    /// Gmail's colors for it, "#rrggbb"; none when it has none.
    public var color = ""
    public var textColor = ""
    /// Whether Gmail's own list of labels shows it: labelShow,
    /// labelShowIfUnread or labelHide.
    public var shown = "labelShow"
    /// Threads with it unread, and in all, as labels.get last said; nil
    /// before it was asked.
    public var unread: Int?
    public var threads: Int?

    public var user: Bool { type == "user" }

    public init(id: String, name: String, type: String = "user", color: String = "", textColor: String = "", shown: String = "labelShow", unread: Int? = nil, threads: Int? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.color = color
        self.textColor = textColor
        self.shown = shown
        self.unread = unread
        self.threads = threads
    }
}

/// A thread put away until a time, or until someone writes in it again
/// (until nil): either way, a new message from someone else wakes it.
public struct MailSnooze: Equatable {
    public var thread: String
    public var until: Date?
    /// In words, for the Later list: "Tomorrow, 9:00", "Until Anna replies".
    public var why: String
    /// The last message from someone else when it was put away.
    public var message: String
}

/// Your answer to an invitation (MailInvite), kept by the draft whose
/// mail tells the organizer: the event's UID, which occurrence ("" the
/// series) and SEQUENCE it answers, the invitation's message, and the
/// iCalendar REPLY the mail carries.
public struct MailRSVP: Equatable {
    public var draft: String
    public var uid: String
    public var recurrence = ""
    public var sequence = 0
    public var answer: MailInvite.Answer
    public var message = ""
    public var ics = ""
    public var at = Date()

    public init(draft: String, uid: String, recurrence: String = "", sequence: Int = 0, answer: MailInvite.Answer, message: String = "", ics: String = "", at: Date = Date()) {
        self.draft = draft
        self.uid = uid
        self.recurrence = recurrence
        self.sequence = sequence
        self.answer = answer
        self.message = message
        self.ics = ics
        self.at = at
    }
}

/// Something you did that Gmail hasn't heard yet.
public struct MailOp: Equatable {
    public enum Kind: String {
        case archive, unarchive, read, unread, label, unlabel, trash, untrash, star, unstar, spam, unspam, mute, unmute, send
    }
    public var seq: Int64
    public var kind: Kind
    /// The thread it is on (a send: its draft's id), or `pack` for one on
    /// many threads at once.
    public var thread: String
    public var label: String
    public var tries: Int
    public var notBefore: Date
    /// Every thread it is on: its one, or a pack's.
    public var threads: [String] = []

    /// The thread of an op on many (MailOps.bulk): its threads are kept
    /// in the store's `packs`, and Gmail hears it as messages/batchModify.
    public static let pack = "pack:"
    var isPack: Bool { thread == MailOp.pack }

    /// The thread of an op on messages by their ids (MailOps.bulk(messages:)):
    /// a Bulk Actions entry taken back, mail from a blocked sender. Its ids
    /// are kept in `pack_messages`, and Gmail hears it as messages/batchModify.
    static let byMessages = "messages:"
    var onMessages: Bool { thread == MailOp.byMessages }
    /// The messages of an op on messages.
    public var messages: [String] = []
}

public final class MailStore: @unchecked Sendable {
    public let file: URL
    /// The account's own address, to tell its mail from other people's.
    /// Written on the store's queue and read from anywhere (the desk reads
    /// it on the main thread), so behind a lock of its own.
    public private(set) var me: String {
        get { meLock.lock(); defer { meLock.unlock() }; return meKept }
        set { meLock.lock(); meKept = newValue; meLock.unlock() }
    }
    private var meKept = ""
    private let meLock = NSLock()
    private let queue: DispatchQueue
    private var connection: SQLiteConnection?
    private var db: OpaquePointer? { connection?.handle }
    private let migrations: [(Int, String)]
    private let resetting: Int
    /// The drafts table has what migration 10 gives it (Bcc, the quote,
    /// what a forward is of): not while that migration hasn't taken.
    private var draftsWhole = false
    /// And what 13 does: a draft's reminder if nobody answers.
    private var draftsRemind = false
    /// The threads with a reminder if nobody answers, kept beside their
    /// table so a list's rows ask for theirs alone (a look for every row
    /// cost the Needs you list a tenth more); read again with every look
    /// over them (`followups()`), which finds one `yab mail flush` made.
    private var following: Set<String> = []
    /// A draft's files have their table (migration 16): not while that
    /// migration hasn't taken.
    private var draftFilesKept = false
    /// The store keeps `labels` (migration 17), and the ids in it, so mail
    /// carrying a label not known here is found without a look at the table.
    private var labeling = false
    private var labelIDs: Set<String> = []
    /// And its words' HTML, its From and its signature (18), with the
    /// send-as addresses beside them.
    private var draftsRich = false
    /// The send-as list and the signatures written here, as last read or
    /// written: a draft asks for them each time it is drawn.
    private var sendAsKept: [MailSendAs]?
    private var signaturesKept: [String: String]?
    /// The store keeps read statuses (19): the keys mail went with, and
    /// what the site said of them.
    private var readsKept = false
    /// Invitations and the answers to them have theirs (migration 20).
    private var inviting = false

    /// The shape every store starts from: the one Yab 0.0.2 and 0.0.3
    /// shipped, "version" 5 in their meta, which stays there so an older
    /// Yab still reads the file. Anything older is started over.
    public static let base = 5

    /// Every change to the store's shape since the base, in order, each
    /// applied once (`open`): its SQL and its number in `meta` "schema" go
    /// in one transaction, so a migration that fails leaves the store as it
    /// was, at the one before, and is tried again at the next launch.
    /// Only ever add to the end: columns (`ALTER TABLE … ADD COLUMN`, with a
    /// default when NOT NULL), tables and indexes (`IF NOT EXISTS`), data
    /// moved in SQL. A header kept in a column of its own joins `late` too.
    public static let migrations: [(Int, String)] = [
        // The word index keyed by its message's rowid, not by a scan of an
        // unindexed id: putting a message looked through every row before.
        (6, """
        DELETE FROM words;
        INSERT INTO words(rowid, id, subject, sender, body)
          SELECT m.rowid, m.id, m.subject, m.from_name || ' ' || m.from_addr, coalesce(b.text, m.snippet)
          FROM messages m LEFT JOIN bodies b ON b.id = m.id;
        """),
        // Reply-To, not known for the mail kept before (NULL): MailSync asks
        // for those again, slowly.
        (7, """
        ALTER TABLE messages ADD COLUMN reply_to TEXT;
        CREATE INDEX IF NOT EXISTS messages_late ON messages(at) WHERE reply_to IS NULL;
        """),
        // Threads you are done waiting on (E in Waiting), each at its last
        // message then; the person's, so a reset keeps them.
        (8, """
        CREATE TABLE IF NOT EXISTS done_waiting(thread TEXT PRIMARY KEY, message TEXT NOT NULL, at REAL NOT NULL);
        """),
        // Muted threads (⇧M), each at its last message then, the person's;
        // and the threads of an op on many at once (MailOps.bulk), one
        // journal entry for them all.
        (9, """
        CREATE TABLE IF NOT EXISTS muted(thread TEXT PRIMARY KEY, message TEXT NOT NULL, at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS packs(seq INTEGER NOT NULL, thread TEXT NOT NULL, PRIMARY KEY(seq, thread));
        """),
        // A draft's Bcc, the mail it quotes or forwards under its words,
        // and which mail a forward is of (MailDraft).
        (10, """
        ALTER TABLE drafts ADD COLUMN bcc TEXT NOT NULL DEFAULT '';
        ALTER TABLE drafts ADD COLUMN quote TEXT NOT NULL DEFAULT '';
        ALTER TABLE drafts ADD COLUMN forwarded TEXT NOT NULL DEFAULT '';
        """),
        // What a notification said already, each thread by its last mail
        // from someone else (MailNotify); the person's, so a reset keeps it.
        (11, """
        CREATE TABLE IF NOT EXISTS notified(thread TEXT PRIMARY KEY, message TEXT NOT NULL, at REAL NOT NULL);
        """),
        // Files mail carries (MailFile): a row for each part read, where the
        // person last saved it; whether a message carries any (NULL: not
        // known); and whether a body was kept with its parts read (NULL:
        // before files were kept, so its parts are read again when opened).
        (12, """
        ALTER TABLE messages ADD COLUMN attached INTEGER;
        ALTER TABLE bodies ADD COLUMN parts INTEGER;
        CREATE TABLE IF NOT EXISTS files(
          message TEXT NOT NULL, part TEXT NOT NULL, name TEXT NOT NULL, mime TEXT NOT NULL, size INTEGER NOT NULL,
          attachment_id TEXT NOT NULL, content_id TEXT NOT NULL, inline INTEGER NOT NULL, saved_path TEXT,
          PRIMARY KEY(message, part));
        """),
        // A draft's reminder if nobody answers (⇧⌘H) and when it was
        // chosen; the reminders of mail sent, each against your mail (its
        // Message-ID), fired once due; and the nudges written for threads
        // you wait on, against their last mail. All the person's.
        (13, """
        ALTER TABLE drafts ADD COLUMN remind REAL;
        ALTER TABLE drafts ADD COLUMN remind_set REAL;
        CREATE TABLE IF NOT EXISTS followups(thread TEXT PRIMARY KEY, message TEXT NOT NULL, until REAL NOT NULL,
          sent REAL NOT NULL, fired REAL, at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS nudges(thread TEXT PRIMARY KEY, message TEXT NOT NULL, body TEXT NOT NULL, at REAL NOT NULL);
        """),
        // Each thread as the lists sort it, kept as its messages change
        // (`tally`), so a split of the whole inbox reads in one pass, a page
        // at a time; mail a search brought from Gmail (`backfilled`, when);
        // threads opened, whose bodies stay (`prune`).
        (14, """
        CREATE TABLE IF NOT EXISTS threads(
          id TEXT PRIMARY KEY, last REAL NOT NULL, last_id TEXT NOT NULL, last_from TEXT NOT NULL, count INTEGER NOT NULL,
          inbox INTEGER NOT NULL, sent INTEGER NOT NULL, unread INTEGER NOT NULL, starred INTEGER NOT NULL, bulk INTEGER NOT NULL,
          category INTEGER NOT NULL, gone INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS threads_last ON threads(last);
        DELETE FROM threads;
        INSERT INTO threads(id, last, last_id, last_from, count, inbox, sent, unread, starred, bulk, category, gone)
          SELECT thread, max(at), id, from_addr, count(*), \(MailStore.tallies("lower(coalesce((SELECT v FROM meta WHERE k = 'me'), ''))"))
          FROM messages GROUP BY thread;
        ALTER TABLE messages ADD COLUMN backfilled REAL;
        CREATE INDEX IF NOT EXISTS messages_backfilled ON messages(thread) WHERE backfilled IS NOT NULL;
        CREATE TABLE IF NOT EXISTS opened(thread TEXT PRIMARY KEY, at REAL NOT NULL);
        """),
        // Cleanup (⌘U, Block Sender, Get Me To Zero): List-Unsubscribe and
        // its -Post as sent, not known yet for a list's mail kept before
        // (NULL, asked again by MailSync) and known to be none for the rest;
        // senders blocked and lists left, the person's; the Bulk Actions log
        // with the messages each entry moved; and the messages of an op on
        // messages by their ids.
        (15, """
        ALTER TABLE messages ADD COLUMN unsubscribe TEXT;
        ALTER TABLE messages ADD COLUMN unsubscribe_post TEXT;
        UPDATE messages SET unsubscribe = '', unsubscribe_post = '' WHERE bulk = 0;
        CREATE INDEX IF NOT EXISTS messages_late_unsubscribe ON messages(at) WHERE unsubscribe IS NULL;
        CREATE TABLE IF NOT EXISTS blocked(who TEXT PRIMARY KEY, at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS unsubscribed(sender TEXT PRIMARY KEY, how TEXT NOT NULL, at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS bulk(id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, said TEXT NOT NULL,
          threads INTEGER NOT NULL, at REAL NOT NULL, back REAL);
        CREATE TABLE IF NOT EXISTS bulk_messages(bulk INTEGER NOT NULL, message TEXT NOT NULL, thread TEXT NOT NULL,
          inbox INTEGER NOT NULL, PRIMARY KEY(bulk, message));
        CREATE TABLE IF NOT EXISTS pack_messages(seq INTEGER NOT NULL, message TEXT NOT NULL, PRIMARY KEY(seq, message));
        """),
        // The files a draft carries, in their chips' order: each one attached
        // here, its copy beside the store (MailAttach), or one of another
        // mail's by that mail's id and part. The person's, so a reset keeps them.
        (16, """
        CREATE TABLE IF NOT EXISTS draft_files(
          draft TEXT NOT NULL, id TEXT NOT NULL, n INTEGER NOT NULL, name TEXT NOT NULL, mime TEXT NOT NULL,
          size INTEGER NOT NULL, message TEXT NOT NULL, part TEXT NOT NULL, PRIMARY KEY(draft, id));
        """),
        // The mailbox's labels as Gmail lists them (MailLabel), with their
        // counts once asked; the names a search learned before (meta
        // label:<name>) come in with them.
        (17, """
        CREATE TABLE IF NOT EXISTS labels(
          id TEXT PRIMARY KEY, name TEXT NOT NULL, type TEXT NOT NULL, color TEXT NOT NULL DEFAULT '',
          text_color TEXT NOT NULL DEFAULT '', shown TEXT NOT NULL DEFAULT 'labelShow', unread INTEGER, threads INTEGER, counted REAL);
        INSERT OR IGNORE INTO labels(id, name, type)
          SELECT v, substr(k, 7), 'user' FROM meta WHERE k LIKE 'label:%' AND v LIKE 'Label\\_%' ESCAPE '\\';
        """),
        // The addresses the account sends as, as Gmail last said them
        // (MailSendAs), and the signatures written here for them, the
        // person's; a draft's words' HTML, the address it goes from, and
        // whether it is signed.
        (18, """
        CREATE TABLE IF NOT EXISTS send_as(
          address TEXT PRIMARY KEY, name TEXT NOT NULL, reply_to TEXT NOT NULL, signature TEXT NOT NULL,
          is_primary INTEGER NOT NULL, is_default INTEGER NOT NULL, n INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS signatures(address TEXT PRIMARY KEY, html TEXT NOT NULL, at REAL NOT NULL);
        ALTER TABLE drafts ADD COLUMN html TEXT NOT NULL DEFAULT '';
        ALTER TABLE drafts ADD COLUMN sender TEXT NOT NULL DEFAULT '';
        ALTER TABLE drafts ADD COLUMN signed INTEGER NOT NULL DEFAULT 0;
        """),
        // Read statuses (MailReads): the key each mail of yours sent with
        // them went with, by its Message-ID, its thread once Gmail named it
        // and when it went; and each time the site said it was opened. The
        // person's, so a reset keeps them.
        (19, """
        CREATE TABLE IF NOT EXISTS reads(message TEXT PRIMARY KEY, key TEXT NOT NULL, sent_at REAL NOT NULL, thread TEXT NOT NULL DEFAULT '');
        CREATE INDEX IF NOT EXISTS reads_thread ON reads(thread);
        CREATE INDEX IF NOT EXISTS reads_sent ON reads(sent_at);
        CREATE INDEX IF NOT EXISTS reads_key ON reads(key);
        CREATE TABLE IF NOT EXISTS read_opens(message TEXT NOT NULL, at REAL NOT NULL, kind TEXT NOT NULL, PRIMARY KEY(message, at, kind));
        """),
        // Invitations mail carries (MailInvite), each message's iCalendar
        // object as it came, by its UID and SEQUENCE: what came from Gmail,
        // so a reset lets them go. And your answers to them (RSVP), each by
        // the draft whose mail carries it to the organizer: the person's.
        (20, """
        CREATE TABLE IF NOT EXISTS invites(message TEXT PRIMARY KEY, thread TEXT NOT NULL, uid TEXT NOT NULL,
          sequence INTEGER NOT NULL, method TEXT NOT NULL, ics TEXT NOT NULL, at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS invites_uid ON invites(uid);
        CREATE TABLE IF NOT EXISTS rsvps(draft TEXT PRIMARY KEY, uid TEXT NOT NULL, recurrence TEXT NOT NULL,
          sequence INTEGER NOT NULL, answer TEXT NOT NULL, message TEXT NOT NULL, ics TEXT NOT NULL, at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS rsvps_uid ON rsvps(uid);
        """),
        // Splits (MailSplits): each thread's senders but you ("|a@x|b@y|"),
        // so a split of people and domains sorts the whole inbox in the one
        // pass that reads it (`facts`); and what Skip the inbox archived as
        // it came, each thread against the mail it came with, its split and
        // when, and when it was taken back. The person's, so a reset keeps it.
        (21, """
        ALTER TABLE threads ADD COLUMN people TEXT NOT NULL DEFAULT '';
        UPDATE threads SET people = coalesce((SELECT '|' || replace(group_concat(DISTINCT m.from_addr), ',', '|') || '|' FROM messages m
          WHERE m.thread = threads.id AND m.from_addr != lower(coalesce((SELECT v FROM meta WHERE k = 'me'), ''))), '');
        INSERT OR REPLACE INTO meta(k, v) SELECT 'peopled', v FROM meta WHERE k = 'synced';
        CREATE TABLE IF NOT EXISTS skipped(thread TEXT PRIMARY KEY, message TEXT NOT NULL, split TEXT NOT NULL, at REAL NOT NULL, back REAL);
        CREATE INDEX IF NOT EXISTS skipped_at ON skipped(at);
        """),
        // Promised (MailPromise): what you promised in your own mail, each
        // against the mail that said it and its place in it, and whether it
        // is open, kept, moved by a later one or a judgment call. The
        // person's, so a reset keeps it (E on one is theirs).
        (22, """
        CREATE TABLE IF NOT EXISTS promises(message TEXT NOT NULL, n INTEGER NOT NULL, thread TEXT NOT NULL, quote TEXT NOT NULL,
          person TEXT NOT NULL, address TEXT NOT NULL, kind TEXT NOT NULL, due REAL, at REAL NOT NULL, state TEXT NOT NULL,
          PRIMARY KEY(message, n));
        CREATE INDEX IF NOT EXISTS promises_thread ON promises(thread);
        CREATE INDEX IF NOT EXISTS promises_state ON promises(state);
        """),
        // What you did by hand, for the offers it leads to (MailOffers): an
        // archive or a label, on which thread, when, and when that thread's
        // last mail had come. Two months kept.
        (23, """
        CREATE TABLE IF NOT EXISTS acts(kind TEXT NOT NULL, thread TEXT NOT NULL, label TEXT NOT NULL, at REAL NOT NULL, came REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS acts_at ON acts(at);
        """),
        // Promises (MailPromise) both ways: what people promised you in
        // their mail beside what you promised in yours, and how its day was
        // said: a span ("this week") or a time of day ("by 11:30").
        (24, """
        ALTER TABLE promises ADD COLUMN theirs INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE promises ADD COLUMN soft INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE promises ADD COLUMN timed INTEGER NOT NULL DEFAULT 0;
        """),
        (25, """
        CREATE TABLE IF NOT EXISTS codes(thread TEXT NOT NULL, message TEXT PRIMARY KEY, code TEXT NOT NULL,
          shown TEXT NOT NULL, purpose TEXT NOT NULL, amount TEXT, merchant TEXT, card TEXT, expires REAL,
          at REAL NOT NULL, used REAL, sure INTEGER NOT NULL DEFAULT 0, site TEXT);
        CREATE INDEX IF NOT EXISTS codes_thread ON codes(thread, at);
        CREATE INDEX IF NOT EXISTS codes_at ON codes(at);
        """),
    ]

    /// Raised only when what came from Gmail can't be trusted any more and
    /// has to come again from nothing (a header read wrongly for months, a
    /// body kept cut short). Mail, bodies and words go; drafts, snoozes,
    /// the journal, the account and what was worked out about threads stay.
    public static let reset = 1

    /// Headers kept in a column of their own after the base: NULL ("not
    /// known yet") for mail kept before the column came, "" when the mail
    /// has none. MailSync asks Gmail for those again, newest first, with a
    /// tenth of the quota (`unknownHeaders`). A new one comes with its
    /// migration, a partial index on `at` where it is NULL, and its place
    /// in `put`, `messages(where:)` and MailGmail's metadata headers.
    /// List-Unsubscribe-Post comes with List-Unsubscribe, in a column beside it.
    public static let late: [(column: String, header: String)] = [("reply_to", "Reply-To"), ("unsubscribe", "List-Unsubscribe")]

    /// A store kept in memory, for tests and measures with no file.
    public static let memory = URL(string: "memory:")!

    /// A thread's columns in `threads` from its messages, as SQL over one
    /// thread's rows: in the inbox, in Sent, unread, starred, mail from a
    /// list in it that isn't yours, in one of Gmail's tabs, all of it thrown
    /// away.
    /// `me`: SQL for the account's address.
    static func tallies(_ me: String, named: Bool = false) -> String {
        let category = MailSplit.categories.sorted().map { "instr(labels, '|\($0)|') > 0" }.joined(separator: " OR ")
        let columns = [
            ("total(instr(labels, '|INBOX|') > 0) > 0", "inbox"), ("total(instr(labels, '|SENT|') > 0) > 0", "sent"),
            ("total(instr(labels, '|UNREAD|') > 0) > 0", "unread"), ("total(instr(labels, '|STARRED|') > 0) > 0", "starred"),
            ("total(bulk = 1 AND from_addr != \(me)) > 0", "bulk"),
            ("total(\(category)) > 0", "category"), ("total(instr(labels, '|TRASH|') > 0 OR instr(labels, '|SPAM|') > 0) = count(*)", "gone"),
        ]
        return columns.map { named ? $0.0 + " AS " + $0.1 : $0.0 }.joined(separator: ", ")
    }

    /// A thread's senders but you, "|a@x|b@y|", as SQL over its rows
    /// (`threads.people`); its one argument is the account's address.
    public static let senders = "coalesce('|' || replace(group_concat(DISTINCT CASE WHEN from_addr != ? THEN from_addr END), ',', '|') || '|', '')"

    /// The store keeps `threads` (its migration went in): the lists read
    /// it; without, they read the messages, slower.
    private var tallied = false
    /// And each thread's senders in it (migration 21), and what Skip the
    /// inbox archived (`skipped`).
    private var peopled = false
    /// Move with the mail itself, not with its labels: `content` with
    /// every mail come, gone or given its words (a body fetched), what a
    /// split's words and searches find; `arrivals` only with mail come or
    /// gone (or the account's address), whom mail went to (MailSplitCache
    /// keeps a split's answers by them). `factsMade` counts each reading of
    /// the facts, for a reader that sorts them once a reading.
    private var content = 0
    private var arrivals = 0
    private var factsMade = 0
    /// The store keeps `muted` (⇧M), and reminders if nobody answers.
    private var muting = false
    private var followed = false
    /// Moves with every change to what the splits read (`threads`, `sense`,
    /// `done_waiting`, `snoozes`, `muted`): `facts` is read once a change,
    /// not once for each of the list, the column and the pin that ask.
    /// Another process's change moves SQLite's own `data_version`.
    private var generation = 0
    private var factsKept: (generation: Int, outside: Int64, minute: Int, facts: [MailSplit.Facts])?

    public init(file: URL, migrations: [(Int, String)] = MailStore.migrations, reset: Int = MailStore.reset) {
        self.file = file
        self.migrations = migrations
        resetting = reset
        reading = false
        queue = DispatchQueue(label: "yab.mail.\(file.lastPathComponent)", qos: .utility)
        queue.sync { open() }
        if file != MailStore.memory { reader = MailStore(reading: file) }
    }

    /// The same file, read only, through a connection and a queue of its
    /// own: for what reads the store off the main thread (a search typed,
    /// who you write with, who wrote a thread). A long read there never
    /// holds what the main thread asks of the store, and the sync's writes
    /// never hold it (the file is a WAL). A store in memory is its own.
    public var off: MailStore { reader ?? self }
    private var reader: MailStore?
    /// This is such a look (`off`): it writes nothing, and reads again what
    /// the writer changed (`readAgain`).
    private let reading: Bool
    private var seenVersion: Int64 = -1

    private init(reading file: URL) {
        self.file = file
        migrations = []
        resetting = MailStore.reset
        reading = true
        queue = DispatchQueue(label: "yab.mail.read.\(file.lastPathComponent)", qos: .userInitiated)
        queue.sync {
            connection = SQLiteConnection(path: file.path, flags: SQLITE_OPEN_READONLY, name: "mail store", log: MailStore.log)
            guard connection != nil else { return }
            functions()
            shape()
            readAgain()
        }
    }

    /// The store's own SQL functions, on a connection.
    private func functions() {
        // Words compared as the search compares them, case and accents off,
        // in any script (MailQuery: to:, cc:).
        sqlite3_create_function_v2(db, "yab_fold", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, values in
            guard let value = values?[0], let text = sqlite3_value_text(value) else { return sqlite3_result_null(context) }
            sqlite3_result_text(context, MailQuery.fold(String(cString: text)), -1, MailStore.transient)
        }, nil, nil, nil)
    }

    /// What the file's migrations have given it, for the reads that differ.
    private func shape() {
        let columns = strings("SELECT name FROM pragma_table_info('drafts')", [])
        draftsWhole = columns.contains("forwarded")
        draftsRemind = columns.contains("remind_set")
        draftsRich = columns.contains("signed")
        followed = int("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'followups'", []) == 1
        tallied = int("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'threads'", []) == 1
        peopled = tallied && strings("SELECT name FROM pragma_table_info('threads')", []).contains("people")
        muting = int("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'muted'", []) == 1
        draftFilesKept = string("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'draft_files'", []) != nil
        labeling = int("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'labels'", []) == 1
        readsKept = int("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'read_opens'", []) == 1
        inviting = string("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'rsvps'", []) != nil
    }

    /// The read-only look, after the writer committed: the account's address
    /// and the threads with reminders read again. Inside its queue.
    private func readAgain() {
        guard reading else { return }
        let version = int("PRAGMA data_version", []) ?? 0
        guard version != seenVersion else { return }
        seenVersion = version
        me = meta("me") ?? ""
        if followed { following = Set(strings("SELECT thread FROM followups", [])) }
        if labeling { labelIDs = Set(strings("SELECT id FROM labels", [])) }
    }

    /// Where an account's store lives.
    public static func file(for account: String) -> URL {
        let safe = account.lowercased().map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "@" ? String($0) : "_" }.joined()
        return Store.folder.appendingPathComponent("mail", isDirectory: true).appendingPathComponent("\(safe).sqlite")
    }

    /// Where an account keeps what isn't in its store, its mail's files
    /// (MailFiles) and its drafts' copies (MailAttach): beside the store,
    /// mail/<account>.noindex, a folder Spotlight leaves out, so a mail's
    /// PDF or a draft's copy never turns up in a search of the Mac. An
    /// older Yab's mail/<account> moves there the first time it is asked
    /// for.
    public static func beside(_ file: URL) -> URL {
        let folder = file.deletingPathExtension().appendingPathExtension("noindex")
        noIndex(from: file.deletingPathExtension(), to: folder)
        return folder
    }

    /// A folder Spotlight indexed, moved once into one it leaves out: whole
    /// when there is none yet, else each thing in it the new one lacks.
    public static func noIndex(from old: URL, to folder: URL) {
        moving.lock()
        defer { moving.unlock() }
        guard moved.insert(old.path).inserted else { return }
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: old.path, isDirectory: &isFolder), isFolder.boolValue else { return }
        if !fm.fileExists(atPath: folder.path), (try? fm.moveItem(at: old, to: folder)) != nil { return }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] {
            let into = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: into.path) {
                // Both had it (an older Yab ran since): what is in it, each thing the new one lacks.
                noIndexed(from: old.appendingPathComponent(name), into: into)
            } else {
                try? fm.moveItem(at: old.appendingPathComponent(name), to: into)
            }
        }
        if ((try? fm.contentsOfDirectory(atPath: old.path)) ?? []).isEmpty { try? fm.removeItem(at: old) }
    }

    private static func noIndexed(from old: URL, into folder: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] where !fm.fileExists(atPath: folder.appendingPathComponent(name).path) {
            try? fm.moveItem(at: old.appendingPathComponent(name), to: folder.appendingPathComponent(name))
        }
        try? fm.removeItem(at: old)
    }

    private static let moving = NSLock()
    nonisolated(unsafe) private static var moved = Set<String>()

    /// Every table, for a file older than the base.
    private static let tables = ["threads", "messages", "bodies", "ops", "words", "drafts", "sense", "ahead", "snoozes"]

    private func open() {
        let inMemory = file == MailStore.memory
        if !inMemory { try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true) }
        // The app and `yab mail flush` may open the same file at once: a
        // busy file is waited for, up to five seconds.
        connection = SQLiteConnection(path: inMemory ? ":memory:" : file.path, name: "mail store", log: MailStore.log)
        guard connection != nil else { return }
        functions()
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT)")
        let schema = Int(meta("schema") ?? meta("version") ?? "") ?? 0
        if schema < MailStore.base {
            // None yet, or a shape from before the base: from nothing.
            exec(MailStore.tables.map { "DROP TABLE IF EXISTS \($0);" }.joined())
            exec("DELETE FROM meta")
        }
        exec("""
        CREATE TABLE IF NOT EXISTS messages(
          id TEXT PRIMARY KEY, thread TEXT NOT NULL, from_name TEXT NOT NULL, from_addr TEXT NOT NULL,
          recipients TEXT NOT NULL, cc TEXT NOT NULL, subject TEXT NOT NULL, snippet TEXT NOT NULL,
          at REAL NOT NULL, labels TEXT NOT NULL, rfc_id TEXT NOT NULL, in_reply_to TEXT NOT NULL,
          refs TEXT NOT NULL, bulk INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS messages_thread ON messages(thread);
        CREATE INDEX IF NOT EXISTS messages_at ON messages(at);
        CREATE TABLE IF NOT EXISTS bodies(id TEXT PRIMARY KEY, text TEXT NOT NULL, html TEXT, fetched REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS ops(
          seq INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, thread TEXT NOT NULL, label TEXT NOT NULL,
          tries INTEGER NOT NULL DEFAULT 0, not_before REAL NOT NULL, made REAL NOT NULL, taken REAL);
        CREATE TABLE IF NOT EXISTS drafts(
          id TEXT PRIMARY KEY, thread TEXT NOT NULL, recipients TEXT NOT NULL, cc TEXT NOT NULL, subject TEXT NOT NULL,
          body TEXT NOT NULL, in_reply_to TEXT NOT NULL, refs TEXT NOT NULL, message_id TEXT NOT NULL, updated REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS sense(
          thread TEXT PRIMARY KEY, message TEXT NOT NULL, needs INTEGER NOT NULL, gist TEXT NOT NULL, due REAL,
          kind TEXT NOT NULL, by_model INTEGER NOT NULL, at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS ahead(thread TEXT NOT NULL, message TEXT NOT NULL, n INTEGER NOT NULL, body TEXT NOT NULL,
          PRIMARY KEY(thread, n));
        CREATE TABLE IF NOT EXISTS snoozes(thread TEXT PRIMARY KEY, until REAL, why TEXT NOT NULL, message TEXT NOT NULL, at REAL NOT NULL);
        CREATE VIRTUAL TABLE IF NOT EXISTS words USING fts5(
          id UNINDEXED, subject, sender, body, tokenize='unicode61 remove_diacritics 2');
        """)
        if schema < MailStore.base { setMeta("version", String(MailStore.base)) }
        if meta("schema") == nil { setMeta("schema", String(max(schema, MailStore.base))) }
        migrate()
        shape()
        following = Set(strings("SELECT thread FROM followups", []))
        if labeling { labelIDs = Set(strings("SELECT id FROM labels", [])) }
        let kept = meta("reset")
        if kept != String(resetting) {
            // A store from before resets were counted keeps its mail.
            if kept != nil { forget() }
            setMeta("reset", String(resetting))
        }
        me = meta("me") ?? ""
        // Synced by a Yab that didn't keep `threads` (an older one opened
        // the file since), or kept them without their senders: the threads
        // counted again from their messages.
        if tallied, meta("tallied") != meta("synced") || peopled && meta("peopled") != meta("synced") {
            tallyAll()
            if let synced = meta("synced") {
                setMeta("tallied", synced)
                if peopled { setMeta("peopled", synced) }
            }
        }
    }

    /// The migrations this file hasn't had, in order, each in a transaction
    /// of its own with its number; the first that fails is rolled back and
    /// stops the rest. The number is read again inside the transaction, so
    /// two processes opening the file at once migrate it once.
    private func migrate() {
        for (number, sql) in migrations.sorted(by: { $0.0 < $1.0 }) {
            guard number > Int(meta("schema") ?? "") ?? 0 else { continue }
            guard exec("BEGIN IMMEDIATE") else { return }
            if number <= Int(meta("schema") ?? "") ?? 0 { exec("COMMIT"); continue }
            guard exec(sql) else {
                let error = db.map { String(cString: sqlite3_errmsg($0)) } ?? ""
                exec("ROLLBACK")
                MailGmail.log.error("mail store migration \(number) failed: \(error, privacy: .public)")
                return
            }
            setMeta("schema", String(number))
            exec("COMMIT")
        }
    }

    /// What came from Gmail, gone; what the person did and made stays.
    private func forget() {
        generation += 1
        content += 1
        arrivals += 1
        mailChanged()
        exec("DELETE FROM messages; DELETE FROM bodies; DELETE FROM words; DELETE FROM files;")
        if tallied { exec("DELETE FROM threads; DELETE FROM opened;") }
        if inviting { exec("DELETE FROM invites") }
        run("DELETE FROM meta WHERE k IN ('history', 'synced', 'boot', 'since', 'tallied', 'inbox', 'inbox.page', 'pruned')", [])
    }

    // MARK: - meta

    public func value(_ key: String) -> String? { queue.sync { meta(key) } }

    /// The addresses the account sends as besides its own (Gmail's send-as,
    /// in meta "aliases", a comma between): a reply to all leaves them out
    /// with `me`. None kept yet but what is set there.
    public var aliases: [String] {
        (value("aliases") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    /// The name the newest mail from this address says it by; "" for none.
    public func newestName(from address: String) -> String {
        queue.sync {
            string("SELECT from_name FROM messages WHERE from_addr = ? AND from_name != '' ORDER BY at DESC LIMIT 1", [address.lowercased()]) ?? ""
        }
    }
    public func set(_ key: String, _ value: String?) {
        queue.sync {
            if let value { setMeta(key, value) } else { run("DELETE FROM meta WHERE k = ?", [key]) }
            if key == "me", value?.lowercased() ?? "" != me {
                me = value?.lowercased() ?? ""
                // Whose the last word is, and whose list mail, said again.
                tallyAll()
            }
            // `threads` was kept by this Yab up to this sync (open).
            if key == "synced", let value {
                setMeta("tallied", value)
                if peopled { setMeta("peopled", value) }
            }
        }
    }

    /// Everything Gmail sent us goes, the journal of what you did stays:
    /// a sync from nothing, when Gmail's history no longer reaches back.
    func forgetMail() {
        queue.sync { forget() }
    }

    // MARK: - messages

    /// Messages as Gmail has them now: new ones added, known ones updated
    /// in place (a row keeps its rowid, which keys its words). A body
    /// already fetched is kept, and so are files a message came with, and
    /// where they were saved. `backfilled`: brought by a search from
    /// Gmail, older than the sync keeps; marked so with the moment.
    /// False when the store wouldn't take them: nothing of the page is
    /// kept (all or none), and the caller fetches it again later.
    @discardableResult
    public func put(_ messages: [MailMessage], backfilled: Bool = false) -> Bool {
        guard !messages.isEmpty else { return true }
        return queue.sync {
            guard exec("BEGIN") else {
                MailStore.log.error("mail store: BEGIN failed: \(self.lastError, privacy: .public)")
                return false
            }
            // Only the messages' own rows decide; what hangs off them (a
            // body, its words, files, an invitation) is kept best effort and
            // a failure there is logged.
            var broke = false
            let found: Any = backfilled ? Date().timeIntervalSince1970 : NSNull()
            var came = false
            for m in messages {
                if !came, int("SELECT 1 FROM messages WHERE id = ?", [m.id]) == nil { came = true }
                if tallied {
                    broke = !run("""
                    INSERT INTO messages(id, thread, from_name, from_addr, recipients, cc, subject, snippet, at, labels,
                      rfc_id, in_reply_to, refs, bulk, reply_to, attached, unsubscribe, unsubscribe_post, backfilled)
                      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET thread = excluded.thread, from_name = excluded.from_name,
                      from_addr = excluded.from_addr, recipients = excluded.recipients, cc = excluded.cc, subject = excluded.subject,
                      snippet = excluded.snippet, at = excluded.at, labels = excluded.labels, rfc_id = excluded.rfc_id,
                      in_reply_to = excluded.in_reply_to, refs = excluded.refs, bulk = excluded.bulk,
                      reply_to = coalesce(excluded.reply_to, reply_to), attached = coalesce(excluded.attached, attached),
                      unsubscribe = coalesce(excluded.unsubscribe, unsubscribe), unsubscribe_post = coalesce(excluded.unsubscribe_post, unsubscribe_post),
                      backfilled = coalesce(backfilled, excluded.backfilled)
                    """, MailStore.row(m) + [found])
                } else {
                    broke = !run("""
                    INSERT INTO messages(id, thread, from_name, from_addr, recipients, cc, subject, snippet, at, labels,
                      rfc_id, in_reply_to, refs, bulk, reply_to, attached, unsubscribe, unsubscribe_post) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET thread = excluded.thread, from_name = excluded.from_name,
                      from_addr = excluded.from_addr, recipients = excluded.recipients, cc = excluded.cc, subject = excluded.subject,
                      snippet = excluded.snippet, at = excluded.at, labels = excluded.labels, rfc_id = excluded.rfc_id,
                      in_reply_to = excluded.in_reply_to, refs = excluded.refs, bulk = excluded.bulk,
                      reply_to = coalesce(excluded.reply_to, reply_to), attached = coalesce(excluded.attached, attached),
                      unsubscribe = coalesce(excluded.unsubscribe, unsubscribe), unsubscribe_post = coalesce(excluded.unsubscribe_post, unsubscribe_post)
                    """, MailStore.row(m))
                }
                guard !broke, let row = int("SELECT rowid FROM messages WHERE id = ?", [m.id]) else { broke = true; break }
                if let files = m.files { keep(files, of: m.id) }
                if let calendar = m.calendar { keepingInvite(m.id, thread: m.thread, at: m.date, ics: calendar) }
                if let text = m.text {
                    run("INSERT OR REPLACE INTO bodies(id, text, html, fetched, parts) VALUES(?,?,?,?,?)",
                        [m.id, text, m.html as Any, Date().timeIntervalSince1970, m.files.map { _ in 1 } as Any])
                    run("INSERT OR REPLACE INTO words(rowid, id, subject, sender, body) VALUES(?,?,?,?,?)",
                        [row, m.id, m.subject, m.from.name + " " + m.from.address, text])
                } else if int("SELECT count(*) FROM words WHERE rowid = ?", [row]) == 0 {
                    run("INSERT INTO words(rowid, id, subject, sender, body) VALUES(?,?,?,?,?)",
                        [row, m.id, m.subject, m.from.name + " " + m.from.address, m.snippet])
                }
            }
            if broke {
                exec("ROLLBACK")
                return false
            }
            tally(Set(messages.map(\.thread)))
            content += 1
            if came { arrivals += 1 }
            guard exec("COMMIT") else {
                MailStore.log.error("mail store: COMMIT failed: \(self.lastError, privacy: .public)")
                exec("ROLLBACK")
                return false
            }
            return true
        }
    }

    /// A message's columns, in `put`'s order.
    private static func row(_ m: MailMessage) -> [Any] {
        [m.id, m.thread, m.from.name, m.from.address, m.to.map(\.header).joined(separator: ", "),
         m.cc.map(\.header).joined(separator: ", "), m.subject, m.snippet, m.date.timeIntervalSince1970,
         MailStore.labels(m.labels), m.rfcID, m.inReplyTo, m.references, m.listUnsubscribe ? 1 : 0,
         m.replyTo.map { $0.map(\.header).joined(separator: ", ") } as Any, m.attached.map { $0 ? 1 : 0 } as Any,
         // Without List-Unsubscribe there is nothing to know of it.
         (m.unsubscribe ?? (m.listUnsubscribe ? nil : "")) as Any,
         (m.unsubscribePost ?? m.unsubscribe.map { _ in "" } ?? (m.listUnsubscribe ? nil : "")) as Any]
    }

    public func remove(messages ids: [String]) {
        guard !ids.isEmpty else { return }
        queue.sync {
            exec("BEGIN")
            var threads = Set<String>()
            for id in ids {
                if let thread = string("SELECT thread FROM messages WHERE id = ?", [id]) { threads.insert(thread) }
                run("DELETE FROM words WHERE rowid = (SELECT rowid FROM messages WHERE id = ?)", [id])
                run("DELETE FROM messages WHERE id = ?", [id])
                run("DELETE FROM bodies WHERE id = ?", [id])
                run("DELETE FROM files WHERE message = ?", [id])
                if inviting { run("DELETE FROM invites WHERE message = ?", [id]) }
            }
            tally(threads)
            content += 1
            arrivals += 1
            exec("COMMIT")
        }
    }

    /// `threads`' columns as `tally` writes them, and their SQL over a
    /// thread's rows: each thread's senders too, once the store keeps them.
    private var tallyColumns: String {
        "id, last, last_id, last_from, count, inbox, sent, unread, starred, bulk, category, gone" + (peopled ? ", people" : "")
    }
    private var tallySQL: String { MailStore.tallies("?") + (peopled ? ", " + MailStore.senders : "") }
    private var tallyArgs: [Any] { peopled ? [me, me] : [me] }

    /// `threads` for these threads counted again from their messages; a
    /// thread with none left goes. Inside the store's queue.
    private func tally(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        generation += 1
        mailChanged()
        guard tallied else { return }
        let all = Array(ids)
        for start in stride(from: 0, to: all.count, by: 400) {
            let chunk = Array(all[start..<min(all.count, start + 400)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            run("DELETE FROM threads WHERE id IN (\(marks))", chunk)
            run("""
            INSERT INTO threads(\(tallyColumns))
              SELECT thread, max(at), id, from_addr, count(*), \(tallySQL)
              FROM messages WHERE thread IN (\(marks)) GROUP BY thread
            """, tallyArgs + chunk)
        }
    }

    /// The mail the word index's map of threads is made from changed
    /// (`threadMap`): its messages, their threads or their labels. Kept in
    /// the file, so the read-only look sees it too; anything else written
    /// (what was worked out about a thread, a snooze, a notification said)
    /// leaves the map as it was. Inside the store's queue.
    private func mailChanged() {
        run("INSERT INTO meta(k, v) VALUES('mail-version', '1') ON CONFLICT(k) DO UPDATE SET v = CAST(v AS INTEGER) + 1", [])
    }

    /// Every thread counted again: the account's address came or changed,
    /// or another Yab synced the file.
    private func tallyAll() {
        generation += 1
        content += 1
        arrivals += 1
        mailChanged()
        guard tallied else { return }
        exec("BEGIN")
        exec("DELETE FROM threads")
        run("""
        INSERT INTO threads(\(tallyColumns))
          SELECT thread, max(at), id, from_addr, count(*), \(tallySQL) FROM messages GROUP BY thread
        """, tallyArgs)
        exec("COMMIT")
    }

    /// Messages kept before the store had a column for one of their
    /// headers (`late`), newest first: what MailSync asks Gmail for again.
    func unknownHeaders(limit: Int) -> [String] {
        let unknown = MailStore.late.map { "\($0.column) IS NULL" }.joined(separator: " OR ")
        return queue.sync { strings("SELECT id FROM messages WHERE \(unknown) ORDER BY at DESC LIMIT ?", [limit]) }
    }

    /// Those of these messages still not known once Gmail was asked (gone
    /// since): known to have none, so they aren't asked for again.
    func noHeaders(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        queue.sync {
            for id in ids {
                for (column, _) in MailStore.late { run("UPDATE messages SET \(column) = '' WHERE id = ? AND \(column) IS NULL", [id]) }
                run("UPDATE messages SET unsubscribe_post = '' WHERE id = ? AND unsubscribe_post IS NULL", [id])
            }
        }
    }

    /// A message's labels, as Gmail's history says they changed.
    func relabel(message id: String, add: Set<String>, remove: Set<String>) {
        queue.sync {
            guard let row = query("SELECT labels, thread FROM messages WHERE id = ?", [id]).first,
                  let now = row[0] as? String, let thread = row[1] as? String else { return }
            let labels = MailStore.labels(now).union(add).subtracting(remove)
            guard labels != MailStore.labels(now) else { return }
            run("UPDATE messages SET labels = ? WHERE id = ?", [MailStore.labels(labels), id])
            tally([thread])
        }
    }

    /// Every message of a thread, as you did something to it here: the op
    /// is in the journal, the list shows it at once.
    func relabel(thread id: String, add: Set<String>, remove: Set<String>) {
        queue.sync { if relabeling(id, add: add, remove: remove) { tally([id]) } }
    }

    /// Every message of many threads, in one transaction: an act on many.
    func relabel(threads ids: [String], add: Set<String>, remove: Set<String>) {
        guard !ids.isEmpty, !(add.isEmpty && remove.isEmpty) else { return }
        queue.sync {
            exec("BEGIN")
            tally(Set(ids.filter { relabeling($0, add: add, remove: remove) }))
            exec("COMMIT")
        }
    }

    /// Messages by their ids, in one transaction: an op on messages
    /// (MailOps.bulk(messages:)). Those not kept here are left as they are.
    func relabel(messages ids: [String], add: Set<String>, remove: Set<String>) {
        guard !ids.isEmpty, !(add.isEmpty && remove.isEmpty) else { return }
        queue.sync {
            exec("BEGIN")
            var changed = Set<String>()
            for id in ids {
                guard let row = query("SELECT labels, thread FROM messages WHERE id = ?", [id]).first,
                      let now = row[0] as? String, let thread = row[1] as? String else { continue }
                let labels = MailStore.labels(now).union(add).subtracting(remove)
                guard labels != MailStore.labels(now) else { continue }
                run("UPDATE messages SET labels = ? WHERE id = ?", [MailStore.labels(labels), id])
                changed.insert(thread)
            }
            tally(changed)
            exec("COMMIT")
        }
    }

    /// A thread's messages relabeled, inside the store's queue: whether any
    /// of them changed (and its row in `threads` wants counting again).
    @discardableResult
    private func relabeling(_ thread: String, add: Set<String>, remove: Set<String>) -> Bool {
        var changed = false
        for row in query("SELECT id, labels FROM messages WHERE thread = ?", [thread]) {
            guard let message = row[0] as? String, let now = row[1] as? String else { continue }
            let labels = MailStore.labels(now).union(add).subtracting(remove)
            guard labels != MailStore.labels(now) else { continue }
            run("UPDATE messages SET labels = ? WHERE id = ?", [MailStore.labels(labels), message])
            changed = true
        }
        return changed
    }

    /// How many messages of each thread are here: what fills a pack.
    func messageCounts(_ threads: [String]) -> [String: Int] {
        queue.sync {
            var out: [String: Int] = [:]
            for start in stride(from: 0, to: threads.count, by: 500) {
                let chunk = Array(threads[start..<min(threads.count, start + 500)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                for row in query("SELECT thread, count(*) FROM messages WHERE thread IN (\(marks)) GROUP BY thread", chunk) {
                    if let thread = row[0] as? String, let n = row[1] as? Int64 { out[thread] = Int(n) }
                }
            }
            return out
        }
    }

    public func message(_ id: String) -> MailMessage? {
        queue.sync { messages(where: "m.id = ?", [id]).first }
    }

    /// A thread's messages, oldest first, bodies where fetched.
    public func messages(thread id: String) -> [MailMessage] {
        queue.sync { messages(where: "m.thread = ? ORDER BY m.at", [id]) }
    }

    /// Messages that have no body here yet, of the newest threads with a
    /// label, for the sync to fetch ahead.
    func unfetched(label: String, threads limit: Int) -> [String] {
        queue.sync {
            // The inbox and Sent by `threads`, not a walk of every message.
            let threads = tallied && (label == "INBOX" || label == "SENT")
                ? strings("SELECT id FROM threads WHERE \(label == "INBOX" ? "inbox" : "sent") = 1 ORDER BY last DESC LIMIT ?", [limit])
                : strings("""
                  SELECT thread FROM messages WHERE labels LIKE ? GROUP BY +thread ORDER BY max(at) DESC LIMIT ?
                  """, ["%|\(label)|%", limit])
            guard !threads.isEmpty else { return [] }
            let marks = Array(repeating: "?", count: threads.count).joined(separator: ",")
            return strings("""
            SELECT DISTINCT m.thread FROM messages m LEFT JOIN bodies b ON b.id = m.id
            WHERE b.id IS NULL AND m.thread IN (\(marks))
            """, threads)
        }
    }

    /// Mail that came in since a moment, newest first, bodies where fetched.
    public func inbound(since: Date) -> [MailMessage] {
        queue.sync {
            messages(where: "m.at > ? AND m.labels NOT LIKE '%|SENT|%' ORDER BY m.at DESC", [since.timeIntervalSince1970])
        }
    }

    /// Mail that may be a purchase: robots' mail since `since`, not Sent,
    /// Spam or Trash, newest first (old mail has only its snippet). A few
    /// words in the subject or snippet keep the walk cheap;
    /// MailPurchases.read tells robots from people. Heads only, never a
    /// body: thousands of whole mails held in memory to learn that nearly
    /// all were read before cost hundreds of megabytes every ten minutes.
    public func purchaseHeads(since: Date, limit: Int = 4000) -> [MailPurchaseHead] {
        let words = ["receipt", "invoice", "order", "subscription", "renew", "payment", "charged", "shipped", "delivery",
                     "tracking", "billing", "Rechnung", "Bestellung",
                     // SQLite's LIKE folds case for ASCII only.
                     "чек", "Чек", "заказ", "Заказ", "подписк", "Подписк"]
        let any = words.map { _ in "m.subject LIKE ? OR m.snippet LIKE ?" }.joined(separator: " OR ")
        let args: [Any] = [since.timeIntervalSince1970] + words.flatMap { ["%\($0)%", "%\($0)%"] } + [limit]
        return queue.sync {
            query("""
            SELECT m.id AS id, m.labels AS labels, length(m.snippet) AS snippet,
              b.id IS NOT NULL AS body, b.html IS NOT NULL AS html
            FROM messages m LEFT JOIN bodies b ON b.id = m.id
            WHERE m.at > ? AND m.labels NOT LIKE '%|SENT|%' AND m.labels NOT LIKE '%|SPAM|%' AND m.labels NOT LIKE '%|TRASH|%'
              AND (\(any)) ORDER BY m.at DESC LIMIT ?
            """, args).compactMap { row in
                guard let id = row.string("id") else { return nil }
                return MailPurchaseHead(id: id, labels: MailStore.labels(row.string("labels") ?? ""), snippet: Int(row.int64("snippet") ?? 0),
                                        body: row.bool("body") ?? false, html: row.bool("html") ?? false)
            }
        }
    }

    /// These mails whole, for the few a purchases pass hasn't read yet.
    public func messages(ids: [String]) -> [MailMessage] {
        guard !ids.isEmpty else { return [] }
        return queue.sync {
            messages(where: "m.id IN (\(ids.map { _ in "?" }.joined(separator: ",")))", ids)
        }
    }

    // MARK: - threads

    /// The threads with a message carrying a label and one unread: what
    /// Mark All as Read on the label reads here (MailLabels.markAllRead).
    public func unreadThreads(label: String) -> [String] {
        queue.sync {
            strings("""
            SELECT DISTINCT thread FROM messages WHERE instr(labels, '|UNREAD|') > 0
              AND thread IN (SELECT thread FROM messages WHERE instr(labels, ?) > 0)
            """, ["|\(label)|"])
        }
    }

    /// Who wrote mail of their own (no bulk) that the word index finds for
    /// an expression, most threads first: whose signatures say "Attorney"
    /// or "LLP", for "my lawyer's mail" (FieldRoles).
    public func senders(saying expression: String, limit: Int) -> [(name: String, address: String, threads: Int)] {
        queue.sync {
            query("""
            SELECT from_name, lower(from_addr), count(DISTINCT thread) FROM messages
              WHERE bulk = 0 AND rowid IN (SELECT rowid FROM words WHERE words MATCH ?) AND lower(from_addr) != ?
              GROUP BY lower(from_addr) ORDER BY 3 DESC LIMIT ?
            """, [expression, me.lowercased(), limit]).compactMap { row in
                guard row.count == 3, let name = row[0] as? String, let address = row[1] as? String else { return nil }
                return (name, address, Int(row[2] as? Int64 ?? 0))
            }
        }
    }

    /// The threads carrying a label, newest first, as a list shows them.
    /// The inbox and Sent by the threads' own newest mail (`threads`).
    public func threads(label: String, limit: Int = 100, before: Date? = nil) -> [MailThread] {
        queue.sync {
            let until = (before ?? .distantFuture).timeIntervalSince1970
            let ids: [String]
            if tallied, label == "INBOX" || label == "SENT" {
                ids = strings("SELECT id FROM threads WHERE \(label == "INBOX" ? "inbox" : "sent") = 1 AND last < ? ORDER BY last DESC LIMIT ?",
                              [until, limit])
            } else {
                // One pass over the messages: grouped by the thread index,
                // SQLite would read each message where it lies (`+thread`).
                ids = strings("""
                SELECT thread FROM messages WHERE labels LIKE ? AND at < ? GROUP BY +thread ORDER BY max(at) DESC LIMIT ?
                """, ["%|\(label)|%", until, limit])
            }
            return summaries(ids)
        }
    }

    public func thread(_ id: String) -> MailThread? { queue.sync { summaries([id]).first } }

    /// Threads by their ids, as a list shows them, newest first; one no
    /// longer here is left out.
    public func threads(ids: [String]) -> [MailThread] { queue.sync { summaries(ids).sorted { $0.last > $1.last } } }

    /// How many threads are kept here, for Settings › Mail.
    public func threadCount() -> Int { queue.sync { Int(int("SELECT COUNT(DISTINCT thread) FROM messages", []) ?? 0) } }

    /// Threads in the inbox with mail not yet read: the Dock's Unread.
    public func unreadThreads() -> Int {
        queue.sync { Int(int("SELECT COUNT(DISTINCT thread) FROM messages WHERE labels LIKE '%|INBOX|%' AND labels LIKE '%|UNREAD|%'", []) ?? 0) }
    }

    /// Every message here, or only those with their bodies.
    public func messageIDs(withBodies: Bool = false) -> Set<String> {
        queue.sync { Set(strings(withBodies ? "SELECT id FROM bodies" : "SELECT id FROM messages", [])) }
    }

    /// The threads someone wrote in or was written to in, newest first.
    /// (Here and below, `+thread`: one pass over the messages, where the
    /// thread index would have SQLite read each message where it lies.)
    public func threads(with address: String, limit: Int = 5) -> [MailThread] {
        queue.sync {
            let ids = strings("""
            SELECT thread FROM messages WHERE from_addr = ? OR recipients LIKE ? GROUP BY +thread ORDER BY max(at) DESC LIMIT ?
            """, [address.lowercased(), "%" + address.lowercased() + "%", limit])
            return summaries(ids)
        }
    }

    /// Threads a whole domain wrote in ("stripe.com": receipts@stripe.com,
    /// billing.stripe.com), or, not only from it, was written to in too.
    public func threads(domain: String, from: Bool, limit: Int = 100) -> [MailThread] {
        let domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@. "))
        guard !domain.isEmpty else { return [] }
        return queue.sync {
            let at = "%@" + domain, sub = "%." + domain
            let ids = from
                ? strings("""
                  SELECT thread FROM messages WHERE from_addr LIKE ? OR from_addr LIKE ? GROUP BY +thread ORDER BY max(at) DESC LIMIT ?
                  """, [at, sub, limit])
                : strings("""
                  SELECT thread FROM messages WHERE from_addr LIKE ? OR from_addr LIKE ? OR recipients LIKE ? OR recipients LIKE ?
                  GROUP BY +thread ORDER BY max(at) DESC LIMIT ?
                  """, [at, sub, "%" + at.dropFirst() + "%", "%" + sub.dropFirst() + "%", limit])
            return summaries(ids)
        }
    }

    /// Threads by Gmail's labels as a whole, newest first: those with none
    /// of `without` on any message, and, `others`, someone else's mail in
    /// them (Done leaves out your own sends nobody answered, which are
    /// Sent's). What this Mac keeps; older mail is the server's (MailQuery).
    public func threads(without: [String], others: Bool = false, limit: Int = 300) -> [MailThread] {
        let none = without.map { "max(labels LIKE '%|\($0)|%') = 0" }
        let clause = (none + (others ? ["max(from_addr != ?) = 1"] : [])).joined(separator: " AND ")
        return queue.sync {
            let ids = strings("""
            SELECT thread FROM messages GROUP BY +thread \(clause.isEmpty ? "" : "HAVING " + clause) ORDER BY max(at) DESC LIMIT ?
            """, others ? [me, limit] : [limit])
            return summaries(ids)
        }
    }

    /// Threads as a list shows them, from their messages, a few hundred
    /// asked at once.
    private func summaries(_ ids: [String]) -> [MailThread] {
        guard !ids.isEmpty else { return [] }
        readAgain()
        var by: [String: [Head]] = [:]
        var done: [String: String] = [:]
        var found = Set<String>(), muted = Set<String>()
        for start in stride(from: 0, to: ids.count, by: 400) {
            let chunk = Array(ids[start..<min(ids.count, start + 400)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for head in heads("m.thread IN (\(marks)) ORDER BY m.at", chunk) {
                by[head.thread, default: []].append(head)
            }
            for row in query("SELECT thread, message FROM done_waiting WHERE thread IN (\(marks))", chunk) {
                if let thread = row[0] as? String, let message = row[1] as? String { done[thread] = message }
            }
            if tallied {
                found.formUnion(strings("SELECT DISTINCT thread FROM messages WHERE thread IN (\(marks)) AND backfilled IS NOT NULL", chunk))
            }
            if muting { muted.formUnion(strings("SELECT thread FROM muted WHERE thread IN (\(marks))", chunk)) }
        }
        return ids.compactMap { id in
            by[id].flatMap { summary(id, $0, done: done[id], muted: muted.contains(id)) }.map { thread in
                var thread = thread
                thread.backfilled = found.contains(id)
                return thread
            }
        }
    }

    private func summary(_ id: String, _ all: [Head], done: String?, muted: Bool) -> MailThread? {
        guard let last = all.last else { return nil }
        let labels = all.reduce(into: Set<String>()) { $0.formUnion($1.labels) }
        var people: [MailPerson] = []
        for message in all.reversed() where message.from.address != me && !people.contains(where: { $0.address == message.from.address }) {
            people.append(message.from)
        }
        if people.isEmpty { people = MailPerson.list(last.to) }
        let mine = !me.isEmpty && last.from.address == me
        // Its line, the start of the last mail's own words: not the mail it
        // quotes, nor "On … wrote:" over that (MailSense.unquoted).
        return MailThread(id: id, subject: all.first?.subject ?? "", snippet: MailSense.unquoted(last.snippet), last: last.date, labels: labels,
                          unread: all.contains { $0.labels.contains("UNREAD") }, people: people, count: all.count,
                          lastIsMine: mine,
                          bulk: all.contains { $0.bulk && $0.from.address != me },
                          // Only yours can be waited on: no look for the rest.
                          doneWaiting: mine && done == last.id, muted: muted,
                          // Nor reminded of: an answer ends a reminder.
                          followup: mine && following.contains(id) ? followupRow(id) : nil,
                          attached: all.contains { $0.attached })
    }

    /// Of a message, what a thread's row is made of: who and to whom (as the
    /// header has it, read only when the row needs it), what about, when.
    private struct Head {
        public let id: String
        public let thread: String
        public let from: MailPerson
        public let to: String
        public let subject: String
        public let snippet: String
        public let date: Date
        public let labels: Set<String>
        public let bulk: Bool
        public let attached: Bool
    }

    /// Messages as rows are made of them, read column by column: a list's
    /// page reads a few hundred, and parsing every one's Cc and To as a
    /// whole message's took longer than the read.
    private func heads(_ clause: String, _ args: [Any]) -> [Head] {
        let sql = "SELECT m.id, m.thread, m.from_name, m.from_addr, m.recipients, m.subject, m.snippet, m.at, m.labels, m.bulk, m.attached"
            + " FROM messages m WHERE " + clause
        guard let statement = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(statement) }
        let text = { (column: Int32) in sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        var out: [Head] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append(Head(id: text(0), thread: text(1), from: MailPerson(name: text(2), address: text(3)), to: text(4), subject: text(5),
                            snippet: text(6), date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                            labels: MailStore.labels(text(8)), bulk: sqlite3_column_int64(statement, 9) != 0,
                            attached: sqlite3_column_int64(statement, 10) == 1))
        }
        return out
    }

    // MARK: - files

    /// A message's files as its parts said: nil while they aren't known.
    public func files(message id: String) -> [MailFile]? {
        queue.sync {
            guard int("SELECT parts FROM bodies WHERE id = ?", [id]) == 1 else { return nil }
            return fileRows([id])[id] ?? []
        }
    }

    /// Gmail's search says these carry files (has:attachment): a clip on
    /// their rows, until their parts are read and say for themselves.
    func markAttached(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        queue.sync {
            exec("BEGIN")
            for id in ids { run("UPDATE messages SET attached = 1 WHERE id = ? AND attached IS NULL", [id]) }
            exec("COMMIT")
        }
    }

    /// Files of mail since a moment, smaller than `under` bytes, newest mail
    /// first: what is fetched ahead (MailFiles).
    func filesAhead(since: Date, under: Int, limit: Int) -> [(message: String, at: Date, file: MailFile)] {
        queue.sync {
            query("""
            SELECT f.message, m.at, f.part, f.name, f.mime, f.size, f.attachment_id, f.content_id, f.inline
            FROM files f JOIN messages m ON m.id = f.message
            WHERE m.at > ? AND f.size < ? AND m.labels NOT LIKE '%|SPAM|%' AND m.labels NOT LIKE '%|TRASH|%'
            ORDER BY m.at DESC LIMIT ?
            """, [since.timeIntervalSince1970, under, limit]).compactMap { row in
                guard let message = row[0] as? String, let file = MailStore.file(Array(row[2...])) else { return nil }
                return (message, Date(timeIntervalSince1970: row[1] as? Double ?? 0), file)
            }
        }
    }

    /// Where the person last saved a file (⌘S), so the same file saved
    /// again is the copy already there.
    public func saved(message: String, part: String) -> String? {
        queue.sync { string("SELECT saved_path FROM files WHERE message = ? AND part = ?", [message, part]) }
    }

    public func keepSaved(message: String, part: String, path: String) {
        queue.sync { run("UPDATE files SET saved_path = ? WHERE message = ? AND part = ?", [path, message, part]) }
    }

    /// One file a mail carried, as Files lists it beside downloads: who
    /// sent it, in which thread, and whether the mail was yours.
    public struct ShelfRow {
        public let message: String
        public let thread: String
        public let from: MailPerson
        public let to: [MailPerson]
        public let subject: String
        public let at: Date
        public let sent: Bool
        public let file: MailFile
    }

    /// Mail's files since `since`, newest first: attachments and the
    /// pictures a mail's words draw (a Content-ID, at least 4 KB, so no
    /// spacer or tracking pixel), never Spam's or Trash's.
    public func shelf(since: Date, limit: Int) -> [ShelfRow] {
        queue.sync {
            query("""
            SELECT f.part, f.name, f.mime, f.size, f.attachment_id, f.content_id, f.inline,
              m.id, m.thread, m.from_name, m.from_addr, m.recipients, m.subject, m.at, m.labels
            FROM files f JOIN messages m ON m.id = f.message
            WHERE m.at > ? AND (f.inline = 0 OR (f.content_id != '' AND f.size >= 4096))
              AND m.labels NOT LIKE '%|SPAM|%' AND m.labels NOT LIKE '%|TRASH|%'
            ORDER BY m.at DESC LIMIT ?
            """, [since.timeIntervalSince1970, limit]).compactMap { row in
                guard let file = MailStore.file(Array(row[0...6])), let id = row[7] as? String, let thread = row[8] as? String else { return nil }
                let labels = row[14] as? String ?? ""
                return ShelfRow(message: id, thread: thread,
                                from: MailPerson(name: row[9] as? String ?? "", address: row[10] as? String ?? ""),
                                to: MailPerson.list(row[11] as? String ?? ""), subject: row[12] as? String ?? "",
                                at: Date(timeIntervalSince1970: row[13] as? Double ?? 0),
                                sent: labels.contains("|SENT|"), file: file)
            }
        }
    }

    /// A message's files as its parts say now: each kept, with where it was
    /// saved; parts it no longer has, gone.
    private func keep(_ files: [MailFile], of message: String) {
        let marks = Array(repeating: "?", count: files.count).joined(separator: ",")
        run("DELETE FROM files WHERE message = ?" + (files.isEmpty ? "" : " AND part NOT IN (\(marks))"), [message] + files.map(\.part))
        for file in files {
            run("""
            INSERT INTO files(message, part, name, mime, size, attachment_id, content_id, inline) VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(message, part) DO UPDATE SET name = excluded.name, mime = excluded.mime, size = excluded.size,
              attachment_id = excluded.attachment_id, content_id = excluded.content_id, inline = excluded.inline
            """, [message, file.part, file.name, file.mime, file.size, file.attachmentID, file.contentID, file.inline ? 1 : 0])
        }
    }

    /// The files of these messages, each message's in its parts' order.
    private func fileRows(_ ids: [String]) -> [String: [MailFile]] {
        var out: [String: [MailFile]] = [:]
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = Array(ids[start..<min(ids.count, start + 500)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for row in query("""
            SELECT message, part, name, mime, size, attachment_id, content_id, inline FROM files WHERE message IN (\(marks))
            """, chunk) {
                guard let message = row[0] as? String, let file = MailStore.file(Array(row[1...])) else { continue }
                out[message, default: []].append(file)
            }
        }
        return out.mapValues { $0.sorted { MailFile.ordered($0.part, $1.part) } }
    }

    /// A file as its row has it: part, name, mime, size, attachment id,
    /// Content-ID, inline.
    private static func file(_ row: [Any?]) -> MailFile? {
        guard row.count >= 7, let part = row[0] as? String, let name = row[1] as? String else { return nil }
        return MailFile(part: part, name: name, mime: row[2] as? String ?? "", size: Int(row[3] as? Int64 ?? 0),
                        attachmentID: row[4] as? String ?? "", contentID: row[5] as? String ?? "", inline: (row[6] as? Int64 ?? 0) != 0)
    }

    // MARK: - splits

    /// What the splits sort threads by (MailSplit.Facts), newest first: every
    /// thread in the inbox, whatever its age, and every one whose last word
    /// is yours from the days Waiting looks at. One pass over `threads`, so
    /// a split of a whole inbox counts and pages without its messages.
    public func facts(now: Date = Date()) -> [MailSplit.Facts] { stampedFacts(now: now).facts }

    /// The same, with which reading of them it is (`factsMade`): the same
    /// stamp, the same facts, for a reader that sorts them once a reading
    /// (MailSplitCache); and how far the mail itself is (`content`).
    public func stampedFacts(now: Date = Date()) -> (facts: [MailSplit.Facts], stamp: Int, content: Int, arrivals: Int) {
        queue.sync {
            let facts = readFacts(now: now)
            return (facts, factsMade, content, arrivals)
        }
    }

    /// `facts`, inside the store's queue.
    private func readFacts(now: Date) -> [MailSplit.Facts] {
        // Waiting's window moves by the minute: the same minute and no
        // change here or by another process, the same facts.
        let minute = Int(now.timeIntervalSince1970 / 60)
        let outside = int("PRAGMA data_version", []) ?? 0
        if let kept = factsKept, kept.generation == generation, kept.outside == outside, kept.minute == minute { return kept.facts }
        factsMade += 1
        // Without `threads` (its migration not in yet): the same, from the messages.
        let source = tallied ? "threads" : """
        (SELECT thread AS id, max(at) AS last, id AS last_id, from_addr AS last_from, count(*) AS count,
          \(MailStore.tallies("?", named: true)) FROM messages GROUP BY thread)
        """
        let window: [Any] = [me, now.timeIntervalSince1970 - MailSplit.waitsTo, now.timeIntervalSince1970 - MailSplit.waitsFrom]
        let sql = """
        SELECT t.id, t.last, t.inbox, t.bulk, t.category, t.gone, (? != '' AND t.last_from = ?), d.message = t.last_id, s.kind,
          z.thread IS NOT NULL, \(muting ? "u.thread IS NOT NULL" : "0"), t.unread, t.starred, t.sent, \(followed ? "f.fired IS NOT NULL" : "0"),
          \(peopled ? "t.people" : "''"), s.thread IS NOT NULL, coalesce(s.needs, 0), s.due IS NOT NULL
        FROM \(source) t LEFT JOIN sense s ON s.thread = t.id LEFT JOIN done_waiting d ON d.thread = t.id
          LEFT JOIN snoozes z ON z.thread = t.id \(muting ? "LEFT JOIN muted u ON u.thread = t.id" : "")
          \(followed ? "LEFT JOIN followups f ON f.thread = t.id" : "")
        WHERE t.inbox = 1 OR (t.last_from = ? AND t.gone = 0 AND t.last > ? AND t.last < ?)
        ORDER BY \(followed ? "max(t.last, coalesce(f.fired, 0))" : "t.last") DESC
        """
        let args: [Any] = [me, me] + (tallied ? [] : [me]) + window
        // Read column by column, not through `query`'s rows of boxed
        // values: a whole inbox is thousands of rows, after every change.
        var facts: [MailSplit.Facts] = []
        if let statement = prepare(sql, args) {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = sqlite3_column_text(statement, 0) else { continue }
                let on = { (column: Int32) in sqlite3_column_int64(statement, column) != 0 }
                let kind = sqlite3_column_text(statement, 8).flatMap { MailSensed.Kind(rawValue: String(cString: $0)) }
                let people = sqlite3_column_text(statement, 15).map { String(cString: $0) } ?? ""
                facts.append(MailSplit.Facts(id: String(cString: id), last: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                                             inbox: on(2), bulk: on(3), category: on(4), gone: on(5), lastIsMine: on(6), doneWaiting: on(7),
                                             kind: kind, snoozed: on(9), muted: on(10), unread: on(11), starred: on(12), replied: on(13),
                                             fired: on(14), people: people, sensed: on(16), needs: on(17), due: on(18)))
            }
            sqlite3_finalize(statement)
        }
        factsKept = (generation, outside, minute, facts)
        return facts
    }

    // MARK: - sense

    public func sensed(_ thread: String) -> MailSensed? {
        queue.sync {
            query("SELECT thread, message, needs, gist, due, kind, by_model FROM sense WHERE thread = ?", [thread]).first.map { row in
                MailSensed(thread: thread, message: row[1] as? String ?? "", needs: (row[2] as? Int64 ?? 0) != 0,
                           gist: row[3] as? String ?? "", due: (row[4] as? Double).map(Date.init(timeIntervalSince1970:)),
                           kind: MailSensed.Kind(rawValue: row[5] as? String ?? "") ?? .other, byModel: (row[6] as? Int64 ?? 0) != 0)
            }
        }
    }

    /// What was worked out about these threads, by thread.
    public func sensed(_ threads: [String]) -> [String: MailSensed] {
        guard !threads.isEmpty else { return [:] }
        return queue.sync {
            var out: [String: MailSensed] = [:]
            for start in stride(from: 0, to: threads.count, by: 400) {
                let chunk = Array(threads[start..<min(threads.count, start + 400)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                for row in query("SELECT thread, message, needs, gist, due, kind, by_model FROM sense WHERE thread IN (\(marks))", chunk) {
                    guard let thread = row[0] as? String else { continue }
                    out[thread] = MailSensed(thread: thread, message: row[1] as? String ?? "", needs: (row[2] as? Int64 ?? 0) != 0,
                                             gist: row[3] as? String ?? "", due: (row[4] as? Double).map(Date.init(timeIntervalSince1970:)),
                                             kind: MailSensed.Kind(rawValue: row[5] as? String ?? "") ?? .other, byModel: (row[6] as? Int64 ?? 0) != 0)
                }
            }
            return out
        }
    }

    /// Threads read as each kind whose newest mail came since a time, in
    /// Trash or Spam or not, newest first: Settings › Mail › Sorting's
    /// numbers, and the threads a kind's Gmail label goes on.
    public func kinds(since: Date) -> [(thread: String, kind: MailSensed.Kind)] {
        queue.sync {
            let sql = tallied
                ? "SELECT s.thread, s.kind FROM sense s JOIN threads t ON t.id = s.thread WHERE t.last > ? AND t.gone = 0 ORDER BY t.last DESC"
                : "SELECT s.thread, s.kind FROM sense s JOIN messages m ON m.thread = s.thread GROUP BY s.thread HAVING max(m.at) > ? ORDER BY max(m.at) DESC"
            return query(sql, [since.timeIntervalSince1970]).compactMap { row in
                guard let thread = row[0] as? String, let kind = MailSensed.Kind(rawValue: row[1] as? String ?? "") else { return nil }
                return (thread, kind)
            }
        }
    }

    /// Threads of the inbox the rules haven't read yet, newest first, past
    /// the newest MailSense reads after each sync (MailSense.backfill): any
    /// with mail of someone else's, which is what they read.
    func unsensedInbox(limit: Int) -> [String] {
        queue.sync {
            guard tallied else { return [] }
            return strings("""
            SELECT t.id FROM threads t WHERE t.inbox = 1 AND t.gone = 0
              AND NOT EXISTS (SELECT 1 FROM sense s WHERE s.thread = t.id)
              AND EXISTS (SELECT 1 FROM messages m WHERE m.thread = t.id AND m.from_addr != ?)
            ORDER BY t.last DESC LIMIT ?
            """, [me, limit])
        }
    }

    public func keep(_ sensed: MailSensed) { keep([sensed]) }

    /// What was worked out about many threads, in one transaction: after
    /// an update every thread of the inbox is sorted again, and each in a
    /// commit of its own held the store three hundred times over.
    public func keep(_ all: [MailSensed]) {
        guard !all.isEmpty else { return }
        queue.sync {
            generation += 1
            let at = Date().timeIntervalSince1970
            if all.count > 1 { exec("BEGIN") }
            for sensed in all {
                run("INSERT OR REPLACE INTO sense(thread, message, needs, gist, due, kind, by_model, at) VALUES(?,?,?,?,?,?,?,?)",
                    [sensed.thread, sensed.message, sensed.needs ? 1 : 0, sensed.gist, sensed.due?.timeIntervalSince1970 as Any,
                     sensed.kind.rawValue, sensed.byModel ? 1 : 0, at])
            }
            if all.count > 1 { exec("COMMIT") }
        }
    }

    /// The shared parse, keyed by message; a richer body preserves a previous use.
    public func keepCode(_ read: MailCodeRead, message: MailMessage) {
        queue.sync {
            run("""
            INSERT INTO codes(thread,message,code,shown,purpose,amount,merchant,card,expires,at,sure)
            VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(message) DO UPDATE SET
              code=excluded.code, shown=excluded.shown, purpose=excluded.purpose, amount=excluded.amount,
              merchant=excluded.merchant, card=excluded.card, expires=excluded.expires, sure=excluded.sure
            """, [message.thread, message.id, read.code, read.shown, read.purpose.rawValue,
                  read.amount as Any, read.merchant as Any, read.card as Any, read.expires?.timeIntervalSince1970 as Any,
                  message.date.timeIntervalSince1970, read.sure ? 1 : 0])
        }
    }

    public func code(message: String) -> MailCodeRead? {
        queue.sync {
            query("SELECT code,shown,purpose,amount,merchant,card,expires,sure FROM codes WHERE message=?", [message]).first.map { r in
                MailCodeRead(code: r[0] as? String ?? "", shown: r[1] as? String ?? "",
                             purpose: MailCodeRead.Purpose(rawValue: r[2] as? String ?? "") ?? .other,
                             amount: r[3] as? String, merchant: r[4] as? String, card: r[5] as? String,
                             expires: (r[6] as? Double).map(Date.init(timeIntervalSince1970:)), sure: (r[7] as? Int64 ?? 0) != 0)
            }
        }
    }

    public func codeMessage(thread: String) -> String? {
        queue.sync { string("SELECT message FROM codes WHERE thread=? ORDER BY at DESC LIMIT 1", [thread]) }
    }

    /// Resend invalidates the older code from this exact sender, across threads.
    public func codeReplaced(message: String, now: Date = Date()) -> Bool {
        queue.sync {
            int("""
            SELECT count(*) FROM codes old JOIN messages m ON m.id=old.message
              JOIN messages next ON next.from_addr=m.from_addr JOIN codes newer ON newer.message=next.id
            WHERE old.message=? AND newer.at>old.at AND newer.at<=?
              AND next.labels NOT LIKE '%SPAM%' AND next.labels NOT LIKE '%TRASH%'
            """, [message, now.addingTimeInterval(30).timeIntervalSince1970]).map { $0 > 0 } ?? false
        }
    }

    /// When the sender's next newer code is dated, which replaces this one
    /// half a minute before (`codeReplaced`); nil if none has come.
    public func codeReplacedAt(message: String) -> Date? {
        queue.sync {
            let found = query("""
            SELECT min(newer.at) FROM codes old JOIN messages m ON m.id=old.message
              JOIN messages next ON next.from_addr=m.from_addr JOIN codes newer ON newer.message=next.id
            WHERE old.message=? AND newer.at>old.at
              AND next.labels NOT LIKE '%SPAM%' AND next.labels NOT LIKE '%TRASH%'
            """, [message]).first?.first
            guard let at = (found as? Double) ?? (found as? Int64).map(Double.init) else { return nil }
            return Date(timeIntervalSince1970: at)
        }
    }

    public func useCode(message: String, site: String, at: Date = Date()) {
        queue.sync { run("UPDATE codes SET used=?, site=? WHERE message=?", [at.timeIntervalSince1970, site, message]) }
    }

    public func codeUse(message: String) -> (at: Date, site: String)? {
        queue.sync {
            guard let r = query("SELECT used,site FROM codes WHERE message=? AND used IS NOT NULL", [message]).first,
                  let at = r[0] as? Double else { return nil }
            return (Date(timeIntervalSince1970: at), r[1] as? String ?? "")
        }
    }

    // MARK: - promised

    /// Promises read from your mail (MailPromise.run), a new one kept, one
    /// already here keeping its state (what was done with it), an open
    /// one's day read again.
    /// Whether any was new.
    @discardableResult
    public func keepPromises(_ all: [MailPromised]) -> Bool {
        guard !all.isEmpty else { return false }
        return queue.sync {
            let before = int("SELECT count(*) FROM promises", []) ?? 0
            if all.count > 1 { exec("BEGIN") }
            for one in all {
                // An open one keeps its state, its day read again (a misread day corrected).
                run("""
                    INSERT INTO promises(message, n, thread, quote, person, address, kind, due, at, state, theirs, soft, timed)
                      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(message, n) DO UPDATE SET due = excluded.due, soft = excluded.soft, timed = excluded.timed,
                      person = excluded.person, address = excluded.address WHERE state IN ('open', 'judgment')
                    """,
                    [one.message, one.n, one.thread, one.quote, one.person, one.address, one.kind.rawValue,
                     one.due?.timeIntervalSince1970 as Any, one.at.timeIntervalSince1970, one.state.rawValue,
                     one.theirs ? 1 : 0, one.soft ? 1 : 0, one.timed ? 1 : 0])
            }
            if all.count > 1 { exec("COMMIT") }
            return (int("SELECT count(*) FROM promises", []) ?? 0) != before
        }
    }

    /// The promises in these states, newest first.
    public func promises(states: [MailPromised.State]) -> [MailPromised] {
        guard !states.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: states.count).joined(separator: ",")
        return queue.sync {
            query("SELECT message, n, thread, quote, person, address, kind, due, at, state, theirs, soft, timed FROM promises WHERE state IN (\(marks)) ORDER BY at DESC",
                  states.map(\.rawValue)).compactMap { row in
                guard let message = row[0] as? String, let thread = row[2] as? String else { return nil }
                return MailPromised(message: message, n: Int(row[1] as? Int64 ?? 0), thread: thread, quote: row[3] as? String ?? "",
                                    person: row[4] as? String ?? "", address: row[5] as? String ?? "",
                                    kind: MailPromised.Kind(rawValue: row[6] as? String ?? "") ?? .word,
                                    due: (row[7] as? Double).map(Date.init(timeIntervalSince1970:)),
                                    at: Date(timeIntervalSince1970: row[8] as? Double ?? 0),
                                    state: MailPromised.State(rawValue: row[9] as? String ?? "") ?? .open,
                                    theirs: (row[10] as? Int64 ?? 0) != 0, soft: (row[11] as? Int64 ?? 0) != 0,
                                    timed: (row[12] as? Int64 ?? 0) != 0)
            }
        }
    }

    /// A promise kept, moved or put back: whether its state changed.
    @discardableResult
    public func setPromise(_ promise: MailPromised, state: MailPromised.State) -> Bool {
        queue.sync {
            let was = string("SELECT state FROM promises WHERE message = ? AND n = ?", [promise.message, promise.n])
            guard was != nil, was != state.rawValue else { return false }
            run("UPDATE promises SET state = ? WHERE message = ? AND n = ?", [state.rawValue, promise.message, promise.n])
            return true
        }
    }

    /// One promise by the mail that said it and its place in it.
    public func promise(message: String, n: Int) -> MailPromised? {
        promises(states: [.open, .judgment, .done, .moved, .not]).first { $0.message == message && $0.n == n }
    }

    /// E on a thread in Promised: every open promise in it kept by hand.
    /// What was open, for ⌘Z.
    public func keepPromises(inThread thread: String) -> [MailPromised] {
        let open = promises(states: [.open, .judgment]).filter { $0.thread == thread && !$0.theirs }
        for one in open { setPromise(one, state: .done) }
        return open
    }

    // MARK: - what you did, for offers

    /// An act of yours on threads (MailOps), each with when its last mail
    /// had come; what is two months old goes.
    func logActs(_ kind: String, threads: [String], label: String = "", at: Date = Date()) {
        guard !threads.isEmpty else { return }
        queue.sync {
            if threads.count > 1 { exec("BEGIN") }
            for thread in threads {
                run("""
                INSERT INTO acts(kind, thread, label, at, came) VALUES(?, ?, ?, ?,
                  coalesce((SELECT max(at) FROM messages WHERE thread = ? AND labels NOT LIKE '%|SENT|%'), 0))
                """, [kind, thread, label, at.timeIntervalSince1970, thread])
            }
            run("DELETE FROM acts WHERE at < ?", [at.timeIntervalSince1970 - 60 * 86_400])
            if threads.count > 1 { exec("COMMIT") }
        }
    }

    public struct Act: Equatable {
        public let kind: String
        public let thread: String
        public let label: String
        public let at: Date
        /// When the thread's last mail had come, as it was done.
        public let came: Date
    }

    public func acts(since: Date) -> [Act] {
        queue.sync {
            query("SELECT kind, thread, label, at, came FROM acts WHERE at > ? ORDER BY at", [since.timeIntervalSince1970]).compactMap { row in
                guard let kind = row[0] as? String, let thread = row[1] as? String, let at = row[3] as? Double else { return nil }
                return Act(kind: kind, thread: thread, label: row[2] as? String ?? "", at: Date(timeIntervalSince1970: at),
                           came: Date(timeIntervalSince1970: row[4] as? Double ?? 0))
            }
        }
    }

    /// Who wrote to you since a moment, but you: per address, the name it
    /// last went by, how many threads, how many of them you took out of the
    /// inbox without opening (unread still, never opened here), how many
    /// you opened, whether it is a list's, and its newest thread and mail.
    public struct Sender: Equatable {
        public let address: String
        public let name: String
        public let threads: Int
        public let outUnopened: Int
        public let opened: Int
        public let list: Bool
        public let thread: String
        public let first: Date
        public let last: Date
    }

    public func senders(since: Date) -> [Sender] {
        queue.sync {
            let me = (meta("me") ?? "").lowercased()
            return query("""
            SELECT lower(m.from_addr), max(m.from_name), count(DISTINCT m.thread),
              count(DISTINCT CASE WHEN m.labels NOT LIKE '%|INBOX|%' AND m.labels LIKE '%|UNREAD|%' AND o.thread IS NULL THEN m.thread END),
              count(DISTINCT CASE WHEN o.thread IS NOT NULL OR m.labels NOT LIKE '%|UNREAD|%' THEN m.thread END),
              max(m.bulk), min(m.at), max(m.at),
              (SELECT n.thread FROM messages n WHERE lower(n.from_addr) = lower(m.from_addr) ORDER BY n.at DESC LIMIT 1)
            FROM messages m LEFT JOIN opened o ON o.thread = m.thread
            WHERE m.at > ? AND lower(m.from_addr) != ? AND m.labels NOT LIKE '%|SENT|%'
              AND m.labels NOT LIKE '%|TRASH|%' AND m.labels NOT LIKE '%|SPAM|%'
            GROUP BY lower(m.from_addr)
            """, [since.timeIntervalSince1970, me]).compactMap { row in
                guard let address = row[0] as? String, !address.isEmpty else { return nil }
                return Sender(address: address, name: row[1] as? String ?? "", threads: Int(row[2] as? Int64 ?? 0),
                              outUnopened: Int(row[3] as? Int64 ?? 0), opened: Int(row[4] as? Int64 ?? 0), list: (row[5] as? Int64 ?? 0) != 0,
                              thread: row[8] as? String ?? "", first: Date(timeIntervalSince1970: row[6] as? Double ?? 0),
                              last: Date(timeIntervalSince1970: row[7] as? Double ?? 0))
            }
        }
    }

    /// Cold pitches you answered since a moment (MailSense called them a
    /// pitch, no list's): the declines an offer counts (MailOffers).
    public func pitchesAnswered(since: Date) -> Int {
        queue.sync {
            Int(int("""
            SELECT count(DISTINCT s.thread) FROM sense s JOIN messages m ON m.thread = s.thread
            WHERE s.kind = 'promotion' AND m.labels LIKE '%|SENT|%' AND m.at > ?
              AND NOT EXISTS (SELECT 1 FROM messages b WHERE b.thread = s.thread AND b.bulk = 1)
            """, [since.timeIntervalSince1970]) ?? 0)
        }
    }

    /// A person's mail to you since a moment, newest first, `limit` of it,
    /// each with when you first answered in its thread after it: how soon
    /// you answer them. Only people who wrote at least `limit` times.
    public func answers(since: Date, limit: Int) -> [String: (name: String, waits: [TimeInterval?])] {
        queue.sync {
            let me = (meta("me") ?? "").lowercased()
            let who = strings("""
            SELECT lower(from_addr) FROM messages WHERE at > ? AND bulk = 0 AND lower(from_addr) != ? AND labels NOT LIKE '%|SENT|%'
            GROUP BY lower(from_addr) HAVING count(*) >= ?
            """, [since.timeIntervalSince1970, me, limit])
            var out: [String: (name: String, waits: [TimeInterval?])] = [:]
            for address in who.prefix(200) {
                let rows = query("""
                SELECT m.from_name, m.at, (SELECT min(s.at) FROM messages s WHERE s.thread = m.thread AND s.at > m.at AND s.labels LIKE '%|SENT|%')
                FROM messages m WHERE lower(m.from_addr) = ? AND m.at > ? AND m.labels NOT LIKE '%|SENT|%' ORDER BY m.at DESC LIMIT ?
                """, [address, since.timeIntervalSince1970, limit])
                let name = rows.first?[0] as? String ?? ""
                out[address] = (name, rows.map { row in (row[2] as? Double).map { $0 - (row[1] as? Double ?? 0) } })
            }
            return out
        }
    }

    // MARK: - replies written ahead

    /// The replies written for a thread's last message; none once another
    /// message came.
    public func ahead(_ thread: String, message: String) -> [String] {
        queue.sync { strings("SELECT body FROM ahead WHERE thread = ? AND message = ? ORDER BY n", [thread, message]) }
    }

    public func keepAhead(_ thread: String, message: String, replies: [String]) {
        queue.sync {
            run("DELETE FROM ahead WHERE thread = ?", [thread])
            for (n, body) in replies.enumerated() { run("INSERT INTO ahead(thread, message, n, body) VALUES(?,?,?,?)", [thread, message, n, body]) }
        }
    }

    /// Mail from an address, newest first: how they write (MailPeople).
    public func messages(from address: String, limit: Int) -> [MailMessage] {
        queue.sync {
            messages(where: "lower(m.from_addr) = ? AND m.labels NOT LIKE '%|SENT|%' ORDER BY m.at DESC LIMIT \(limit)", [address.lowercased()])
        }
    }

    /// Mail you sent to an address, newest first: how you write to them.
    public func sent(to address: String, limit: Int) -> [MailMessage] {
        queue.sync {
            messages(where: "m.labels LIKE '%|SENT|%' AND m.recipients LIKE ? ORDER BY m.at DESC LIMIT \(limit)", ["%" + address.lowercased() + "%"])
        }
    }

    // MARK: - snoozed

    public func snooze(_ snooze: MailSnooze) {
        queue.sync {
            generation += 1
            run("INSERT OR REPLACE INTO snoozes(thread, until, why, message, at) VALUES(?,?,?,?,?)",
                [snooze.thread, snooze.until?.timeIntervalSince1970 as Any, snooze.why, snooze.message, Date().timeIntervalSince1970])
        }
    }

    public func snoozes() -> [MailSnooze] {
        queue.sync {
            query("SELECT thread, until, why, message FROM snoozes ORDER BY until", []).compactMap { row in
                guard let thread = row[0] as? String else { return nil }
                return MailSnooze(thread: thread, until: (row[1] as? Double).map(Date.init(timeIntervalSince1970:)),
                                  why: row[2] as? String ?? "", message: row[3] as? String ?? "")
            }
        }
    }

    func unsnooze(_ thread: String) { queue.sync { generation += 1; run("DELETE FROM snoozes WHERE thread = ?", [thread]) } }

    /// A snooze taken to wake its thread, by whoever takes it first: the
    /// app and `yab mail flush` may both find it due, and only the one
    /// that took it wakes the thread. Nil when it is gone already.
    func takeSnooze(_ thread: String) -> MailSnooze? {
        queue.sync {
            guard let row = query("SELECT thread, until, why, message FROM snoozes WHERE thread = ?", [thread]).first else { return nil }
            run("DELETE FROM snoozes WHERE thread = ?", [thread])
            guard sqlite3_changes(db) == 1 else { return nil }
            return MailSnooze(thread: thread, until: (row[1] as? Double).map(Date.init(timeIntervalSince1970:)),
                              why: row[2] as? String ?? "", message: row[3] as? String ?? "")
        }
    }

    /// The last message someone else wrote in a thread: a new one wakes it.
    public func lastFromOthers(_ thread: String) -> String? {
        queue.sync {
            string("SELECT id FROM messages WHERE thread = ? AND from_addr != ? ORDER BY at DESC LIMIT 1", [thread, me])
        }
    }

    // MARK: - done waiting

    /// Done waiting on a thread as it stands (E in Waiting): kept against
    /// its last message, so the next one in it, theirs or yours, ends it.
    /// Only this Mac knows; by Gmail's own ids, so a sync from nothing
    /// keeps it.
    func stopWaiting(_ thread: String) {
        queue.sync {
            generation += 1
            guard let last = messages(where: "m.thread = ? ORDER BY m.at", [thread], bodies: false).last else { return }
            run("INSERT OR REPLACE INTO done_waiting(thread, message, at) VALUES(?,?,?)", [thread, last.id, Date().timeIntervalSince1970])
        }
    }

    /// Waiting on it again (⌘Z).
    func waitAgain(_ thread: String) { queue.sync { generation += 1; run("DELETE FROM done_waiting WHERE thread = ?", [thread]) } }

    // MARK: - muted

    /// Muted (⇧M), as it stands: kept against its last message, so what
    /// comes in it after is put away as it comes (MailOps.keepMuted). Gmail
    /// gives no mute of its own: this Mac keeps it, by Gmail's ids, and
    /// the thread wears yab/Muted there.
    public func mute(_ thread: String) {
        queue.sync {
            generation += 1
            let last = messages(where: "m.thread = ? ORDER BY m.at", [thread], bodies: false).last?.id ?? ""
            run("INSERT OR REPLACE INTO muted(thread, message, at) VALUES(?,?,?)", [thread, last, Date().timeIntervalSince1970])
        }
    }

    func unmute(_ thread: String) { queue.sync { generation += 1; run("DELETE FROM muted WHERE thread = ?", [thread]) } }

    /// Every muted thread here, newest first.
    public func mutedThreads(limit: Int = 300) -> [MailThread] {
        queue.sync {
            summaries(strings("SELECT thread FROM muted", [])).sorted { $0.last > $1.last }.prefix(limit).map { $0 }
        }
    }

    /// Mutes as Gmail has them under yab/Muted (`label`, its id): a thread
    /// carrying it that this Mac doesn't keep as muted was muted on another
    /// Mac, or before Yab was put on this one again, and is muted here too,
    /// against its newest mail that carries it (what came after is new in
    /// it, put away as it comes); one kept muted here that no mail of it
    /// carries any more, with no mute of its own still to tell Gmail, was
    /// unmuted elsewhere. What changed, for the lists.
    @discardableResult
    func readMutes(label: String) -> (muted: [String], unmuted: [String]) {
        queue.sync {
            let pattern = "%|" + label + "|%"
            let muted = strings("""
            SELECT DISTINCT m.thread FROM messages m WHERE m.labels LIKE ?
              AND NOT EXISTS (SELECT 1 FROM muted u WHERE u.thread = m.thread)
            """, [pattern])
            let unmuted = strings("""
            SELECT u.thread FROM muted u
            WHERE EXISTS (SELECT 1 FROM messages m WHERE m.thread = u.thread)
              AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.thread = u.thread AND m.labels LIKE ?)
              AND NOT EXISTS (SELECT 1 FROM ops o WHERE o.thread = u.thread AND o.kind IN ('mute', 'unmute'))
              AND NOT EXISTS (SELECT 1 FROM ops o JOIN packs p ON p.seq = o.seq WHERE p.thread = u.thread AND o.kind IN ('mute', 'unmute'))
            """, [pattern])
            guard !muted.isEmpty || !unmuted.isEmpty else { return ([], []) }
            generation += 1
            exec("BEGIN")
            let now = Date().timeIntervalSince1970
            for thread in muted {
                let last = string("SELECT id FROM messages WHERE thread = ? AND labels LIKE ? ORDER BY at DESC LIMIT 1", [thread, pattern]) ?? ""
                run("INSERT OR REPLACE INTO muted(thread, message, at) VALUES(?,?,?)", [thread, last, now])
            }
            for thread in unmuted { run("DELETE FROM muted WHERE thread = ?", [thread]) }
            exec("COMMIT")
            return (muted, unmuted)
        }
    }

    /// Muted threads that new mail came into, in the inbox now.
    func mutedArrivals() -> [String] {
        queue.sync {
            strings("""
            SELECT u.thread FROM muted u
            WHERE EXISTS (SELECT 1 FROM messages m WHERE m.thread = u.thread AND m.labels LIKE '%|INBOX|%')
              AND u.message != coalesce((SELECT id FROM messages WHERE thread = u.thread ORDER BY at DESC LIMIT 1), u.message)
            """, [])
        }
    }

    // MARK: - notified

    /// The mail a notification last said for each thread (MailNotify).
    public func notified() -> [String: String] {
        queue.sync {
            var out: [String: String] = [:]
            for row in query("SELECT thread, message FROM notified", []) {
                if let thread = row[0] as? String, let message = row[1] as? String { out[thread] = message }
            }
            return out
        }
    }

    /// Said, or passed over on purpose: not said again for that mail. Kept a
    /// week, long past the hour a mail counts as new.
    public func noteNotified(_ said: [(thread: String, message: String)]) {
        guard !said.isEmpty else { return }
        queue.sync {
            let now = Date().timeIntervalSince1970
            exec("BEGIN")
            for one in said { run("INSERT OR REPLACE INTO notified(thread, message, at) VALUES(?,?,?)", [one.thread, one.message, now]) }
            run("DELETE FROM notified WHERE at < ?", [now - 7 * 86_400])
            exec("COMMIT")
        }
    }

    // MARK: - reminders if nobody answers

    /// A thread's reminder set or moved (MailFollowups), one a thread.
    public func follow(_ followup: MailFollowup) {
        queue.sync {
            generation += 1
            run("INSERT OR REPLACE INTO followups(thread, message, until, sent, fired, at) VALUES(?,?,?,?,?,?)",
                [followup.thread, followup.message, followup.until.timeIntervalSince1970, followup.sent.timeIntervalSince1970,
                 followup.fired?.timeIntervalSince1970 as Any, Date().timeIntervalSince1970])
            following.insert(followup.thread)
        }
    }

    public func unfollow(_ thread: String) {
        queue.sync {
            generation += 1
            run("DELETE FROM followups WHERE thread = ?", [thread])
            following.remove(thread)
        }
    }

    public func followup(_ thread: String) -> MailFollowup? { queue.sync { followupRow(thread) } }

    /// Every reminder, soonest first.
    public func followups() -> [MailFollowup] {
        queue.sync {
            let all = query("SELECT thread, message, until, sent, fired FROM followups ORDER BY until", []).compactMap(followupRow)
            following = Set(all.map(\.thread))
            return all
        }
    }

    /// A reminder come due, marked so by whoever marks it first, the app or
    /// `yab mail flush`: false when the other did, or it isn't due.
    public func fire(_ thread: String, at now: Date) -> Bool {
        queue.sync {
            generation += 1
            run("UPDATE followups SET fired = ? WHERE thread = ? AND fired IS NULL AND until <= ?",
                [now.timeIntervalSince1970, thread, now.timeIntervalSince1970])
            return sqlite3_changes(db) == 1
        }
    }

    private func followupRow(_ thread: String) -> MailFollowup? {
        query("SELECT thread, message, until, sent, fired FROM followups WHERE thread = ?", [thread]).first.flatMap(followupRow)
    }

    private func followupRow(_ row: SQLiteRow) -> MailFollowup? {
        guard let thread = row[0] as? String, let until = row[2] as? Double, let sent = row[3] as? Double else { return nil }
        return MailFollowup(thread: thread, message: row[1] as? String ?? "", until: Date(timeIntervalSince1970: until),
                            sent: Date(timeIntervalSince1970: sent), fired: (row[4] as? Double).map(Date.init(timeIntervalSince1970:)))
    }

    // MARK: - nudges

    /// A nudge written for a thread you wait on (MailDrafts), while the
    /// mail it follows up is still the thread's last.
    public func nudge(_ thread: String) -> String? {
        queue.sync {
            string("""
            SELECT n.body FROM nudges n WHERE n.thread = ? AND n.body != ''
              AND n.message = (SELECT id FROM messages WHERE thread = n.thread ORDER BY at DESC LIMIT 1)
            """, [thread])
        }
    }

    /// When a nudge was last asked for a thread, and the mail it was for.
    public func nudged(_ thread: String) -> (message: String, at: Date)? {
        queue.sync {
            query("SELECT message, at FROM nudges WHERE thread = ?", [thread]).first.map { row in
                (row[0] as? String ?? "", Date(timeIntervalSince1970: row[1] as? Double ?? 0))
            }
        }
    }

    /// A nudge asked for now, for a thread's last mail: a day before the
    /// next, whatever comes back.
    public func nudging(_ thread: String, message: String, at now: Date) {
        queue.sync {
            run("""
            INSERT INTO nudges(thread, message, body, at) VALUES(?, ?, '', ?)
            ON CONFLICT(thread) DO UPDATE SET at = excluded.at
            """, [thread, message, now.timeIntervalSince1970])
        }
    }

    public func keepNudge(_ thread: String, message: String, body: String) {
        queue.sync { run("UPDATE nudges SET message = ?, body = ? WHERE thread = ?", [message, body, thread]) }
    }

    // MARK: - invitations

    /// An invitation a message carries, kept as it came, by its UID and
    /// SEQUENCE: at the sync, when the message's parts held its words, or
    /// once fetched as a file when the thread is opened (MailInvites).
    public func keepInvite(message: String, thread: String, at: Date, ics: String) {
        queue.sync {
            keepingInvite(message, thread: thread, at: at, ics: ics)
            // The splits read it (Calendar): what they keep of the mail moves.
            content += 1
            generation += 1
        }
    }

    /// Threads carrying an invitation this Mac read, of these or of all
    /// kept: the Calendar split's, beside what MailSense reads as a meeting.
    public func invited(among ids: [String]?) -> Set<String> {
        queue.sync {
            guard inviting else { return [] }
            let all = Set(strings("SELECT DISTINCT thread FROM invites", []))
            return ids.map { all.intersection($0) } ?? all
        }
    }

    /// When each of these threads' invitation meets next: the newest one
    /// kept of each, not called off and not over (a series at its next
    /// occurrence), for its row to say. Answers (REPLY) ask nothing.
    public func meets(among ids: [String], now: Date = Date()) -> [String: (start: Date, allDay: Bool)] {
        queue.sync {
            let wanted = Array(Set(ids.filter { !$0.isEmpty }))
            guard inviting, !wanted.isEmpty else { return [:] }
            var newest: [String: String] = [:]
            for start in stride(from: 0, to: wanted.count, by: 500) {
                let chunk = Array(wanted[start..<min(wanted.count, start + 500)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                for row in query("SELECT thread, ics FROM invites WHERE thread IN (\(marks)) AND method != 'REPLY' ORDER BY at", chunk) {
                    if let thread = row[0] as? String, let ics = row[1] as? String { newest[thread] = ics }
                }
            }
            var out: [String: (start: Date, allDay: Bool)] = [:]
            for (thread, ics) in newest {
                guard let invite = MailInvite.parse(ics), !invite.canceled else { continue }
                let next = invite.next(after: now)
                guard next.end > now else { continue }
                out[thread] = (next.start, invite.allDay)
            }
            return out
        }
    }

    private func keepingInvite(_ message: String, thread: String, at: Date, ics: String) {
        guard inviting, let invite = MailInvite.parse(ics) else { return }
        run("INSERT OR REPLACE INTO invites(message, thread, uid, sequence, method, ics, at) VALUES(?,?,?,?,?,?,?)",
            [message, thread, invite.uid, invite.sequence, invite.method, ics, at.timeIntervalSince1970])
    }

    /// Every invitation kept of one event, oldest first: what came before
    /// an update, and answers to it (REPLY), with who sent each.
    public func invites(uid: String) -> [(message: String, from: String, at: Date, ics: String)] {
        queue.sync {
            guard inviting else { return [] }
            return query("""
            SELECT i.message, coalesce(m.from_addr, ''), i.at, i.ics FROM invites i LEFT JOIN messages m ON m.id = i.message
            WHERE i.uid = ? ORDER BY i.sequence, i.at
            """, [uid]).compactMap { row in
                guard let message = row[0] as? String, let ics = row[3] as? String else { return nil }
                return (message, row[1] as? String ?? "", Date(timeIntervalSince1970: row[2] as? Double ?? 0), ics)
            }
        }
    }

    /// Your answer to an invitation, by the draft whose mail carries it:
    /// waiting for its undo, gone, or taken back (then dropped).
    public func keep(_ rsvp: MailRSVP) {
        queue.sync {
            guard inviting else { return }
            run("INSERT OR REPLACE INTO rsvps(draft, uid, recurrence, sequence, answer, message, ics, at) VALUES(?,?,?,?,?,?,?,?)",
                [rsvp.draft, rsvp.uid, rsvp.recurrence, rsvp.sequence, rsvp.answer.rawValue, rsvp.message, rsvp.ics, rsvp.at.timeIntervalSince1970])
        }
    }

    public func dropRSVP(draft: String) { queue.sync { if inviting { run("DELETE FROM rsvps WHERE draft = ?", [draft]) } } }

    /// The iCalendar REPLY a draft's mail carries, for the send (MailOps).
    public func rsvp(draft: String) -> MailRSVP? {
        queue.sync { rsvps("draft = ?", [draft]).first }
    }

    /// Your newest answer to an event (or to one occurrence of it).
    public func rsvp(uid: String, recurrence: String = "") -> MailRSVP? {
        queue.sync { rsvps("uid = ? AND recurrence = ? ORDER BY at DESC LIMIT 1", [uid, recurrence]).first }
    }

    private func rsvps(_ clause: String, _ args: [Any]) -> [MailRSVP] {
        guard inviting else { return [] }
        return query("SELECT draft, uid, recurrence, sequence, answer, message, ics, at FROM rsvps WHERE " + clause, args).compactMap { row in
            guard let draft = row[0] as? String, let answer = (row[4] as? String).flatMap(MailInvite.Answer.init(rawValue:)) else { return nil }
            return MailRSVP(draft: draft, uid: row[1] as? String ?? "", recurrence: row[2] as? String ?? "", sequence: Int(row[3] as? Int64 ?? 0),
                            answer: answer, message: row[5] as? String ?? "", ics: row[6] as? String ?? "",
                            at: Date(timeIntervalSince1970: row[7] as? Double ?? 0))
        }
    }

    /// Threads whose last word is an answer of yours to an invitation (an
    /// iCalendar REPLY, sent from here or from anywhere): no thread you
    /// wait on. Done waiting on, against that mail, so a mail after it
    /// waits again as any does. How many it marked.
    @discardableResult
    func settleAnswers() -> Int {
        queue.sync {
            guard inviting, tallied, !me.isEmpty else { return 0 }
            run("""
            INSERT OR REPLACE INTO done_waiting(thread, message, at)
              SELECT t.id, t.last_id, ? FROM threads t JOIN invites i ON i.message = t.last_id
              WHERE i.method = 'REPLY' AND t.last_from = ?
                AND NOT EXISTS (SELECT 1 FROM done_waiting d WHERE d.thread = t.id AND d.message = t.last_id)
            """, [Date().timeIntervalSince1970, me])
            let changed = Int(sqlite3_changes(db))
            if changed > 0 { generation += 1 }
            return changed
        }
    }

    // MARK: - cleanup

    /// A sender kept out (Block Sender): an address, or a domain and every
    /// one under it (MailBlock), since then. The person's, so a reset keeps it.
    public func block(_ who: String, at: Date = Date()) {
        queue.sync { run("INSERT OR IGNORE INTO blocked(who, at) VALUES(?,?)", [who, at.timeIntervalSince1970]) }
    }

    public func unblock(_ who: String) { queue.sync { run("DELETE FROM blocked WHERE who = ?", [who]) } }

    /// Every sender kept out, the newest first.
    /// Senders unsubscribed from since a moment, for Yab Wrapped.
    public func unsubscribedCount(since: Date) -> Int {
        queue.sync {
            (query("SELECT COUNT(*) FROM unsubscribed WHERE at >= ?", [since.timeIntervalSince1970]).first?.first as? Int64).map(Int.init) ?? 0
        }
    }

    public func blocked() -> [(who: String, at: Date)] {
        queue.sync {
            query("SELECT who, at FROM blocked ORDER BY at DESC", []).compactMap { row in
                guard let who = row[0] as? String else { return nil }
                return (who, Date(timeIntervalSince1970: row[1] as? Double ?? 0))
            }
        }
    }

    /// Mail in the inbox from a sender kept out, come since they were: what
    /// MailOps.keepBlocked puts in Trash. An address is its own; a domain
    /// is every address at it or under it, never one that merely ends the
    /// same way. Never your own mail.
    func blockedArrivals() -> [String] {
        queue.sync {
            strings("""
            SELECT DISTINCT m.id FROM messages m JOIN blocked b
              ON (instr(b.who, '@') > 0 AND m.from_addr = b.who)
              OR (instr(b.who, '@') = 0 AND (m.from_addr LIKE '%@' || b.who OR m.from_addr LIKE '%.' || b.who))
            WHERE m.at > b.at AND m.labels LIKE '%|INBOX|%' AND m.from_addr != ?
            """, [me])
        }
    }

    /// A list left with ⌘U, by its sender's address: how (MailUnsubscribe.Way's
    /// name) and when.
    public func unsubscribed(_ sender: String, how: String, at: Date = Date()) {
        queue.sync {
            run("INSERT OR REPLACE INTO unsubscribed(sender, how, at) VALUES(?,?,?)", [sender.lowercased(), how, at.timeIntervalSince1970])
        }
    }

    public func unsubscribed(from sender: String) -> (how: String, at: Date)? {
        queue.sync {
            query("SELECT how, at FROM unsubscribed WHERE sender = ?", [sender.lowercased()]).first.map { row in
                (row[0] as? String ?? "", Date(timeIntervalSince1970: row[1] as? Double ?? 0))
            }
        }
    }

    /// Threads in the inbox as Get Me To Zero weighs them, newest first: the
    /// time of their newest mail, and whether any of it is unread or starred.
    /// From `threads` where the store keeps it, the whole inbox in one look.
    public func inboxThreads() -> [(thread: String, last: Date, unread: Bool, starred: Bool)] {
        queue.sync {
            query(tallied
                ? "SELECT id, last, unread, starred FROM threads WHERE inbox = 1 ORDER BY last DESC"
                : """
                  SELECT thread, max(at), max(labels LIKE '%|UNREAD|%'), max(labels LIKE '%|STARRED|%') FROM messages
                  GROUP BY thread HAVING max(labels LIKE '%|INBOX|%') = 1 ORDER BY max(at) DESC
                  """, []).compactMap { row in
                guard let thread = row[0] as? String else { return nil }
                return (thread, Date(timeIntervalSince1970: row[1] as? Double ?? 0), (row[2] as? Int64 ?? 0) != 0, (row[3] as? Int64 ?? 0) != 0)
            }
        }
    }

    /// Threads in the inbox someone wrote in, newest first: everything from
    /// a sender, after ⌘U or Block Sender.
    public func inboxThreads(from address: String) -> [String] {
        queue.sync {
            strings("""
            SELECT thread FROM messages GROUP BY thread
            HAVING max(labels LIKE '%|INBOX|%') = 1 AND max(from_addr = ?) = 1 ORDER BY max(at) DESC
            """, [address.lowercased()])
        }
    }

    /// The messages of these threads here, each with its thread and whether
    /// it is in the inbox: what a Bulk Actions entry keeps.
    public func messages(of threads: [String]) -> [(id: String, thread: String, inbox: Bool)] {
        queue.sync {
            var out: [(String, String, Bool)] = []
            for start in stride(from: 0, to: threads.count, by: 500) {
                let chunk = Array(threads[start..<min(threads.count, start + 500)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                for row in query("SELECT id, thread, labels LIKE '%|INBOX|%' FROM messages WHERE thread IN (\(marks)) ORDER BY at", chunk) {
                    guard let id = row[0] as? String, let thread = row[1] as? String else { continue }
                    out.append((id, thread, (row[2] as? Int64 ?? 0) != 0))
                }
            }
            return out
        }
    }

    /// Labels of messages by their ids, those kept here.
    public func labels(of ids: [String]) -> [String: Set<String>] {
        queue.sync {
            var out: [String: Set<String>] = [:]
            for start in stride(from: 0, to: ids.count, by: 500) {
                let chunk = Array(ids[start..<min(ids.count, start + 500)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                for row in query("SELECT id, labels FROM messages WHERE id IN (\(marks))", chunk) {
                    if let id = row[0] as? String { out[id] = MailStore.labels(row[1] as? String ?? "") }
                }
            }
            return out
        }
    }

    /// An entry of the Bulk Actions log (MailBulk) and the messages it moved,
    /// `inbox` those it took out of the inbox, in one transaction.
    @discardableResult
    func logBulk(_ kind: String, said: String, threads: Int, messages: [(id: String, thread: String, inbox: Bool)], at: Date = Date()) -> Int64 {
        queue.sync {
            exec("BEGIN")
            run("INSERT INTO bulk(kind, said, threads, at) VALUES(?,?,?,?)", [kind, said, threads, at.timeIntervalSince1970])
            let id = sqlite3_last_insert_rowid(db)
            for m in messages {
                run("INSERT OR IGNORE INTO bulk_messages(bulk, message, thread, inbox) VALUES(?,?,?,?)", [id, m.id, m.thread, m.inbox ? 1 : 0])
            }
            exec("COMMIT")
            return id
        }
    }

    /// The log's entries since a moment, newest first.
    public func bulks(since: Date) -> [MailBulk] {
        queue.sync {
            query("SELECT id, kind, said, threads, at, back FROM bulk WHERE at >= ? ORDER BY at DESC, id DESC", [since.timeIntervalSince1970])
                .compactMap(bulkRow)
        }
    }

    public func bulk(_ id: Int64) -> MailBulk? {
        queue.sync { query("SELECT id, kind, said, threads, at, back FROM bulk WHERE id = ?", [id]).first.flatMap(bulkRow) }
    }

    private func bulkRow(_ row: SQLiteRow) -> MailBulk? {
        guard let id = row[0] as? Int64, let kind = (row[1] as? String).flatMap(MailBulk.Kind.init) else { return nil }
        return MailBulk(id: id, kind: kind, said: row[2] as? String ?? "", threads: Int(row[3] as? Int64 ?? 0),
                        at: Date(timeIntervalSince1970: row[4] as? Double ?? 0), back: (row[5] as? Double).map(Date.init(timeIntervalSince1970:)))
    }

    func bulkMessages(_ id: Int64) -> [(id: String, thread: String, inbox: Bool)] {
        queue.sync {
            query("SELECT message, thread, inbox FROM bulk_messages WHERE bulk = ? ORDER BY rowid", [id]).compactMap { row in
                guard let message = row[0] as? String, let thread = row[1] as? String else { return nil }
                return (message, thread, (row[2] as? Int64 ?? 0) != 0)
            }
        }
    }

    /// An entry taken back then, or not after all (nil).
    public func bulkBack(_ id: Int64, at: Date?) {
        queue.sync { run("UPDATE bulk SET back = ? WHERE id = ?", [at?.timeIntervalSince1970 as Any, id]) }
    }

    /// Entries older than the log keeps, gone with their messages.
    func forgetBulks(before: Date) {
        queue.sync {
            run("DELETE FROM bulk_messages WHERE bulk IN (SELECT id FROM bulk WHERE at < ?)", [before.timeIntervalSince1970])
            run("DELETE FROM bulk WHERE at < ?", [before.timeIntervalSince1970])
        }
    }

    // MARK: - splits

    /// Threads Skip the inbox archived as their mail came (MailSkip), each
    /// against that mail and its split, then.
    public func skip(_ items: [(thread: String, message: String, split: String)], at: Date) {
        guard !items.isEmpty, peopled else { return }
        queue.sync {
            exec("BEGIN")
            for item in items {
                run("INSERT OR REPLACE INTO skipped(thread, message, split, at, back) VALUES(?,?,?,?,NULL)",
                    [item.thread, item.message, item.split, at.timeIntervalSince1970])
            }
            exec("COMMIT")
        }
    }

    /// The mail each of these threads was archived with as it came, by
    /// thread: an arrival is archived once, whatever is done to it after.
    public func skippedMessages(_ threads: [String]) -> [String: String] {
        guard !threads.isEmpty, peopled else { return [:] }
        return queue.sync {
            var out: [String: String] = [:]
            for start in stride(from: 0, to: threads.count, by: 400) {
                let chunk = Array(threads[start..<min(threads.count, start + 400)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                for row in query("SELECT thread, message FROM skipped WHERE thread IN (\(marks))", chunk) {
                    if let thread = row[0] as? String, let message = row[1] as? String { out[thread] = message }
                }
            }
            return out
        }
    }

    /// Threads Skip the inbox archived since a moment, newest first, with
    /// their split and when: not taken back, and out of the inbox still.
    public func skipped(since: Date) -> [(thread: String, split: String, at: Date)] {
        guard peopled else { return [] }
        return queue.sync {
            query("""
            SELECT s.thread, s.split, s.at FROM skipped s LEFT JOIN threads t ON t.id = s.thread
            WHERE s.at >= ? AND s.back IS NULL AND coalesce(t.inbox, 0) = 0 ORDER BY s.at DESC
            """, [since.timeIntervalSince1970]).compactMap { row in
                guard let thread = row[0] as? String, let split = row[1] as? String else { return nil }
                return (thread, split, Date(timeIntervalSince1970: row[2] as? Double ?? 0))
            }
        }
    }

    /// Taken back (⌘Z): no longer said as archived as it came.
    public func unskip(_ threads: [String], at: Date = Date()) {
        guard !threads.isEmpty, peopled else { return }
        queue.sync {
            let marks = Array(repeating: "?", count: threads.count).joined(separator: ",")
            run("UPDATE skipped SET back = ? WHERE thread IN (\(marks))", [at.timeIntervalSince1970] + threads)
        }
    }

    /// A thread's senders but you, as `threads` keeps them ("|a@x|b@y|").
    public func people(of thread: String) -> String {
        guard peopled else { return "" }
        return queue.sync { string("SELECT people FROM threads WHERE id = ?", [thread]) ?? "" }
    }

    /// You have written to them: mail of yours with the address in its To
    /// or Cc. What Skip the inbox never archives mail from.
    public func wroteTo(_ address: String) -> Bool {
        let who = address.lowercased()
        guard who.contains("@") else { return false }
        return queue.sync {
            guard !me.isEmpty else { return false }
            return int("SELECT 1 FROM messages WHERE from_addr = ? AND (instr(recipients, ?) > 0 OR instr(cc, ?) > 0) LIMIT 1",
                       [me, who, who]) != nil
        }
    }

    /// Threads with mail a search answers here (MailQuery.local), as its
    /// terms ask: a split's words or its search. Among `ids` when given.
    /// Nil when the store can't tell (MailQuery.answerable).
    public func threads(answering asked: MailQuery, among ids: [String]? = nil, now: Date = Date()) -> Set<String>? {
        queue.sync {
            guard let local = asked.local(me: me, labels: { label($0) }, now: now) else { return nil }
            guard let ids else { return Set(strings("SELECT DISTINCT m.thread FROM messages m WHERE \(local.sql)", local.args)) }
            var out = Set<String>()
            for start in stride(from: 0, to: ids.count, by: 400) {
                let chunk = Array(ids[start..<min(ids.count, start + 400)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                out.formUnion(strings("SELECT DISTINCT m.thread FROM messages m WHERE (\(local.sql)) AND m.thread IN (\(marks))", local.args + chunk))
            }
            return out
        }
    }

    /// Threads with mail sent to any of these, an address or everyone at a
    /// domain and under it: your own mail (`mine`, a split's to:), or
    /// anyone's (with:). Among `ids` when given.
    public func threads(to who: [String], mine: Bool, among ids: [String]? = nil) -> Set<String> {
        let needles = who.map { $0.lowercased() }.flatMap { $0.contains("@") ? [$0] : ["@" + $0, "." + $0] }
        guard !needles.isEmpty else { return [] }
        let found = needles.map { _ in "instr(m.recipients, ?) > 0 OR instr(m.cc, ?) > 0" }.joined(separator: " OR ")
        let needleArgs: [Any] = needles.flatMap { [$0, $0] }
        return queue.sync {
            let clause = (mine ? "m.from_addr = ? AND " : "") + "(\(found))"
            let args: [Any] = (mine ? [me] : []) + needleArgs
            guard let ids else { return Set(strings("SELECT DISTINCT m.thread FROM messages m WHERE \(clause)", args)) }
            var out = Set<String>()
            for start in stride(from: 0, to: ids.count, by: 400) {
                let chunk = Array(ids[start..<min(ids.count, start + 400)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                out.formUnion(strings("SELECT DISTINCT m.thread FROM messages m WHERE (\(clause)) AND m.thread IN (\(marks))", args + chunk))
            }
            return out
        }
    }

    // MARK: - search

    /// Threads a search finds here, newest first (MailQuery): words, or
    /// Gmail's operators.
    public func search(_ words: String, limit: Int = 30) -> [MailThread] { find(MailQuery.parse(words), limit: limit).threads }

    /// What a search finds here (`find`).
    public struct Found {
        /// The newest threads it finds, as a list shows them.
        public var threads: [MailThread] = []
        /// How many threads it finds in all.
        public var total = 0
        /// Of the threads asked about (`among`), those it finds.
        public var among: Set<String> = []
        /// False when the store can't tell: a term only Gmail can answer
        /// makes the whole search Gmail's, and nothing is found here.
        public var answered = true
    }

    /// What a search finds here: its newest `limit` threads and how many in
    /// all, in one pass over the index; and which of `among` (threads Gmail
    /// named) it finds too.
    public func find(_ query: MailQuery, limit: Int = 30, among: [String] = [], now: Date = Date()) -> Found {
        queue.sync {
            guard !query.isEmpty else { return Found() }
            readAgain()
            guard let local = query.local(me: me, labels: { label($0) }, now: now) else { return Found(answered: false) }
            if tallied, let words = local.words { return found(words, limit: limit, among: among) }
            let rows = tallied
                ? self.query("""
                  SELECT t.id, count(*) OVER () FROM threads t WHERE t.id IN (SELECT m.thread FROM messages m WHERE \(local.sql))
                  ORDER BY t.last DESC LIMIT ?
                  """, local.args + [limit])
                : self.query("""
                  SELECT m.thread, count(*) OVER () FROM messages m WHERE \(local.sql) GROUP BY m.thread ORDER BY max(m.at) DESC LIMIT ?
                  """, local.args + [limit])
            let ids = rows.compactMap { $0.first as? String }
            var found = Found(threads: summaries(ids), total: Int(rows.first?[1] as? Int64 ?? 0))
            if !among.isEmpty {
                // All it finds is on the page: no need to ask again.
                if found.total <= ids.count {
                    found.among = Set(ids).intersection(among)
                } else {
                    let marks = Array(repeating: "?", count: among.count).joined(separator: ",")
                    found.among = Set(strings("SELECT DISTINCT m.thread FROM messages m WHERE (\(local.sql)) AND m.thread IN (\(marks))",
                                              local.args + among))
                }
            }
            return found
        }
    }

    /// Words alone, the search typed most (a letter at a time): the index's
    /// rowids, each its message's thread by the map (`threadMap`), the
    /// threads newest first. A word of one letter finds most of a mailbox,
    /// and reading each message it found for its thread took longer than
    /// the index did. Inside the store's queue.
    private func found(_ words: String, limit: Int, among: [String]) -> Found {
        let map = threadMap()
        var seen = [Bool](repeating: false, count: map.order.count)
        var places: [Int32] = []
        if let statement = prepare("SELECT rowid FROM words WHERE words MATCH ?", [words]) {
            while sqlite3_step(statement) == SQLITE_ROW {
                let rowid = Int(sqlite3_column_int64(statement, 0))
                guard rowid >= 0, rowid < map.thread.count else { continue }
                let place = map.thread[rowid]
                if place >= 0, !seen[Int(place)] {
                    seen[Int(place)] = true
                    places.append(place)
                }
            }
            sqlite3_finalize(statement)
        }
        // Newest first: a thread's place is its rank by its newest mail.
        places.sort()
        let ids = places.prefix(limit).map { map.order[Int($0)] }
        var out = Found(threads: summaries(ids), total: places.count)
        out.among = Set(among.filter { id in map.places[id].map { seen[Int($0)] } ?? false })
        return out
    }

    /// Each message's thread by the message's rowid (the word index's
    /// key), as its place among the threads newest first, -1 for mail in
    /// Trash or Spam; made again once the mail changed (`mailChanged`),
    /// here or by another process.
    private struct ThreadMap {
        public var version: String
        public var thread: [Int32]
        public var order: [String]
        public var places: [String: Int32]
    }
    private var threadMapKept: ThreadMap?
    /// How many times the map was made, for tests.
    private(set) var mapsMade = 0

    private func threadMap() -> ThreadMap {
        // Read before the mail is: a change while it is read makes it again next time.
        let version = meta("mail-version") ?? ""
        if let kept = threadMapKept, kept.version == version { return kept }
        mapsMade += 1
        var order: [String] = []
        var places: [String: Int32] = [:]
        var byRow: [Int64: Int32] = [:]
        if let statement = prepare("SELECT rowid, id FROM threads ORDER BY last DESC", []) {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let text = sqlite3_column_text(statement, 1) else { continue }
                let place = Int32(order.count)
                let id = String(cString: text)
                order.append(id)
                places[id] = place
                byRow[sqlite3_column_int64(statement, 0)] = place
            }
            sqlite3_finalize(statement)
        }
        let top = Int(int("SELECT max(rowid) FROM messages", []) ?? 0)
        var thread = [Int32](repeating: -1, count: top + 1)
        if let statement = prepare("""
            SELECT m.rowid, t.rowid FROM messages m JOIN threads t ON t.id = m.thread
            WHERE instr(m.labels, '|TRASH|') = 0 AND instr(m.labels, '|SPAM|') = 0
            """, []) {
            while sqlite3_step(statement) == SQLITE_ROW {
                let rowid = Int(sqlite3_column_int64(statement, 0))
                guard rowid >= 0, rowid <= top, let place = byRow[sqlite3_column_int64(statement, 1)] else { continue }
                thread[rowid] = place
            }
            sqlite3_finalize(statement)
        }
        let made = ThreadMap(version: version, thread: thread, order: order, places: places)
        threadMapKept = made
        return made
    }

    /// Which of these messages are here.
    public func known(_ ids: [String]) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        return queue.sync {
            var out = Set<String>()
            for start in stride(from: 0, to: ids.count, by: 400) {
                let chunk = Array(ids[start..<min(ids.count, start + 400)])
                out.formUnion(strings("SELECT id FROM messages WHERE id IN (\(Array(repeating: "?", count: chunk.count).joined(separator: ",")))", chunk))
            }
            return out
        }
    }

    // MARK: - labels

    /// A label of yours by its name, as Gmail's list gave it (`keepLabels`)
    /// or an op made it (yab/Snoozed): its id, or nil when not known here.
    /// Gmail's search reads a space, a slash and a dash in a name alike.
    public func labelID(named name: String) -> String? { queue.sync { label(name) } }

    /// A label of yours by its name as it is written, case aside, as Gmail
    /// keeps names apart: "Work-Clients" isn't "Work/Clients" here. What L
    /// and V put on mail, and make at Gmail when it isn't there.
    public func labelID(exactly name: String) -> String? { queue.sync { exactLabel(name) } }

    private func label(_ name: String) -> String? {
        if let exact = exactLabel(name) { return exact }
        let wanted = MailStore.labelKey(name)
        if labeling {
            for row in query("SELECT id, name FROM labels WHERE type = 'user'", []) {
                guard let id = row[0] as? String, let named = row[1] as? String else { continue }
                if MailStore.labelKey(named) == wanted { return id }
            }
        }
        // Learned before the store kept labels of its own.
        for row in query("SELECT k, v FROM meta WHERE k LIKE 'label:%'", []) {
            guard let key = row[0] as? String, let id = row[1] as? String else { continue }
            if MailStore.labelKey(String(key.dropFirst(6))) == wanted { return id }
        }
        return nil
    }

    private func exactLabel(_ name: String) -> String? {
        if labeling, let id = string("SELECT id FROM labels WHERE name = ? COLLATE NOCASE AND type = 'user'", [name]) { return id }
        return string("SELECT v FROM meta WHERE k = ? COLLATE NOCASE", ["label:" + name])
    }

    private static func labelKey(_ name: String) -> String {
        MailQuery.fold(name).map { " /-_".contains($0) ? "-" : String($0) }.joined()
    }

    /// The labels of yours Gmail listed, by name, for searches to name them:
    /// each learned or renamed, none let go (`keepLabels` does that).
    public func learn(labels: [(id: String, name: String)]) {
        queue.sync {
            for label in labels where label.id.hasPrefix("Label_") {
                guard labeling else { setMeta("label:" + label.name, label.id); continue }
                run("""
                INSERT INTO labels(id, name, type) VALUES(?, ?, 'user') ON CONFLICT(id) DO UPDATE SET name = excluded.name
                """, [label.id, label.name])
                labelIDs.insert(label.id)
            }
        }
    }

    /// Gmail's whole list of labels (labels.list): new ones in, a rename or
    /// a color as Gmail has it now; one no longer there gone, and off every
    /// message it was on (a label deleted in Gmail leaves its mail), with any
    /// op still to tell Gmail of it. Their counts stay. The ids that went.
    @discardableResult
    public func keepLabels(_ listed: [MailLabel]) -> [String] {
        // Gmail's list always has its own labels: none at all is no answer.
        guard !listed.isEmpty else { return [] }
        return queue.sync {
            guard labeling else {
                for label in listed where label.user { setMeta("label:" + label.name, label.id) }
                return []
            }
            exec("BEGIN")
            let now = Set(listed.map(\.id))
            let gone = labelIDs.subtracting(now).filter { $0.hasPrefix("Label_") }
            for label in listed {
                run("""
                INSERT INTO labels(id, name, type, color, text_color, shown) VALUES(?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, type = excluded.type, color = excluded.color,
                  text_color = excluded.text_color, shown = excluded.shown
                """, [label.id, label.name, label.type, label.color, label.textColor, label.shown])
            }
            for id in gone { strip(id) }
            // Names learned before, in meta: the list says them now.
            run("DELETE FROM meta WHERE k LIKE 'label:%'", [])
            exec("COMMIT")
            labelIDs = now
            return gone.sorted()
        }
    }

    /// A label gone from Gmail, gone here: off every message (their threads
    /// counted again), and nothing left to tell Gmail of it. In the queue.
    private func strip(_ id: String) {
        run("DELETE FROM labels WHERE id = ?", [id])
        let mark = "|" + id + "|"
        let threads = strings("SELECT DISTINCT thread FROM messages WHERE instr(labels, ?) > 0", [mark])
        if !threads.isEmpty {
            run("UPDATE messages SET labels = CASE WHEN labels = ? THEN '' ELSE replace(labels, ?, '|') END WHERE instr(labels, ?) > 0",
                [mark, mark, mark])
            tally(Set(threads))
        }
        run("DELETE FROM packs WHERE seq IN (SELECT seq FROM ops WHERE label = ?)", [id])
        run("DELETE FROM pack_messages WHERE seq IN (SELECT seq FROM ops WHERE label = ?)", [id])
        run("DELETE FROM ops WHERE label = ?", [id])
    }

    /// A label made here (L's Create, an op's yab/Snoozed): kept at once.
    public func keep(label: MailLabel) {
        queue.sync {
            guard labeling else { return setMeta("label:" + label.name, label.id) }
            run("""
            INSERT INTO labels(id, name, type, color, text_color, shown) VALUES(?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name
            """, [label.id, label.name, label.type, label.color, label.textColor, label.shown])
            labelIDs.insert(label.id)
        }
    }

    /// The mailbox's labels, Gmail's and yours, by name, with their counts
    /// as labels.get last said them.
    public func labels() -> [MailLabel] {
        guard labeling else { return [] }
        return queue.sync {
            query("SELECT id, name, type, color, text_color, shown, unread, threads FROM labels ORDER BY name", []).compactMap { row in
                guard let id = row[0] as? String, let name = row[1] as? String else { return nil }
                return MailLabel(id: id, name: name, type: row[2] as? String ?? "user", color: row[3] as? String ?? "",
                                 textColor: row[4] as? String ?? "", shown: row[5] as? String ?? "labelShow",
                                 unread: (row[6] as? Int64).map(Int.init), threads: (row[7] as? Int64).map(Int.init))
            }
        }
    }

    /// Whether a label id is one the store knows: mail carrying one it
    /// doesn't has Gmail's list asked at once (MailSync.keepLabels).
    func knowsLabel(_ id: String) -> Bool { queue.sync { labelIDs.contains(id) } }

    /// A label's counts, as labels.get said them now.
    public func count(label id: String, unread: Int, threads: Int, at: Date = Date()) {
        guard labeling else { return }
        queue.sync { run("UPDATE labels SET unread = ?, threads = ?, counted = ? WHERE id = ?", [unread, threads, at.timeIntervalSince1970, id]) }
    }

    /// Labels whose mail changed (a sync, an op Gmail heard): their counts
    /// are asked again the next time they are shown.
    func staleLabels(_ ids: Set<String>) {
        guard labeling, !ids.isEmpty else { return }
        queue.sync {
            for id in ids where labelIDs.contains(id) { run("UPDATE labels SET counted = NULL WHERE id = ?", [id]) }
        }
    }

    /// Of these labels, those whose counts want asking: never asked, changed
    /// since, or asked before `before`. In the order given.
    func uncounted(_ ids: [String], before: Date) -> [String] {
        guard labeling, !ids.isEmpty else { return [] }
        return queue.sync {
            let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let fresh = Set(strings("SELECT id FROM labels WHERE id IN (\(marks)) AND counted >= ?", ids + [before.timeIntervalSince1970]))
            return ids.filter { labelIDs.contains($0) && !fresh.contains($0) }
        }
    }

    /// A list beyond the inbox's, a page at a time (MailDesk.viewThreads):
    /// threads with `label` on a message of theirs (nil: any thread), none
    /// of `without` on the messages read, and, `others`, someone else's mail
    /// in them; newest first, the first `limit`, and how many in all, in one
    /// pass. Sent by `threads`, where the store keeps it.
    public func view(label: String?, without: [String] = [], others: Bool = false, limit: Int) -> (threads: [MailThread], total: Int) {
        queue.sync {
            let rows: [SQLiteRow]
            if tallied, label == "SENT", without == ["TRASH"], !others {
                rows = query("SELECT id, count(*) OVER () FROM threads WHERE sent = 1 AND gone = 0 ORDER BY last DESC LIMIT ?", [limit])
            } else {
                let having = without.map { "max(instr(labels, '|\($0)|') > 0) = 0" } + (others ? ["max(from_addr != ?) = 1"] : [])
                rows = query("""
                SELECT thread, count(*) OVER () FROM messages \(label == nil ? "" : "WHERE instr(labels, ?) > 0")
                GROUP BY +thread \(having.isEmpty ? "" : "HAVING " + having.joined(separator: " AND ")) ORDER BY max(at) DESC LIMIT ?
                """, (label.map { ["|" + $0 + "|"] } ?? []) + (others ? [me] : []) + [limit])
            }
            return (summaries(rows.compactMap { $0.first as? String }), Int(rows.first?[1] as? Int64 ?? 0))
        }
    }

    // MARK: - bodies kept

    /// A thread opened, by you or an agent: its bodies stay here (`prune`).
    public func opened(_ thread: String, at: Date = Date()) {
        guard tallied else { return }
        queue.sync { run("INSERT OR REPLACE INTO opened(thread, at) VALUES(?, ?)", [thread, at.timeIntervalSince1970]) }
    }

    /// Of these threads, those with a message whose body isn't here, each
    /// with those messages, in the order asked.
    func unbodied(_ threads: [String]) -> [(thread: String, messages: [String])] {
        guard !threads.isEmpty else { return [] }
        return queue.sync {
            var by: [String: [String]] = [:]
            for start in stride(from: 0, to: threads.count, by: 400) {
                let chunk = Array(threads[start..<min(threads.count, start + 400)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                for row in query("""
                SELECT m.thread, m.id FROM messages m LEFT JOIN bodies b ON b.id = m.id
                WHERE b.id IS NULL AND m.thread IN (\(marks)) ORDER BY m.at
                """, chunk) {
                    if let thread = row[0] as? String, let id = row[1] as? String { by[thread, default: []].append(id) }
                }
            }
            return threads.compactMap { thread in by[thread].map { (thread, $0) } }
        }
    }

    /// Threads with mail since a moment, received or sent, whose body isn't
    /// here, newest first.
    func unbodied(since: Date, limit: Int) -> [String] {
        queue.sync {
            // By the time index (`+m.thread` keeps SQLite from grouping by
            // walking the thread index, which reads every message there is).
            strings("""
            SELECT m.thread FROM messages m LEFT JOIN bodies b ON b.id = m.id
            WHERE b.id IS NULL AND m.at >= ? AND instr(m.labels, '|SPAM|') = 0 AND instr(m.labels, '|TRASH|') = 0
            GROUP BY +m.thread ORDER BY max(m.at) DESC LIMIT ?
            """, [since.timeIntervalSince1970, limit])
        }
    }

    /// Bodies kept for reading offline: mail of the last month, the
    /// threads given (each split's newest), every thread opened, found by a
    /// search or snoozed. Older bodies of the rest go, the oldest first and
    /// at most `limit` of them, so the store is held a moment, not the
    /// seconds a big mailbox's whole share takes; their words in the index
    /// go back to the snippet, and opening one fetches it again. How many went.
    @discardableResult
    public func prune(keeping threads: Set<String>, before: Date, limit: Int = .max) -> Int {
        guard tallied else { return 0 }
        return queue.sync {
            exec("BEGIN")
            exec("CREATE TEMP TABLE IF NOT EXISTS held(thread TEXT PRIMARY KEY); DELETE FROM held;")
            for thread in threads { run("INSERT OR IGNORE INTO held(thread) VALUES(?)", [thread]) }
            exec("""
            CREATE TEMP TABLE IF NOT EXISTS going(n INTEGER PRIMARY KEY, id TEXT, subject TEXT, sender TEXT, snippet TEXT);
            DELETE FROM going;
            """)
            // From the bodies kept, far fewer than the mail there is.
            run("""
            INSERT INTO going(n, id, subject, sender, snippet)
              SELECT m.rowid, m.id, m.subject, m.from_name || ' ' || m.from_addr, m.snippet FROM bodies b CROSS JOIN messages m ON m.id = b.id
              WHERE m.at < ? AND m.thread NOT IN (SELECT thread FROM held) AND m.thread NOT IN (SELECT thread FROM opened)
                AND m.thread NOT IN (SELECT thread FROM snoozes)
                AND m.thread NOT IN (SELECT thread FROM messages WHERE backfilled IS NOT NULL)
              ORDER BY m.at LIMIT ?
            """, [before.timeIntervalSince1970, limit])
            let gone = Int(int("SELECT count(*) FROM going", []) ?? 0)
            exec("""
            INSERT OR REPLACE INTO words(rowid, id, subject, sender, body) SELECT n, id, subject, sender, snippet FROM going;
            DELETE FROM bodies WHERE id IN (SELECT id FROM going);
            DELETE FROM going; DELETE FROM held;
            """)
            exec("COMMIT")
            return gone
        }
    }

    // MARK: - drafts

    public func save(_ draft: MailDraft) {
        queue.sync {
            run("""
            INSERT OR REPLACE INTO drafts(id, thread, recipients, cc, subject, body, in_reply_to, refs, message_id, updated)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """, [draft.id, draft.thread, draft.to.map(\.header).joined(separator: ", "), draft.cc.map(\.header).joined(separator: ", "),
                  draft.subject, draft.body, draft.inReplyTo, draft.references, draft.messageID, Date().timeIntervalSince1970])
            if draftFilesKept {
                exec("BEGIN")
                run("DELETE FROM draft_files WHERE draft = ?", [draft.id])
                for (n, file) in draft.files.enumerated() {
                    run("INSERT OR REPLACE INTO draft_files(draft, id, n, name, mime, size, message, part) VALUES(?,?,?,?,?,?,?,?)",
                        [draft.id, file.id, n, file.name, file.mime, file.size, file.message, file.part])
                }
                exec("COMMIT")
            }
            guard draftsWhole else { return }
            run("UPDATE drafts SET bcc = ?, quote = ?, forwarded = ? WHERE id = ?",
                [draft.bcc.map(\.header).joined(separator: ", "), draft.quote, draft.forwarded, draft.id])
            guard draftsRemind else { return }
            run("UPDATE drafts SET remind = ?, remind_set = ? WHERE id = ?",
                [draft.remind?.timeIntervalSince1970 as Any, draft.remindSet?.timeIntervalSince1970 as Any, draft.id])
            guard draftsRich else { return }
            run("UPDATE drafts SET html = ?, sender = ?, signed = ? WHERE id = ?", [draft.html, draft.from, draft.signed ? 1 : 0, draft.id])
        }
    }

    /// A draft's files, in their chips' order.
    private func draftFiles(_ id: String) -> [MailDraftFile] {
        guard draftFilesKept else { return [] }
        return query("SELECT id, name, mime, size, message, part FROM draft_files WHERE draft = ? ORDER BY n", [id]).map { row in
            MailDraftFile(id: row[0] as? String ?? "", name: row[1] as? String ?? "", mime: row[2] as? String ?? "",
                          size: Int(row[3] as? Int64 ?? 0), message: row[4] as? String ?? "", part: row[5] as? String ?? "")
        }
    }

    public func draft(_ id: String) -> MailDraft? {
        queue.sync {
            guard var draft = query("SELECT id, thread, recipients, cc, subject, body, in_reply_to, refs, message_id FROM drafts WHERE id = ?", [id])
                .first.map({ row in
                    MailDraft(id: row[0] as? String ?? id, thread: row[1] as? String ?? "", to: MailPerson.list(row[2] as? String ?? ""),
                              cc: MailPerson.list(row[3] as? String ?? ""), subject: row[4] as? String ?? "", body: row[5] as? String ?? "",
                              inReplyTo: row[6] as? String ?? "", references: row[7] as? String ?? "", messageID: row[8] as? String ?? "")
                }) else { return nil }
            if draftsWhole, let row = query("SELECT bcc, quote, forwarded FROM drafts WHERE id = ?", [id]).first {
                draft.bcc = MailPerson.list(row[0] as? String ?? "")
                draft.quote = row[1] as? String ?? ""
                draft.forwarded = row[2] as? String ?? ""
            }
            if draftsRemind, let row = query("SELECT remind, remind_set FROM drafts WHERE id = ?", [id]).first {
                draft.remind = (row[0] as? Double).map(Date.init(timeIntervalSince1970:))
                draft.remindSet = (row[1] as? Double).map(Date.init(timeIntervalSince1970:))
            }
            if draftsRich, let row = query("SELECT html, sender, signed FROM drafts WHERE id = ?", [id]).first {
                draft.html = row[0] as? String ?? ""
                draft.from = row[1] as? String ?? ""
                draft.signed = (row[2] as? Int64 ?? 0) != 0
            }
            draft.files = draftFiles(id)
            return draft
        }
    }

    /// The draft written in a reply's or a forward's place in a thread
    /// (MailDesk.place): the one there, else the newest that went out from
    /// there and came back (⌘Z) while another took the place; never one
    /// still waiting to go.
    public func draft(place: String) -> MailDraft? {
        if let here = draft(place) { return here }
        let id: String? = queue.sync {
            string("""
            SELECT id FROM drafts WHERE substr(id, 1, ?) = ? AND id NOT IN (SELECT thread FROM ops WHERE kind = 'send')
            ORDER BY updated DESC LIMIT 1
            """, [place.count + 1, place + ":"])
        }
        return id.flatMap { draft($0) }
    }

    /// A draft kept under another id, its files' rows with it, and their
    /// copies (MailAttach.move): a reply going out leaves its thread's
    /// place for the next, and comes back to it when taken back.
    public func rename(draft id: String, to new: String) {
        queue.sync {
            exec("BEGIN")
            run("DELETE FROM drafts WHERE id = ?", [new])
            run("UPDATE drafts SET id = ? WHERE id = ?", [new, id])
            if draftFilesKept {
                run("DELETE FROM draft_files WHERE draft = ?", [new])
                run("UPDATE draft_files SET draft = ? WHERE draft = ?", [new, id])
            }
            exec("COMMIT")
        }
        MailAttach.move(draft: id, to: new, store: self)
    }

    /// A draft gone, sent: its files' rows with it (their copies are
    /// MailAttach's to take away).
    public func dropDraft(_ id: String) {
        queue.sync {
            run("DELETE FROM drafts WHERE id = ?", [id])
            if draftFilesKept { run("DELETE FROM draft_files WHERE draft = ?", [id]) }
        }
    }

    /// Every draft with words in it, a file of its own, or a forward with
    /// someone to go to, newest first: the mail column's Kept.
    public func drafts() -> [MailDraft] {
        queue.sync {
            let attached = draftFilesKept ? " OR EXISTS (SELECT 1 FROM draft_files f WHERE f.draft = drafts.id AND f.message = '')" : ""
            return query(draftsWhole ? """
            SELECT id, thread, recipients, subject, body, forwarded FROM drafts
            WHERE length(trim(body)) > 0 OR (forwarded != '' AND length(trim(recipients)) > 0)\(attached) ORDER BY updated DESC
            """ : "SELECT id, thread, recipients, subject, body, '' FROM drafts WHERE length(trim(body)) > 0\(attached) ORDER BY updated DESC", []).map { row in
                let id = row[0] as? String ?? ""
                return MailDraft(id: id, thread: row[1] as? String ?? "", to: MailPerson.list(row[2] as? String ?? ""),
                                 subject: row[3] as? String ?? "", body: row[4] as? String ?? "", forwarded: row[5] as? String ?? "",
                                 files: draftFiles(id))
            }
        }
    }

    /// Every draft that carries a file of its own, by id: whose copies are
    /// kept beside the store (MailAttach.sweep).
    func draftsWithFiles() -> Set<String> {
        queue.sync { draftFilesKept ? Set(strings("SELECT DISTINCT draft FROM draft_files WHERE message = ''", [])) : [] }
    }

    // MARK: - send-as

    /// The addresses the account sends as, as Gmail last said them, the
    /// account's own first (MailSendAs). None kept yet: none.
    public func sendAs() -> [MailSendAs] {
        queue.sync {
            guard draftsRich else { return [] }
            if let sendAsKept { return sendAsKept }
            let all = query("SELECT address, name, reply_to, signature, is_primary, is_default FROM send_as ORDER BY n", []).map { row in
                MailSendAs(address: row[0] as? String ?? "", name: row[1] as? String ?? "", replyTo: row[2] as? String ?? "",
                           signature: row[3] as? String ?? "", primary: (row[4] as? Int64 ?? 0) != 0, isDefault: (row[5] as? Int64 ?? 0) != 0)
            }
            sendAsKept = all
            return all
        }
    }

    /// Gmail's send-as list kept in place of the last, and meta `aliases`
    /// with it: the addresses besides the account's own.
    public func keep(sendAs all: [MailSendAs]) {
        queue.sync {
            guard draftsRich else { return }
            exec("BEGIN")
            run("DELETE FROM send_as", [])
            for (n, one) in all.enumerated() {
                run("INSERT OR REPLACE INTO send_as(address, name, reply_to, signature, is_primary, is_default, n) VALUES(?,?,?,?,?,?,?)",
                    [one.address, one.name, one.replyTo, one.signature, one.primary ? 1 : 0, one.isDefault ? 1 : 0, n])
            }
            let aliases = all.filter { !$0.primary && $0.address != me }.map(\.address)
            if aliases.isEmpty { run("DELETE FROM meta WHERE k = 'aliases'", []) } else { setMeta("aliases", aliases.joined(separator: ",")) }
            exec("COMMIT")
            sendAsKept = all
        }
    }

    /// The signature a mail from this address carries, HTML: the one
    /// written here, else Gmail's; "" for none.
    public func signature(for address: String) -> String {
        if let own = ownSignature(for: address) { return own }
        return sendAs().first { $0.address == address.lowercased() }?.signature ?? ""
    }

    /// The signature written here for this address, if one is (Settings › Mail).
    public func ownSignature(for address: String) -> String? {
        queue.sync {
            guard draftsRich else { return nil }
            if signaturesKept == nil {
                signaturesKept = Dictionary(query("SELECT address, html FROM signatures", []).map { ($0[0] as? String ?? "", $0[1] as? String ?? "") },
                                            uniquingKeysWith: { a, _ in a })
            }
            return signaturesKept?[address.lowercased()]
        }
    }

    /// A signature of one's own for this address; nil, Gmail's again.
    public func setSignature(_ html: String?, for address: String) {
        queue.sync {
            guard draftsRich else { return }
            if let html {
                run("INSERT OR REPLACE INTO signatures(address, html, at) VALUES(?,?,?)", [address.lowercased(), html, Date().timeIntervalSince1970])
            } else {
                run("DELETE FROM signatures WHERE address = ?", [address.lowercased()])
            }
            signaturesKept = nil
        }
    }

    /// The writer busy for `seconds`, as a long sync write keeps it, from
    /// the caller's queue; `entered` once it is: for a bench timing what
    /// must not wait on the writer (evals/mail/field_click.py).
    public func holdWriter(_ seconds: TimeInterval, entered: () -> Void = {}) {
        queue.sync {
            entered()
            Thread.sleep(forTimeInterval: seconds)
        }
    }

    // MARK: - read statuses

    /// The key a mail of yours goes with (MailReads), by its Message-ID: the
    /// one kept for it already, a try before that Gmail may have sent, or
    /// a new one (`make`) kept now, before the mail goes. Nil while the
    /// store has no room for it (its migration not in yet).
    public func readKey(message: String, at: Date, make: () -> String) -> String? {
        queue.sync {
            guard readsKept, !message.isEmpty else { return nil }
            if let kept = string("SELECT key FROM reads WHERE message = ?", [message]) { return kept }
            let key = make()
            run("INSERT INTO reads(message, key, sent_at, thread) VALUES(?,?,?,'')", [message, key, at.timeIntervalSince1970])
            return key
        }
    }

    /// A mail with a key gone: in its thread, at its time.
    public func readSent(message: String, thread: String, at: Date) {
        queue.sync {
            guard readsKept else { return }
            run("UPDATE reads SET thread = ?, sent_at = ? WHERE message = ?", [thread, at.timeIntervalSince1970, message])
        }
    }

    /// A key that will go with nothing: its mail goes without (the setting
    /// turned off before a try that hadn't gone).
    func dropRead(message: String) {
        queue.sync {
            guard readsKept else { return }
            run("DELETE FROM reads WHERE message = ?", [message])
            run("DELETE FROM read_opens WHERE message = ?", [message])
        }
    }

    /// The keys of mail that went since then, newest first, by Message-ID,
    /// with their threads; with `thread`, only that thread's.
    public func readKeys(since: Date, thread: String? = nil) -> [(message: String, key: String, thread: String)] {
        queue.sync {
            guard readsKept else { return [] }
            let rows = thread.map { query("SELECT message, key, thread FROM reads WHERE thread = ? AND sent_at >= ? ORDER BY sent_at DESC",
                                          [$0, since.timeIntervalSince1970]) }
                ?? query("SELECT message, key, thread FROM reads WHERE sent_at >= ? ORDER BY sent_at DESC", [since.timeIntervalSince1970])
            return rows.compactMap { row in
                guard let message = row[0] as? String, let key = row[1] as? String else { return nil }
                return (message, key, row[2] as? String ?? "")
            }
        }
    }

    /// What the site said, by key: each open kept once, so the ones it no
    /// longer gives (it gives a key's newest 50) stay. How many were new.
    @discardableResult
    func keepOpens(_ found: [String: [MailReads.Open]]) -> Int {
        queue.sync {
            guard readsKept, !found.isEmpty else { return 0 }
            var added = 0
            exec("BEGIN")
            for (key, opens) in found {
                for open in opens {
                    run("INSERT OR IGNORE INTO read_opens(message, at, kind) SELECT message, ?, ? FROM reads WHERE key = ?",
                        [open.at.timeIntervalSince1970, open.kind.rawValue, key])
                    added += Int(sqlite3_changes(db))
                }
            }
            exec("COMMIT")
            return added
        }
    }

    /// Each of these mails that went with a key (by Message-ID), and the
    /// times it was opened, newest first; one without a key isn't there.
    public func opens(messages: [String]) -> [String: [MailReads.Open]] {
        queue.sync {
            let wanted = Array(Set(messages.filter { !$0.isEmpty }))
            guard readsKept, !wanted.isEmpty else { return [:] }
            var out: [String: [MailReads.Open]] = [:]
            for start in stride(from: 0, to: wanted.count, by: 500) {
                let chunk = Array(wanted[start..<min(wanted.count, start + 500)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                for row in query("SELECT message FROM reads WHERE message IN (\(marks))", chunk) {
                    if let message = row[0] as? String { out[message] = [] }
                }
                let sql = "SELECT message, at, kind FROM read_opens WHERE message IN (\(marks)) ORDER BY at DESC"
                for row in query(sql, chunk) {
                    guard let message = row[0] as? String, let at = row[1] as? Double else { continue }
                    out[message, default: []].append(MailReads.Open(at: Date(timeIntervalSince1970: at),
                                                                    kind: MailReads.Kind(rawValue: row[2] as? String ?? "") ?? .other))
                }
            }
            return out
        }
    }

    /// For each of these threads, its newest mail of yours that went with
    /// a key, by its Message-ID: what a list's row says of it.
    func readMessages(threads: [String]) -> [String: String] {
        queue.sync {
            let wanted = Array(Set(threads.filter { !$0.isEmpty }))
            guard readsKept, !wanted.isEmpty else { return [:] }
            var out: [String: (message: String, at: Double)] = [:]
            for start in stride(from: 0, to: wanted.count, by: 500) {
                let chunk = Array(wanted[start..<min(wanted.count, start + 500)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                for row in query("SELECT thread, message, sent_at FROM reads WHERE thread IN (\(marks))", chunk) {
                    guard let thread = row[0] as? String, let message = row[1] as? String, let at = row[2] as? Double else { continue }
                    if at >= out[thread]?.at ?? -.infinity { out[thread] = (message, at) }
                }
            }
            return out.mapValues(\.message)
        }
    }

    // MARK: - the journal

    @discardableResult
    func queueOp(_ kind: MailOp.Kind, thread: String, label: String = "", after: TimeInterval = 0) -> Int64 {
        queue.sync {
            let now = Date().timeIntervalSince1970
            run("INSERT INTO ops(kind, thread, label, not_before, made) VALUES(?,?,?,?,?)", [kind.rawValue, thread, label, now + after, now])
            return sqlite3_last_insert_rowid(db)
        }
    }

    /// One op on many threads (MailOps.bulk): one entry in the journal,
    /// its threads beside it, in one transaction.
    @discardableResult
    func queuePack(_ kind: MailOp.Kind, threads: [String], label: String = "", after: TimeInterval = 0) -> Int64 {
        queue.sync {
            let now = Date().timeIntervalSince1970
            exec("BEGIN")
            run("INSERT INTO ops(kind, thread, label, not_before, made) VALUES(?,?,?,?,?)", [kind.rawValue, MailOp.pack, label, now + after, now])
            let seq = sqlite3_last_insert_rowid(db)
            for thread in threads { run("INSERT OR IGNORE INTO packs(seq, thread) VALUES(?,?)", [seq, thread]) }
            exec("COMMIT")
            return seq
        }
    }

    /// One op on messages by their ids (MailOps.bulk(messages:)): one entry
    /// in the journal, its messages beside it, in one transaction.
    @discardableResult
    func queueMessages(_ kind: MailOp.Kind, ids: [String], after: TimeInterval = 0) -> Int64 {
        queue.sync {
            let now = Date().timeIntervalSince1970
            exec("BEGIN")
            run("INSERT INTO ops(kind, thread, label, not_before, made) VALUES(?,?,?,?,?)", [kind.rawValue, MailOp.byMessages, "", now + after, now])
            let seq = sqlite3_last_insert_rowid(db)
            for id in ids { run("INSERT OR IGNORE INTO pack_messages(seq, message) VALUES(?,?)", [seq, id]) }
            exec("COMMIT")
            return seq
        }
    }

    /// The ops due now, oldest first.
    func dueOps(now: Date = Date()) -> [MailOp] {
        queue.sync {
            query("SELECT seq, kind, thread, label, tries, not_before FROM ops WHERE not_before <= ? AND (taken IS NULL OR taken < ?) ORDER BY seq",
                  [now.timeIntervalSince1970, min(now, Date()).timeIntervalSince1970 - 120]).compactMap(opRow)
        }
    }

    /// Every op not yet done, due or held, being sent or not.
    public func allOps() -> [MailOp] {
        queue.sync { query("SELECT seq, kind, thread, label, tries, not_before FROM ops ORDER BY seq", []).compactMap(opRow) }
    }

    public func op(_ seq: Int64) -> MailOp? {
        queue.sync { query("SELECT seq, kind, thread, label, tries, not_before FROM ops WHERE seq = ?", [seq]).first.flatMap(opRow) }
    }

    /// An op as its row has it, a pack's threads with it.
    private func opRow(_ row: SQLiteRow) -> MailOp? {
        guard let seq = row[0] as? Int64, let kind = (row[1] as? String).flatMap(MailOp.Kind.init),
              let thread = row[2] as? String else { return nil }
        var op = MailOp(seq: seq, kind: kind, thread: thread, label: row[3] as? String ?? "",
                        tries: Int(row[4] as? Int64 ?? 0), notBefore: Date(timeIntervalSince1970: row[5] as? Double ?? 0))
        if op.onMessages {
            op.messages = strings("SELECT message FROM pack_messages WHERE seq = ? ORDER BY rowid", [seq])
            // The threads they are in here, for what shows them.
            op.threads = strings("""
            SELECT DISTINCT m.thread FROM pack_messages p JOIN messages m ON m.id = p.message WHERE p.seq = ?
            """, [seq])
        } else {
            op.threads = op.isPack ? strings("SELECT thread FROM packs WHERE seq = ? ORDER BY rowid", [seq]) : [thread]
        }
        return op
    }

    /// The messages of these threads here, oldest first in each: what a
    /// pack labels at Gmail.
    public func messageIDs(threads: [String]) -> [String] {
        queue.sync { threads.flatMap { strings("SELECT id FROM messages WHERE thread = ? ORDER BY at", [$0]) } }
    }

    /// Those of these threads this Mac may not hold whole: the first mail
    /// kept of it answers one that isn't here (older than the sync went
    /// back). Gmail labels those by the thread, not by the ids known here.
    public func partial(_ threads: [String]) -> Set<String> {
        queue.sync {
            Set(threads.filter { thread in
                guard let answers = query("SELECT in_reply_to FROM messages WHERE thread = ? ORDER BY at LIMIT 1", [thread]).first?.first as? String,
                      !answers.isEmpty else { return false }
                return int("SELECT count(*) FROM messages WHERE thread = ? AND rfc_id = ?", [thread, answers]) == 0
            })
        }
    }

    /// An op taken by one flush, so another running at the same moment
    /// doesn't send it too, and an undo knows it is too late: false when
    /// someone else has it, or it went. A flush that died lets go after
    /// two minutes.
    public func take(_ seq: Int64, now: Date = Date()) -> Bool {
        queue.sync {
            let at = now.timeIntervalSince1970
            run("UPDATE ops SET taken = ? WHERE seq = ? AND not_before <= ? AND (taken IS NULL OR taken < ?)", [at, seq, at, at - 120])
            return sqlite3_changes(db) == 1
        }
    }

    /// Takes back an op nobody is sending: false when it went or is going.
    public func dropOp(_ seq: Int64, now: Date = Date()) -> Bool {
        queue.sync {
            run("DELETE FROM ops WHERE seq = ? AND (taken IS NULL OR taken < ?)", [seq, now.timeIntervalSince1970 - 120])
            guard sqlite3_changes(db) == 1 else { return false }
            run("DELETE FROM packs WHERE seq = ?", [seq])
            run("DELETE FROM pack_messages WHERE seq = ?", [seq])
            return true
        }
    }

    func doneOp(_ seq: Int64) {
        queue.sync {
            run("DELETE FROM ops WHERE seq = ?", [seq])
            run("DELETE FROM packs WHERE seq = ?", [seq])
            run("DELETE FROM pack_messages WHERE seq = ?", [seq])
        }
    }

    /// Again at a time. `counted`: a failed try, as against Gmail saying
    /// slow down, which says nothing about the op.
    func retryOp(_ seq: Int64, at: Date, counted: Bool = true) {
        queue.sync {
            run("UPDATE ops SET tries = tries + ?, not_before = ?, taken = NULL WHERE seq = ?", [counted ? 1 : 0, at.timeIntervalSince1970, seq])
        }
    }

    public var pendingOps: Int { queue.sync { Int(int("SELECT count(*) FROM ops", []) ?? 0) } }

    /// Those of these ops still in the journal: the rest went, or were given up.
    public func pending(_ seqs: [Int64]) -> Set<Int64> {
        guard !seqs.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: seqs.count).joined(separator: ",")
        return queue.sync { Set(query("SELECT seq FROM ops WHERE seq IN (\(marks))", seqs).compactMap { $0.first as? Int64 }) }
    }

    // MARK: - rows

    private func messages(where clause: String, _ args: [Any], bodies: Bool = true) -> [MailMessage] {
        // Read by column name, not by place: a column added to or moved in
        // the SELECT can't shift the others.
        let body = bodies ? "b.text AS text, b.html AS html, b.parts AS parts" : "NULL AS text, NULL AS html, NULL AS parts"
        var read: [String] = []
        var out: [MailMessage] = query("""
        SELECT m.id AS id, m.thread AS thread, m.from_name AS from_name, m.from_addr AS from_addr, m.recipients AS recipients,
          m.cc AS cc, m.subject AS subject, m.snippet AS snippet, m.at AS at, m.labels AS labels, m.rfc_id AS rfc_id,
          m.in_reply_to AS in_reply_to, m.refs AS refs, m.bulk AS bulk, m.reply_to AS reply_to, m.attached AS attached,
          m.unsubscribe AS unsubscribe, m.unsubscribe_post AS unsubscribe_post, \(body)
        FROM messages m LEFT JOIN bodies b ON b.id = m.id WHERE \(clause)
        """, args).compactMap { row in
            guard let id = row.string("id"), let thread = row.string("thread") else { return nil }
            // Its parts read: its files come with it.
            if row.int64("parts") == 1 { read.append(id) }
            return MailMessage(
                id: id, thread: thread,
                from: MailPerson(name: row.string("from_name") ?? "", address: row.string("from_addr") ?? ""),
                to: MailPerson.list(row.string("recipients") ?? ""), cc: MailPerson.list(row.string("cc") ?? ""),
                subject: row.string("subject") ?? "", snippet: row.string("snippet") ?? "",
                date: Date(timeIntervalSince1970: row.double("at") ?? 0),
                labels: MailStore.labels(row.string("labels") ?? ""),
                rfcID: row.string("rfc_id") ?? "", inReplyTo: row.string("in_reply_to") ?? "", references: row.string("refs") ?? "",
                listUnsubscribe: row.bool("bulk") ?? false,
                replyTo: row.string("reply_to").map(MailPerson.list),
                unsubscribe: row.string("unsubscribe"), unsubscribePost: row.string("unsubscribe_post"),
                text: row.string("text"), html: row.string("html"),
                attached: row.bool("attached"))
        }
        guard !read.isEmpty else { return out }
        let files = fileRows(read)
        let known = Set(read)
        for at in out.indices where known.contains(out[at].id) { out[at].files = files[out[at].id] ?? [] }
        guard inviting else { return out }
        let invites = inviteRows(read)
        for at in out.indices { out[at].calendar = invites[out[at].id] }
        return out
    }

    /// The invitations of these messages, each its iCalendar text.
    private func inviteRows(_ ids: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = Array(ids[start..<min(ids.count, start + 500)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for row in query("SELECT message, ics FROM invites WHERE message IN (\(marks))", chunk) {
                if let message = row[0] as? String, let ics = row[1] as? String { out[message] = ics }
            }
        }
        return out
    }

    /// Labels in one column, each between bars, so LIKE '%|INBOX|%' finds one.
    public static func labels(_ set: Set<String>) -> String { set.isEmpty ? "" : "|" + set.sorted().joined(separator: "|") + "|" }
    public static func labels(_ text: String) -> Set<String> { Set(text.split(separator: "|").map(String.init)) }

    // MARK: - SQL

    private func meta(_ key: String) -> String? { string("SELECT v FROM meta WHERE k = ?", [key]) }
    private func setMeta(_ key: String, _ value: String) { run("INSERT OR REPLACE INTO meta(k, v) VALUES(?, ?)", [key, value]) }

    /// SQL as it is, unbound; a failure is the caller's to say.
    @discardableResult
    private func exec(_ sql: String) -> Bool { connection?.exec(sql) ?? false }

    private static let transient = SQLiteConnection.transient

    static let log = MailGmail.log

    private var lastError: String { connection?.lastError ?? "no database" }

    /// A statement of its own, for a caller that steps it and finalizes it;
    /// one that won't compile is said in the log.
    private func prepare(_ sql: String, _ args: [Any]) -> OpaquePointer? { connection?.prepare(sql, args) }

    /// A failed statement is said in the log, never silently.
    @discardableResult
    private func run(_ sql: String, _ args: [Any]) -> Bool { connection?.run(sql, args) ?? false }

    private func query(_ sql: String, _ args: [Any]) -> [SQLiteRow] { connection?.query(sql, args) ?? [] }

    private func string(_ sql: String, _ args: [Any]) -> String? { query(sql, args).first?.first as? String }
    private func int(_ sql: String, _ args: [Any]) -> Int64? { query(sql, args).first?.first as? Int64 }
    private func strings(_ sql: String, _ args: [Any]) -> [String] { query(sql, args).compactMap { $0.first as? String } }
}
