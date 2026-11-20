import Foundation

/// A recovery migration (#909): shared pins left in their file while they
/// aren't shared (Pins turned off by sync with no window open to turn them)
/// become pins of `home`, at its head, as turning them off gives them
/// (`SharedPins.heir`). Only where no window holds `home`'s row: at launch,
/// before the row is read, or with no window open. Otherwise they lay hidden
/// while sync still sent them, and with that stopped (`syncRow`) would be
/// gone from every device.
///
/// The pins' file is cleared only once `home`'s row with them is saved and
/// reads back so; a failed save leaves it as it was, for the next launch.
/// A pin `home` already has (a run that saved `home` and stopped before
/// clearing) is not added twice.
enum PinsHandBack {
    /// Where the migration reads and saves rows: the session files, or a
    /// test's.
    struct Rows {
        var read: (UUID) -> Session.Shape
        var save: (UUID, Session.Shape) throws -> Void

        static var files: Rows { Rows(read: { Session.read(space: $0) }, save: { try Session.save(space: $0, $1) }) }
    }

    /// `pins` at the head of `home`, less any `home` already holds by id,
    /// their pairs kept among the pins that remain.
    static func merged(_ pins: Session.Shape, into home: Session.Shape) -> Session.Shape {
        let held = Set(home.tabs.compactMap(\.id))
        let kept = pins.tabs.indices.filter { pins.tabs[$0].id.map { !held.contains($0) } ?? true }
        let at = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($1, $0) })
        let pairs = (pins.pairs ?? []).compactMap { pair -> Session.Pair? in
            guard let a = at[pair.first], let b = at[pair.second] else { return nil }
            return Session.Pair(first: a, second: b, share: pair.share)
        }
        return SharedPins.folded(kept.map { pins.tabs[$0] }, into: home, pinPairs: pairs)
    }

    /// Runs the migration: true once the pins are in `home` and their file
    /// is clear.
    @discardableResult
    static func run(to home: UUID, rows: Rows = .files) -> Bool {
        let pins = rows.read(Space.pinsID)
        guard !pins.tabs.isEmpty else { return false }
        let row = merged(pins, into: rows.read(home))
        do {
            try rows.save(home, row)
        } catch {
            DebugLog.note("pins-hand-back", ["result": "home not saved", "error": "\(error)"])
            return false
        }
        guard marks(rows.read(home)) == marks(row) else {
            DebugLog.note("pins-hand-back", ["result": "home reads back otherwise"])
            return false
        }
        do {
            try rows.save(Space.pinsID, .init(tabs: [], active: 0))
        } catch {
            // Home has them; the next run finds them there and adds none.
            DebugLog.note("pins-hand-back", ["result": "pins not cleared", "error": "\(error)"])
            return false
        }
        return true
    }

    private static func marks(_ shape: Session.Shape) -> [String] {
        shape.tabs.map { "\($0.id ?? "")|\($0.url)|\($0.pin ?? "")" }
    }
}
