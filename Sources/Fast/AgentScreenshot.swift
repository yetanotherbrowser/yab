import AppKit

/// Keep pixels in memory until authorization is checked again at delivery.
/// In particular, a file must not be written before this returns an image.
@MainActor
enum AgentImageGate {
    static func capture(_ page: any PageHandle, shot: PageShot,
                        allowed: @escaping @MainActor () async -> Bool) async throws -> NSImage {
        guard await allowed() else { throw AgentSecrets.Refused(page) }
        let (image, error) = await withCheckedContinuation { continuation in
            page.snapshot(shot) { image, error in continuation.resume(returning: (image, error)) }
        }
        guard await allowed() else { throw AgentSecrets.Refused(page) }
        guard let image else { throw error ?? NSError(domain: "AgentScreenshot", code: 1,
                                                      userInfo: [NSLocalizedDescriptionKey: "no picture"]) }
        return image
    }
}

@MainActor
enum AgentScreenshot {
    static func capture(_ tab: Tab, width: Double?) async throws -> NSImage {
        guard let page = tab.page as? ChromiumPage else { throw AgentSecrets.Refused() }
        var receipt: Set<String>?
        var shot = PageShot(width: width.map { CGFloat($0) })
        shot.scrollMayMove = true
        return try await AgentImageGate.capture(page, shot: shot) {
            guard !tab.gone, tab.builtPage === page, !tab.wallet.agentScreenshotBlocked,
                  await AgentSecrets.check(page), case let frames = (try? await page.agentFrames()) ?? [],
                  // A frame with no script context is left out of the
                  // receipt, as the guard leaves it out; it is not a refusal.
                  case let tokens = Set(frames.compactMap({ try? page.scripts.token($0, tab: page.remoteID) })),
                  !tab.gone, tab.builtPage === page, !tab.wallet.agentScreenshotBlocked else { return false }
            // A safe replacement document cannot authorize pixels captured
            // from the old document or its old frame inventory.
            if let receipt, receipt != tokens { return false }
            receipt = tokens
            return true
        }
    }
}
