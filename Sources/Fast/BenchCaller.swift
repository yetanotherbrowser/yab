import Foundation
import Security

// Who is on the other end of the bench's socket.
//
// Every program the person runs can open the socket: its file mode and the
// caller's user id say only that it is theirs. A shipped Yab answers only
// its own code, the `yab` command and `yab mcp` from inside its bundle,
// whether Yab started it for an agent or Claude Code, Codex, Cursor or Zed
// did. The kernel says who connected (the peer's audit token, which names
// one process for its whole life and never the next one with its pid), and
// Code Signing says whether that process's code is Yab's: it must satisfy
// the designated requirement Yab's own signature carries, Yab's identifier
// signed by its team, any version.
//
// Not a token handed to the agents Yab starts: `yab mcp` started by another
// client could only find one where every other program of the person's
// could too, and Codex passes its servers no variable it wasn't told of.

enum BenchCaller {
    /// The audit token of whoever is connected on `fd`, or nil when there is
    /// nobody, or `fd` isn't a local socket.
    nonisolated static func token(_ fd: Int32) -> Data? {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
              size == socklen_t(MemoryLayout<audit_token_t>.size) else { return nil }
        return withUnsafeBytes(of: &token) { Data($0) }
    }

    /// Whether the running code `token` names satisfies `requirement`, and
    /// is still valid (not changed on disk under it, not lost its signature).
    nonisolated static func satisfies(_ token: Data, _ requirement: SecRequirement) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// What Yab's own signature requires of code that is Yab: nil for a
    /// copy that isn't signed at all, which then trusts nobody.
    nonisolated static let own: SecRequirement? = {
        var me: SecCode?
        var stat: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &stat) == errSecSuccess, let stat,
              SecCodeCopyDesignatedRequirement(stat, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }()

    /// Answers already given, by audit token: every tool call is a connection
    /// of its own, and one `yab mcp` makes hundreds.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [Data: Bool] = [:]
    private static let queue = DispatchQueue(label: "bench.caller", qos: .userInitiated)

    private nonisolated static func cached(_ token: Data) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return known[token]
    }

    private nonisolated static func remember(_ token: Data, _ said: Bool) {
        lock.lock()
        if known.count > 512 { known = [:] }
        known[token] = said
        lock.unlock()
    }

    /// Whether the caller on `fd` is Yab's own code.
    nonisolated static func yab(_ fd: Int32) -> Bool {
        guard let requirement = own, let token = token(fd) else { return false }
        if let said = cached(token) { return said }
        let said = satisfies(token, requirement)
        remember(token, said)
        return said
    }

    /// Checks whether the caller on `fd` is Yab's own code without blocking
    /// the main thread on Security.framework code-signing validation.
    @MainActor
    static func check(_ fd: Int32, done: @escaping @MainActor (Bool) -> Void) {
        guard let token = token(fd) else {
            done(false)
            return
        }
        if let said = cached(token) {
            done(said)
            return
        }
        queue.async {
            let said: Bool
            if let cached = cached(token) {
                said = cached
            } else if let requirement = own {
                let verified = satisfies(token, requirement)
                remember(token, verified)
                said = verified
            } else {
                said = false
            }
            DispatchQueue.main.async { done(said) }
        }
    }

    /// What a caller that isn't Yab is told.
    static let refusal = "Only Yab's own yab command and yab mcp can use Yab's socket."
}
