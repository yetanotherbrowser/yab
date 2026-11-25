import AppKit
import YabCoreClient

/// Keep the keyboard event's native text payload across the process boundary.
/// Reconstructing an NSEvent from characters loses the CGEvent Unicode payload
/// that AppKit's input context uses for supplementary characters (emoji).
@MainActor
enum ChromiumKeyboardInput {
    /// `commands`: the editing commands Yab's input context read from the
    /// key, which the page's view runs in place of reading its copy again.
    static func fields(_ event: NSEvent, commands: [String] = []) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["keyCode": .number(Double(event.keyCode)),
            "modifiers": .number(Double(event.modifierFlags.rawValue))]
        if event.type != .flagsChanged {
            fields["characters"] = .string(event.characters ?? "")
            fields["unmodified"] = .string(event.charactersIgnoringModifiers ?? "")
            fields["repeat"] = .bool(event.isARepeat)
        }
        if !commands.isEmpty { fields["commands"] = .array(commands.map { .string($0) }) }
        if let data = event.cgEvent?.data as Data?, !data.isEmpty {
            fields["event"] = .string(data.base64EncodedString())
        }
        return fields
    }
}
