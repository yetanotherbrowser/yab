import CryptoKit
import Foundation
import SyncKit

/// The Mac as this iPhone's tasks see it: something that takes a task in the
/// person's words, walks its steps in Yab with their sign-ins, asks for a
/// code or a yes, and says how it went. Today the VirtualMac stands in for
/// it, inside the app; with sync (phase 2) the real Mac answers through the
/// same calls, its words carried by encrypted records and push.
@MainActor
protocol TaskBackend: AnyObject {
    /// Where the Mac's news lands, in the order it happened.
    var onEvent: ((MacEvent) -> Void)? { get set }
    /// Awake, or asleep since a time.
    var presence: MacPresence { get }

    /// A new task: the Mac takes it when it is awake.
    func send(_ order: TaskOrder)
    /// The code a site sent to this iPhone. Encrypted by sync on its way;
    /// the virtual Mac gets it as it is.
    func giveCode(_ id: TaskRun.ID, code: String)
    /// The person's yes, signed on this iPhone after Face ID. The Mac checks
    /// the signature against what it asked, then presses the site's button.
    func giveYes(_ id: TaskRun.ID, _ yes: SignedYes)
    /// Not now: the Mac keeps waiting for the yes, the page stays as it is.
    func notNow(_ id: TaskRun.ID)
    /// Again from the step where it stopped.
    func retry(_ id: TaskRun.ID)
    /// Stop it where it is; its tabs stay in their folder on the Mac.
    func stop(_ id: TaskRun.ID)
    /// More words for a task while it works ("Tell it more").
    func tell(_ id: TaskRun.ID, _ words: String)
    /// The key that signs this iPhone's yes, as the Mac learns it at pairing.
    func trust(_ key: P256.Signing.PublicKey)
    /// Returns once the Mac is awake: what waits for it (a task, Claude's
    /// answer) goes on from there.
    func whenAwake() async
}

/// Live task execution awaits a Mac backend. It cannot use the fixture
/// runner to pretend a payment or a browser action succeeded.
@MainActor
final class UnavailableTaskBackend: TaskBackend {
    var onEvent: ((MacEvent) -> Void)?
    var presence: MacPresence { .awake }
    func send(_ order: TaskOrder) {}
    func giveCode(_ id: TaskRun.ID, code: String) {}
    func giveYes(_ id: TaskRun.ID, _ yes: SignedYes) {}
    func notNow(_ id: TaskRun.ID) {}
    func retry(_ id: TaskRun.ID) {}
    func stop(_ id: TaskRun.ID) {}
    func tell(_ id: TaskRun.ID, _ words: String) {}
    func trust(_ key: P256.Signing.PublicKey) {}
    func whenAwake() async {}
}

/// A task sent from this iPhone: which one, and the words it was given in.
struct TaskOrder: Sendable, Equatable {
    var id: TaskRun.ID
    var words: String
    /// Where it picks up: 0 for a new task, the step it stopped at otherwise.
    var step: Int = 0
}

/// Whether the Mac is there to do anything.
struct MacPresence: Sendable, Equatable {
    var awake: Bool
    /// "18:52": when it fell asleep, as the Now line says it.
    var asleepSince: String?

    static let awake = MacPresence(awake: true, asleepSince: nil)
    static func asleep(since: String) -> MacPresence { MacPresence(awake: false, asleepSince: since) }
}

/// What the Mac says about a task, one event at a time.
enum MacEvent: Sendable, Equatable {
    /// It took the task: running, at its first step.
    case taken(TaskRun.ID)
    /// It reached step `k` (0-based) and works on it.
    case step(TaskRun.ID, Int)
    /// The site sent a code to this iPhone; the Mac waits for it.
    case needsCode(TaskRun.ID, CodeRequest)
    /// The site didn't take the code given: it waits for another.
    case codeRefused(TaskRun.ID, CodeRequest)
    /// A payment, a post or a cancel: the facts the Mac's Yab read from the page.
    case needsYes(TaskRun.ID, YesRequest)
    /// The signature checked out: the Mac presses the site's button.
    case paying(TaskRun.ID)
    case done(TaskRun.ID)
    /// It stopped, and why, in words for the Now line and the chat.
    case failed(TaskRun.ID, TaskFailure)
    /// The person stopped it: its tabs stay in their folder, nothing went wrong.
    case stopped(TaskRun.ID)
    /// The Mac is asleep: the task waits, nothing is lost.
    case waits(TaskRun.ID)
    /// Asleep or awake.
    case presence(MacPresence)
}

