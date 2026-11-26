import Testing
@testable import Fast

/// The model picker's effort as you move through its list: one effort that
/// follows you, as the Settings field keeps it, said only where it is taken.
struct PickerEffortTests {
    private let terra = AgentModel(cli: "codex", model: "gpt-6.1-terra", name: "GPT-6.1 Terra", about: "",
                                   efforts: ["low", "medium", "high", "xhigh", "max", "ultra"])
    private let sol = AgentModel(cli: "codex", model: "gpt-6-sol", name: "GPT-6 Sol", about: "",
                                 efforts: ["low", "medium", "high", "xhigh", "max", "ultra"])
    private let luna = AgentModel(cli: "codex", model: "gpt-6-luna", name: "GPT-6 Luna", about: "",
                                  efforts: ["low", "medium", "high", "xhigh", "max"])
    private let opus = AgentModel(cli: "claude", model: "opus", name: "Claude Opus", about: "",
                                  efforts: ["low", "medium", "high", "xhigh", "max"])
    private let mac = AgentModel(cli: "mac", model: "", name: "Apple Intelligence", about: "", efforts: [])

    @Test func theEffortInUseStaysWhileYouMoveAwayAndBack() {
        var effort = PickerEffort(picked: "high")
        #expect(effort.on(terra) == "high")
        #expect(effort.on(sol) == "high")
        #expect(effort.on(terra) == "high")
        effort.turn(terra, by: 1)
        #expect(effort.on(sol) == "xhigh")
        #expect(effort.on(terra) == "xhigh")
    }

    @Test func aModelThatDoesNotTakeTheEffortSaysAuto() {
        let effort = PickerEffort(picked: "ultra")
        #expect(effort.on(terra) == "ultra")
        #expect(effort.on(luna) == nil)
        #expect(effort.on(opus) == nil)
        #expect(effort.on(mac) == nil)
        // Passing through a model that can't take it doesn't lose it.
        #expect(effort.on(sol) == "ultra")
    }

    @Test func arrowsStepFromWhatTheModelShows() {
        var effort = PickerEffort(picked: "ultra")
        effort.turn(luna, by: 1)
        #expect(effort.on(luna) == "low")
        effort.turn(luna, by: -1)
        #expect(effort.on(luna) == nil)
        effort.turn(luna, by: -1)
        #expect(effort.on(luna) == nil)
        effort.turn(luna, by: 9)
        #expect(effort.on(luna) == "max")
        effort.turn(mac, by: 1)
        #expect(effort.picked == "max")
    }
}
