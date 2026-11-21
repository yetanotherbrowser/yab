import Foundation

/// Which pages in the bench's room draw at their display's rate. A page there
/// is drawn as if someone looked at it, so that it behaves for its agent as a
/// page in front of someone does, but no one does: between its agent's calls
/// it can draw slowly (Bench.paceRoom). It draws at the display's rate while a
/// call that names it is in flight, and so does a page woken by a call that
/// named none (`open`), until none of its agent's calls is in flight.
struct BenchPace {
    private(set) var calls = 0
    private var agents: [String: Int] = [:]
    private var named: [ObjectIdentifier: Int] = [:]
    private var loose: [ObjectIdentifier: String] = [:]

    mutating func began(for agent: String) {
        calls += 1
        agents[agent, default: 0] += 1
    }

    mutating func names(_ page: ObjectIdentifier) { named[page, default: 0] += 1 }

    mutating func ended(for agent: String, naming page: ObjectIdentifier?) {
        calls = max(calls - 1, 0)
        if let page, let count = named[page] { named[page] = count > 1 ? count - 1 : nil }
        if let count = agents[agent], count > 1 { agents[agent] = count - 1; return }
        agents[agent] = nil
        loose = loose.filter { $0.value != agent }
    }

    /// The bench took the page into its room. Woken by Yab itself, with no
    /// call of its agent in flight, it is not kept awake for the next one.
    mutating func woke(_ page: ObjectIdentifier, for agent: String) {
        if named[page] == nil, agents[agent] != nil { loose[page] = agent }
    }

    mutating func forget(_ page: ObjectIdentifier) { loose[page] = nil }

    func awake(_ page: ObjectIdentifier) -> Bool {
        named[page] != nil || loose[page].map { agents[$0] != nil } == true
    }
}
