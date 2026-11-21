import Foundation
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct ThriftWatchTests {
    @Test func everyWatcherHearsPowerSavingStart() {
        final class Owner {}
        let first = Owner(), second = Owner()
        var heard: [String] = []
        // From not saving, whatever this Mac's setting and battery say.
        let held = Store.settings.object(forKey: EnergySaver.key)
        Store.settings.removeObject(forKey: EnergySaver.key)
        Thrift.forced = false
        Thrift.look()
        Thrift.watch(first) { if $0 { heard.append("first") } }
        Thrift.watch(second) { if $0 { heard.append("second") } }
        defer {
            Thrift.unwatch(first); Thrift.unwatch(second)
            Store.settings.set(held, forKey: EnergySaver.key)
            Thrift.forced = false
            Thrift.look()
        }
        Thrift.forced = true
        #expect(heard.sorted() == ["first", "second"])
        Thrift.forced = false
        Thrift.unwatch(first)
        heard = []
        Thrift.forced = true
        #expect(heard == ["second"])
    }
}
