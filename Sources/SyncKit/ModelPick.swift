import Foundation

// The models a Mac offers for its chats, said in its `commandcap` record so
// an iPhone can pick one (and how hard it thinks) for a new chat or the
// next words of one (docs/sync.md, "Chats and words from the iPhone").

/// A model a Mac can start a chat's agent on, as its own model picker
/// lists it (AgentModels).
public struct SyncMacModel: Equatable, Sendable, Identifiable {
    /// "claude" or "codex": the agent that runs it.
    public var cli: String
    /// What the agent is told (`--model`, `-m`).
    public var model: String
    public var name: String
    public var about: String
    /// The reasoning efforts it takes, least first ("low", "xhigh"…).
    public var efforts: [String]

    public var id: String { cli + ":" + model }

    public init(cli: String, model: String, name: String, about: String = "", efforts: [String] = []) {
        self.cli = cli; self.model = model; self.name = name; self.about = about; self.efforts = efforts
    }

    public var value: Value {
        .object(["cli": .string(cli), "model": .string(model), "name": .string(name), "about": .string(about),
                 "efforts": .array(efforts.map(Value.string))])
    }

    public init?(_ value: Value) {
        guard let o = value.object, let cli = o["cli"]?.string, ChatAgent(rawValue: cli) != nil,
              let model = o["model"]?.string, !model.isEmpty else { return nil }
        self.init(cli: cli, model: model, name: o["name"]?.string ?? model, about: o["about"]?.string ?? "",
                  efforts: o["efforts"]?.array?.compactMap(\.string) ?? [])
    }

    /// The group a model is listed under, by its agent's plan.
    public static func plan(_ cli: String) -> String { ["codex": "ChatGPT", "cursor": "Cursor", "gemini": "Gemini", "opencode": "OpenCode"][cli] ?? "Claude" }

    /// An effort as the Mac's picker says it: "Low", "Extra high".
    public static func effortTitle(_ effort: String) -> String {
        effort == "xhigh" ? "Extra high" : effort.prefix(1).uppercased() + effort.dropFirst()
    }
}

/// Picking a chat's model and effort from the iPhone: what a Mac offers, in
/// its `commandcap` record (`models`, `modelPick`), and the `model` and
/// `effort` of a `send`.
public enum ModelPick {
    public static let version = 1
    /// The capability field, and the field listing the models.
    public static let field = "modelPick", modelsField = "models"

    public static func supports(_ record: Record?, device: String) -> Bool {
        guard let record, record.collection == OpenOnMac.capability,
              record.id == device, record.alive(), record["device"]?.string == device else { return false }
        return record[field]?.number == Double(version)
    }

    /// The models the Mac offers, in its picker's order; none from a Mac
    /// that doesn't take a pick.
    public static func models(_ record: Record?, device: String) -> [SyncMacModel] {
        guard supports(record, device: device) else { return [] }
        return (record?[modelsField]?.array ?? []).compactMap(SyncMacModel.init)
    }

    /// The fields a Mac writes into its capability record.
    public static func fields(_ models: [SyncMacModel]) -> SyncFields {
        models.isEmpty ? [field: .null, modelsField: .null]
            : [field: .number(Double(version)), modelsField: .array(models.map(\.value))]
    }
}
