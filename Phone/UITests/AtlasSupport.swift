import UIKit
import XCTest

/// What the atlas, accessibility, perf and film tests share: the app launched
/// in a named state, the moment it says it has settled, and files written
/// straight to the Mac running the simulator (a simulator's processes can
/// reach the Mac's folders), where Phone/scripts/phone collects them.
///
/// The script hands these over as TEST_RUNNER_ variables (xcodebuild passes
/// them to the test runner without the prefix):
///
///     YAB_OUT      the job's output folder on the Mac
///     YAB_WORLD    the world (default mira)
///     YAB_MODEL    the simulator's model name, for folder names (default pro)
///     YAB_STATES   comma separated states; default every registered one
///
/// A state counts only when its ready marker says settled=yes: a page that
/// never drew is taken again and, if it still hasn't, fails the test rather
/// than passing on a blank picture.
enum Atlas {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var out: URL {
        if let path = environment["YAB_OUT"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("yab-atlas")
    }

    static var world: String { environment["YAB_WORLD"].flatMap { $0.isEmpty ? nil : $0 } ?? "mira" }
    static var model: String { environment["YAB_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? "pro" }
    static var deviceWord: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    /// A fresh folder for ready markers, so an old marker never counts.
    static func readyFolder() -> URL {
        let folder = out.appendingPathComponent(".ready/\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// How a named state's launch went, from its ready marker
    /// (Testing/StateCatalog.swift, StateRunner): settled=yes is the only
    /// state worth a picture or an audit.
    enum Settle: Equatable {
        /// The marker came and the page had drawn.
        case settled
        /// The marker came with settled=no: the page never drew in time.
        case notPainted
        /// No marker in time: the launch itself was slow or stuck.
        case noMarker
        /// The app has no state of that name (it set up the world's start).
        case unknown

        var words: String {
            switch self {
            case .settled: return "settled"
            case .notPainted: return "the page never drew (settled=no)"
            case .noMarker: return "no ready marker in time"
            case .unknown: return "no state of that name in the app"
            }
        }
    }

    /// The first launch of a test process waits longer: after an install the
    /// web process starts cold, a minute and more on a loaded Mac.
    private static var cold = true
    /// When the last take was launched, for `picture`.
    private static var launchedAt = Date()

    /// The screen once it has stopped changing, the same way every time (the
    /// system's chrome could still be changing the moment a state settled):
    /// not before 2.5 s from the launch, then until two pictures in a row are
    /// the same (three at most), as Phone/scripts/phone shot does.
    static func picture() -> XCUIScreenshot {
        let left = 2.5 - Date().timeIntervalSince(launchedAt)
        if left > 0 { Thread.sleep(forTimeInterval: left) }
        var shot = XCUIScreen.main.screenshot()
        for _ in 0..<2 {
            Thread.sleep(forTimeInterval: 0.3)
            let next = XCUIScreen.main.screenshot()
            if next.pngRepresentation == shot.pngRepresentation { break }
            shot = next
        }
        return shot
    }

    /// The app in a named state, settled: true only when its marker says the
    /// page drew (settled=yes). See `open` for the takes.
    @discardableResult
    static func launch(_ app: XCUIApplication, state: String, ready: URL, still: Bool = true,
                       extra: [String] = [], environment: [String: String] = [:], timeout: TimeInterval = 60) -> Bool {
        open(app, state: state, ready: ready, still: still, extra: extra, environment: environment, timeout: timeout) == .settled
    }

    /// The app in a named state, and how it went. A take whose page never
    /// drew, or that wrote no marker in time, is taken again, up to `takes`
    /// (a cold web process on a busy Mac); an unknown name is not.
    static func open(_ app: XCUIApplication, state: String, ready: URL, still: Bool = true, extra: [String] = [],
                     environment: [String: String] = [:], timeout: TimeInterval = 60, takes: Int = 3) -> Settle {
        var outcome = Settle.noMarker
        for take in 1...max(1, takes) {
            let marker = ready.appendingPathComponent(state)
            try? FileManager.default.removeItem(at: marker)
            app.launchArguments = ["-YabWorld", world, "-YabState", state] + (still ? ["-YabNoAnim", "YES"] : []) + extra
            app.launchEnvironment = environment.merging(["YAB_READY_DIR": ready.path]) { a, _ in a }
            launchedAt = Date()
            app.launch()
            let wait = cold ? max(timeout, 180) : timeout
            cold = false
            guard waitForFile(marker, timeout: wait) else {
                outcome = .noMarker
                print("atlas: \(state): no ready marker after \(Int(wait)) s (take \(take))")
                continue
            }
            let notes = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
            if notes.contains("unknown state") { return .unknown }
            let lines = notes.split(separator: "\n")
            if lines.contains("settled=no") {
                outcome = .notPainted
                print("atlas: \(state): the page hadn't drawn (take \(take))")
                continue
            }
            // Drawn once and gone by the marker: the web view has no page (its
            // web process ended on a loaded Mac), a blank picture.
            if lines.contains(where: { $0.hasPrefix("web: url=none ") }) {
                outcome = .notPainted
                print("atlas: \(state): the page went blank (take \(take))")
                continue
            }
            return .settled
        }
        return outcome
    }

    static func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// The states to walk: YAB_STATES, else the app's own catalog.
    static func states(_ app: XCUIApplication) -> [(name: String, title: String)] {
        if let list = environment["YAB_STATES"], !list.isEmpty {
            return list.split(separator: ",")
                .map { (name: String($0).trimmingCharacters(in: .whitespaces), title: "") }
                .filter { !$0.name.isEmpty }
        }
        let ready = readyFolder()
        app.launchArguments = ["-YabWorld", world, "-YabState", "catalog", "-YabNoAnim", "YES"]
        app.launchEnvironment = ["YAB_READY_DIR": ready.path]
        app.launch()
        let file = ready.appendingPathComponent("catalog.json")
        guard waitForFile(file, timeout: 180),
              let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let states = json["states"] as? [[String: Any]] else { return [] }
        return states.compactMap { s in (s["name"] as? String).map { (name: $0, title: s["title"] as? String ?? "") } }
    }

    static func write(_ data: Data, to path: String) {
        let url = out.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Every element with an identifier, the accessibility tree as XCTest
    /// sees it, in the same shape as the app's own frames dump.
    static func elements(_ app: XCUIApplication) -> [[String: Any]] {
        guard let root = try? app.snapshot() else { return [] }
        var out: [[String: Any]] = []
        func visit(_ node: XCUIElementSnapshot) {
            if !node.identifier.isEmpty {
                let f = node.frame
                func r(_ v: CGFloat) -> Double { (Double(v) * 100).rounded() / 100 }
                out.append(["id": node.identifier, "x": r(f.minX), "y": r(f.minY), "w": r(f.width), "h": r(f.height),
                            "label": node.label, "value": (node.value as? String) ?? "", "type": node.elementType.rawValue])
            }
            // The page's own markup isn't ours to compare.
            if node.elementType == .webView { return }
            node.children.forEach(visit)
        }
        visit(root)
        return out
    }

    /// A fresh file for the app's haptics journal (Design/Haptics.swift):
    /// launch with it as YAB_HAPTICS_JOURNAL, then read what played.
    static func hapticsJournal() -> URL {
        let url = out.appendingPathComponent("haptics/\(UUID().uuidString.prefix(8)).log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    /// The haptics played so far, in order: "light column", "selection space"…
    static func haptics(_ journal: URL) -> [String] {
        guard let text = try? String(contentsOf: journal, encoding: .utf8) else { return [] }
        // Each line is "<seconds> <kind> <reason>".
        return text.split(separator: "\n").map { line in
            line.split(separator: " ", maxSplits: 1).dropFirst().joined()
        }
    }

    static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}
