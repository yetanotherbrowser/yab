import Foundation
#if canImport(SyncKit)
import SyncKit
#endif

/// What a question is asked with: its words, the page it is about, and the
/// turns before it.
struct AskContext: Sendable {
    var question: String
    var page: PageContext?
    var history: [Message]

    /// Context sent to the Mac when it cannot read this iPhone's page.
    var macPrompt: String {
        var parts: [String] = []
        let previous = history.filter { $0.role == .you || $0.role == .answer }.suffix(8)
        if !previous.isEmpty {
            parts.append("Earlier conversation on this \(DeviceWord.name):\n" + previous.map {
                "\($0.role == .you ? "You" : "Assistant"): \(String($0.plain.prefix(2000)))"
            }.joined(separator: "\n"))
        }
        if let page {
            parts.append("Page on this \(DeviceWord.name):\nTitle: \(page.title)\nURL: \(page.address)\nPage text:\n\(String(page.text.prefix(12000)))")
        }
        guard !parts.isEmpty else { return question }
        parts.insert("Question: " + question, at: 0)
        return parts.joined(separator: "\n\n")
    }
}

/// The page a question is about, as words: its title, address and text.
struct PageContext: Sendable, Equatable {
    var title: String
    var address: String
    var text: String
}

/// Something that answers: the model on this iPhone, or Claude on the Mac.
/// Each says who it is, in words, and whether it can answer right now.
@MainActor
protocol ChatBackend: AnyObject {
    var who: Chat.Answerer { get }
    var isAvailable: Bool { get }
    func answer(_ context: AskContext) async throws -> String
}

/// Real page questions follow Settings. The iPhone choice stays local on
/// failure, Private always stays local, and remote conversations keep their
/// owning provider. Named fixtures retain the prototype's answer routing.
@MainActor
final class Answerers {
    /// The model on this iPhone (a stand-in in test worlds and tests).
    var device: ChatBackend
    let mac: ClaudeOnMac
    private let deviceChosenExplicitly: Bool
    /// Tests can inject a private settings store without changing shared defaults.
    var pageAnswers: () -> SettingsStore.PageAnswers = { SettingsStore.shared.pageAnswers }
    var macAgent: () -> SettingsStore.Agent = { SettingsStore.shared.agent }

    var preferredMacAgent: ChatAgent { macAgent() == .chatGPT ? .codex : .claude }

    enum LocalFailure: LocalizedError {
        case unavailable, interrupted
        var errorDescription: String? {
            switch self {
            case .unavailable: "Apple Intelligence isn't available on this \(DeviceWord.name). Enable it in Settings, then ask again. This question stayed on this \(DeviceWord.name)."
            case .interrupted: "This \(DeviceWord.name) couldn't answer. Ask again, or choose Your Mac for public page questions in Settings. This question stayed on this \(DeviceWord.name)."
            }
        }
    }

    init(device: ChatBackend, mac: ClaudeOnMac, deviceChosenExplicitly: Bool = true) {
        self.device = device
        self.mac = mac
        self.deviceChosenExplicitly = deviceChosenExplicitly
    }

    /// Fixture mode is chosen by AppModel, including injected test apps.
    func configureFixtures(_ enabled: Bool) {
        mac.usesStandIn = enabled
        if enabled, !deviceChosenExplicitly { device = StandInDevice() }
        else if !enabled, device is StandInDevice { device = OnDeviceModel() }
    }

    /// The answerers for a launch: in test worlds the stand-in for the model,
    /// so pictures and tests see the same words; for people the model itself.
    /// `-YabOnDevice model|standin|none` picks one by hand (none: an iPhone
    /// without Apple Intelligence).
    static func forLaunch(_ options: LaunchOptions, macAsleep: Bool,
                          arguments: [String] = ProcessInfo.processInfo.arguments) -> Answerers {
        let named = arguments.firstIndex(of: "-YabOnDevice").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        let device: ChatBackend
        switch named ?? (options.isTestRun ? "standin" : "model") {
        case "standin": device = StandInDevice()
        case "none": device = NoDeviceModel()
        default: device = OnDeviceModel()
        }
        return Answerers(device: device, mac: ClaudeOnMac(asleep: macAsleep, usesStandIn: options.fixtureWorld != nil), deviceChosenExplicitly: named != nil)
    }

    /// Who answers `question` in `chat`.
    func who(for question: String, in chat: Chat, aboutPage: Bool,
             fixturesEnabled: Bool = true, privateContext: Bool = false, remoteChat: Bool = false) -> Chat.Answerer {
        if !fixturesEnabled {
            // Private origin always stays local, even when a page isn't attached.
            if privateContext { return .iphone }
            // An existing remote chat carries on with its original provider.
            if remoteChat { return .claude }
            return aboutPage && pageAnswers() == .iPhone ? .iphone : .claude
        }
        let claudeJoined = chat.messages.contains { $0.by == .claude || $0.role == .wait || $0.role == .pick }
        guard aboutPage, !claudeJoined, device.isAvailable else { return .claude }
        // The stand-in knows which of its replies are about the page.
        if device is StandInDevice, let hit = StandIns.reply(to: question), !hit.aboutPage { return .claude }
        return .iphone
    }

    func backend(_ who: Chat.Answerer) -> ChatBackend { who == .iphone ? device : mac }
}

/// The model on this iPhone in test worlds: the prototype's replies, at once.
@MainActor
final class StandInDevice: ChatBackend {
    let who = Chat.Answerer.iphone
    var isAvailable: Bool { true }
    func answer(_ context: AskContext) async throws -> String { StandIns.answer(context.question) }
}

/// An iPhone without Apple Intelligence: never answers, so the Mac does.
@MainActor
final class NoDeviceModel: ChatBackend {
    let who = Chat.Answerer.iphone
    var isAvailable: Bool { false }
    func answer(_ context: AskContext) async throws -> String { throw CancellationError() }
}

/// The fixture Mac's replies. Real Mac answers arrive through SyncBridge;
/// this backend cannot manufacture them during a person's launch.
@MainActor
final class ClaudeOnMac: ChatBackend {
    let who = Chat.Answerer.claude
    var asleep: Bool
    var usesStandIn: Bool
    /// How long Claude seems to think.
    var thinking: Duration = .milliseconds(1300)
    /// Answers wait until landNow(): a named state stops on "Claude is thinking".
    var paused = false
    private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(asleep: Bool = false, usesStandIn: Bool = false) {
        self.asleep = asleep
        self.usesStandIn = usesStandIn
    }

    var isAvailable: Bool { usesStandIn && !asleep }

    func answer(_ context: AskContext) async throws -> String {
        guard usesStandIn else { throw Failure.notConnected }
        let text = StandIns.answer(context.question)
        await think()
        return text
    }

    enum Failure: Error { case notConnected }

    /// Whatever is being thought about lands now.
    func landNow() {
        let all = waiting
        waiting.removeAll()
        for (_, waiter) in all { waiter.resume() }
    }

    var isThinking: Bool { !waiting.isEmpty }

    private func think() async {
        let id = UUID()
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            waiting[id] = waiter
            guard !paused else { return }
            let delay = thinking
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                self?.resume(id)
            }
        }
    }

    private func resume(_ id: UUID) {
        guard let waiter = waiting.removeValue(forKey: id) else { return }
        waiter.resume()
    }
}
