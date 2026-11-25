import AppKit
import YabCoreClient

/// What a page in the bench's room was last told to draw at, by which
/// helper: a helper started again names its tabs from tab-1 again.
@MainActor
final class ChromiumFrames {
    struct Sent: Equatable { let remote: String; let helper: UUID; let interval: Int }
    var resting = false
    var sent: Sent?
    var turn = 0
    var sending: Task<Void, Never>?

    /// What to send now, or nothing. A helper without CEF 0137 is never sent
    /// anything, and a page it has just made draws at the display's rate.
    nonisolated static func next(interval: Int, capable: Bool, remote: String, helper: UUID, sent: Sent?) -> Sent? {
        guard capable else { return nil }
        let before = sent.flatMap { $0.remote == remote && $0.helper == helper ? $0 : nil }
        guard interval != before?.interval ?? 0 else { return nil }
        return Sent(remote: remote, helper: helper, interval: interval)
    }
}

/// An agent's page in the bench's room, between its agent's calls, draws at
/// most 30 times a second, the rate Chrome's Energy Saver gives every page,
/// and is still shown to itself: animation frames, timers and observers go on,
/// fewer frames are drawn. The room lies on no screen, so Chrome paced it by
/// the main display: 240 a second on a 240 Hz monitor, where an animated page
/// there cost its GPU process 37% of a core, its renderer 18% and the window
/// server 14% (2026-11-19). A call that names the page, or the stage taking
/// it, brings it back to the display's rate at once.
extension ChromiumPage: PageFramePace {
    nonisolated static let restingInterval = 33

    /// A video of the page in picture in picture is someone's to watch, and
    /// its frame sink is the page's child: slowing the page would slow it.
    nonisolated static func frameInterval(resting: Bool, inRoom: Bool, pictureInPicture: Bool = false) -> Int {
        resting && inRoom && !pictureInPicture ? restingInterval : 0
    }

    var restsFrames: Bool {
        get { frames.resting }
        // Sent only when it changes (ChromiumFrames.next).
        set {
            frames.resting = newValue
            paceFrames()
        }
    }

    /// A new page in the helper draws at the display's rate until told
    /// otherwise; one told nothing yet is told only to slow down. Sent
    /// straight to the helper, not behind the page's own queue: a page taken
    /// to the stage must not wait on a script still running there. One
    /// request at a time, and only the newest, so a slow-down sent late can't
    /// undo a wake-up. A request that fails counts as sent: the next change
    /// of call, stage or room asks again, not every call in between.
    func paceFrames() {
        guard let remote = remoteID, !retired, let core = ChromiumProcess.shared.connectedClient else { return }
        let interval = Self.frameInterval(resting: frames.resting, inRoom: window?.identifier == Bench.roomID,
                                          pictureInPicture: videoPiP != nil)
        guard let sent = ChromiumFrames.next(interval: interval, capable: ChromiumProcess.shared.pacesFrames, remote: remote,
                                             helper: ChromiumProcess.shared.connectionGeneration, sent: frames.sent) else { return }
        frames.sent = sent
        frames.turn &+= 1
        let turn = frames.turn, previous = frames.sending
        frames.sending = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.frames.turn == turn, ChromiumProcess.shared.isCurrent(core) else { return }
            do {
                _ = try await core.request("tab.frames", params: ["tab": .string(remote), "interval": .number(Double(interval))])
            } catch {
                DebugLog.note("chromium.frames", ["error": error.localizedDescription, "interval": interval])
            }
        }
    }
}
