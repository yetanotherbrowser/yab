import Foundation

/// Where a key an agent presses lands, for weighing a send-like key before
/// it is pressed. The main world's `focused()` stops at another site's
/// frame, whose empty element would weigh as nothing; out-of-process frames
/// are asked one by one instead, through the complete agent inventory.
enum AgentFocus {
    case main
    case frame(PageFrame)
    /// No single focused document: the key is not weighed as harmless.
    case unknown
}

extension ChromiumPage {
    func agentFocus() async -> AgentFocus {
        let crossed = AgentPage.focusedScript + "\nconst el = focused(); return el.tagName === 'IFRAME' || el.tagName === 'FRAME';"
        guard let inFrame = (try? await call(crossed, in: .agent, gesture: false)) as? Bool else { return .unknown }
        guard inFrame else { return .main }
        guard let frames = try? await agentFrames() else { return .unknown }
        // The focus may be in an extension's own window, which is never run
        // in: no other frame can be taken for where the key lands.
        if frames.contains(where: AgentSecrets.walledOff) { return .unknown }
        // A frame's own focused element, into open shadow roots but not into
        // its frames: the innermost focused document is the only leaf.
        let leaf = """
        let el = document.activeElement;
        for (let n = 0; el && el.shadowRoot && el.shadowRoot.activeElement && n < 16; n++) el = el.shadowRoot.activeElement;
        const isLeaf = !!el && el !== document.body && el !== document.documentElement && el.tagName !== 'IFRAME' && el.tagName !== 'FRAME';
        return { focus: document.hasFocus(), leaf: isLeaf };
        """
        var focused: [PageFrame] = [], held: [PageFrame] = []
        for frame in frames where !frame.isMain {
            guard let row = (try? await call(leaf, in: .agent, frame: frame, gesture: false)) as? [String: Any] else { return .unknown }
            guard row["leaf"] as? Bool == true else { continue }
            held.append(frame)
            if row["focus"] as? Bool == true { focused.append(frame) }
        }
        // A hidden window may report no document focus at all; then the one
        // frame holding a focused element is where the key goes.
        let candidates = focused.isEmpty ? held : focused
        return candidates.count == 1 ? .frame(candidates[0]) : .unknown
    }
}

extension ChromiumPage {
    /// The words selected in the page, or else in one of its frames (each
    /// asked in its own document, out of process or not), the focused
    /// frame's first; "" when nothing is selected anywhere. As
    /// PageView.readSelected is for WebKit.
    func agentSelectedWords() async -> String {
        let main = (try? await run(PageView.selected, in: .agent, gesture: false)) as? String ?? ""
        guard main.isEmpty else { return main }
        let frames = await withCheckedContinuation { continuation in childFrames { continuation.resume(returning: $0) } }
        var found: [(focused: Bool, words: String)] = []
        for frame in frames where !frame.isMain {
            guard let pair = (try? await run("[\(PageView.selected), document.hasFocus()]", in: .agent, frame: frame, gesture: false)) as? [Any],
                  let words = pair.first as? String, !words.isEmpty else { continue }
            found.append((pair.last as? Bool == true, words))
        }
        return (found.first(where: \.focused) ?? found.first)?.words ?? ""
    }
}
