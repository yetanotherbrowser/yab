import Foundation

/// The agentText envelope prevents a rolled-back Mac from using its default.
/// Only explicit new-agent requests use it; legacy requests stay unchanged.
public enum ChatAgent: String, Sendable, CaseIterable {
    case claude, codex, cursor, gemini, opencode

    public static let version = 1
    public static let unsupported = "Update Yab on your Mac to use the agent selected on this iPhone."
    public static let invalid = "Yab doesn't know that agent request."

    public static func supports(_ record: Record?, device: String) -> Bool {
        guard let record, record.collection == OpenOnMac.capability,
              record.id == device, record.alive(), record["device"]?.string == device else { return false }
        return record["chatAgent"]?.number == Double(version)
    }
}