/// A site sent a code to this iPhone (the Mac signs in, the SMS comes here).
struct CodeRequest: Codable, Hashable, Sendable {
    /// Who sent it: "TAP".
    var sender: String
    /// The site's icon key: "tap".
    var icon: String
    /// Where the Mac signs in: "flytap.com".
    var site: String
    /// How many digits the code has.
    var length: Int = 6

    /// "TAP sent a code to this iPhone".
    var title: String { "\(sender) sent a code to this \(DeviceWord.name)" }
    /// "Your Mac is signing in to flytap.com for Lisbon flights".
    func line(task: String?) -> String {
        task.map { "Your Mac is signing in to \(site) for \($0)" } ?? "Your Mac is signing in to \(site)"
    }
}

/// What a yes is for, read from the page by Yab on the Mac, not by the model.
struct YesRequest: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case pay, post, cancel
    }

    var kind: Kind
    /// The site's icon key.
    var icon: String
    /// "Pay €238.00 to TAP Air Portugal?"
    var title: String
    /// "flytap.com · Lisbon flights"
    var subtitle: String
    /// Label and value, as the page says them: ["Out", "Tue, Oct 13 · …"].
    var facts: [[String]]
    /// "Pay with Face ID"
    var button: String
    /// The chat's waiting row: "Waiting for you: Pay €238".
    var waiting: String
    /// A live Mac challenge. Fixture requests deliberately have no binding.
    var approval: TaskApproval? = nil

    /// A live signer accepts only a challenge for the displayed facts and its
    /// enrolled key. Legacy fixture digests never authorize a real Mac action.
    func approvalDigest(task: TaskRun.ID, key: P256.Signing.PublicKey, allowsFixture: Bool = false,
                        at now: Int64 = Int64(Date().timeIntervalSince1970)) throws -> Data {
        guard let approval else {
            guard allowsFixture else { throw YesSignerError.unavailable("This action has no Mac approval request") }
            return digest(task: task)
        }
        try approval.validate(at: now)
        guard approval.action.task == task, approval.action.kind == kind.rawValue,
              approval.action.title == title, approval.action.subtitle == subtitle,
              approval.action.facts == facts, approval.action.button == button else { throw TaskApproval.Failure.changed }
        guard approval.keyID == TaskApproval.keyID(key) else { throw TaskApproval.Failure.untrustedKey }
        return try approval.digest()
    }

    /// What the approval sheet describes.
    var noun: String {
        switch kind {
        case .pay: "payment"
        case .post: "post"
        case .cancel: "change"
        }
    }

    /// The Lock Screen's words: never the amount or who gets it, the
    /// iPhone may be in someone else's hand.
    var lockTitle: String {
        switch kind {
        case .pay: "A payment needs you"
        case .post: "A post needs you"
        case .cancel: "A change needs you"
        }
    }

    var lockLine: String {
        switch kind {
        case .pay: "The amount shows in Yab after Face ID"
        case .post: "What it posts shows in Yab after Face ID"
        case .cancel: "What changes shows in Yab after Face ID"
        }
    }

    /// The bytes a yes signs: every word the person saw, in a fixed order,
    /// so the Mac can tell this exact request from any other.
    /// The prototype's fixture digest. Real signing uses approvalDigest.
    func digest(task: TaskRun.ID) -> Data {
        var text = "yab-yes-1\n\(task)\n\(kind.rawValue)\n\(title)\n\(subtitle)\n"
        for fact in facts { text += fact.joined(separator: "\t") + "\n" }
        return Data(SHA256.hash(data: Data(text.utf8)))
    }
}

/// The person's yes: the request's digest signed by this iPhone's key.
struct SignedYes: Sendable, Equatable {
    var digest: Data
    var signature: Data
}

/// Why a task stopped, in the Mac's words.
struct TaskFailure: Codable, Hashable, Sendable {
    /// The Now line: "Couldn’t open flytap.com · the page didn’t load".
    var line: String
    /// The chat: "Couldn’t open flytap.com: the page didn’t load on your Mac".
    var long: String
    /// The Lock Screen's title and line.
    var lockTitle: String
    var lockLine: String
}
