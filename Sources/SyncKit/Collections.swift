import Foundation

// Every collection sync carries, by name, and how each merges
// (docs/sync.md, "Collections"). One list for the Mac and the iPhone: two
// devices that merge one record by different rules never agree on it.

public enum SyncCollection {
    public static let space = "space", tab = "tab", folder = "folder", pair = "pair", bookmark = "bookmark", setting = "setting"
    public static let file = "file", icon = "icon", routine = "routine", memory = "memory", visit = "visit", answer = "answer"
    public static let chat = "chat", chatItem = "chatitem", send = "send", presence = "presence"
    /// A piece of a file an iPhone attached to its words for a Mac's chat (SyncSendFile).
    public static let sendPart = "sendpart"
    public static let login = "login", code = "code", card = "card", address = "address"
    public static let ext = "extension", plugin = "plugin", pluginPart = "pluginpart"
    /// A Mac's Now rows about mail, for the iPhone's Now widget (SyncNow).
    public static let now = "now"
    /// A project of chats (SyncProject).
    public static let project = "project"
    /// Where this account's devices go: left behind when two accounts
    /// became one (AccountMove, docs/sync.md).
    public static let moved = "accountmove"
    /// A bookmark's parent at the top level.
    public static let root = "root"
    /// The first space: the same id on every device, so first spaces meet
    /// instead of doubling.
    public static let firstSpace = "00000000-0000-0000-0000-000000000001"
    /// Whether `id` is the first space's. Its sign-ins are every device's:
    /// it never has its own, whatever a record says (#909).
    public static func isFirstSpace(_ id: String) -> Bool { id.uppercased() == firstSpace }

    /// Every collection's merge rules. Runs before a journal opens, on
    /// every device, the collections a device never shows too.
    public static func register() {
        Kind.register(Kind(space, groups: [Kind.place, ["icon", "iconChoice", "iconChoiceID"], ["ownSignIns", "signInWith"]]))
        Kind.register(Kind(tab, removalWins: true, rules: ["seen": .most], groups: [Kind.place]))
        // A folder moved into another moves as one: the space, its place
        // there and the folder it is in.
        Kind.register(Kind(folder, groups: [Kind.place + ["folder"]]))
        Kind.register(Kind(pair, removalWins: true))
        Kind.register(Kind(bookmark, groups: [Kind.place]))
        Kind.register(Kind(setting))
        Kind.register(Kind(file))
        Kind.register(Kind(icon))
        Kind.register(Kind(routine))
        Kind.register(Kind(memory))
        Kind.register(Kind(visit, rules: ["last": .most]))
        Kind.register(Kind(answer))
        Kind.register(Kind(chat))
        Kind.register(Kind(chatItem))
        Kind.register(Kind(send))
        Kind.register(Kind(moved))
        Kind.register(Kind(sendPart, removalWins: true))
        Kind.register(Kind(OpenOnMac.capability))
        TaskRecords.register()
        AssistantApprovalRecords.register()
        Kind.register(Kind(login, rules: ["used": .most]))
        Kind.register(Kind(code))
        Kind.register(Kind(card))
        Kind.register(Kind(address))
        Kind.register(Kind(ext))
        Kind.register(Kind(plugin))
        Kind.register(Kind(pluginPart))
        Kind.register(Kind(now))
        Kind.register(Kind(project))
    }
}

public typealias SyncFields = [String: Value]
