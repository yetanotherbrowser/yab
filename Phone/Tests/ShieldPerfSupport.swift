import UIKit
import WebKit
import XCTest
@testable import YabPhone

@_silgen_name("proc_pid_rusage")
private func perfRusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32

/// What the opt-in Shield perf tests share: the switch (YAB_PERF=1, or
/// TEST_RUNNER_YAB_PERF=1 through xcodebuild), the real lists built once a
/// run by Shield itself, memory readings and where results go.
@MainActor
enum ShieldPerf {
    static let environment = ProcessInfo.processInfo.environment
    static var enabled: Bool { environment["YAB_PERF"] == "1" }

    static func int(_ key: String, _ fallback: Int) -> Int {
        environment[key].flatMap(Int.init) ?? fallback
    }

    /// The week's lists, fetched on the first use and kept in Caches so
    /// later tests and runs only look them up.
    static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("yab-shield-perf", isDirectory: true)

    private static var made: [Bool: Shield] = [:]

    /// A Shield over the real lists, its scriptlets on or off.
    static func shield(scriptlets: Bool) async throws -> Shield {
        if let shield = made[scriptlets] { return shield }
        if scriptlets == false { _ = try await shield(scriptlets: true) }
        let shield = Shield(folder: folder, fetches: false)
        shield.scriptletsAllowed = scriptlets
        shield.start()
        await shield.settled()
        if (shield.made?.rules ?? 0) < 50_000 {
            shield.refresh(now: true)
            await shield.settled()
        }
        try XCTSkipIf(shield.lists.count < 2 || (shield.made?.rules ?? 0) < 50_000, "the lists didn't arrive (network?): \(shield.report)")
        if scriptlets { _ = try XCTUnwrap(shield.scriptlets, "the real lists made no scriptlets") }
        else { XCTAssertNil(shield.scriptlets) }
        made[scriptlets] = shield
        return shield
    }

    static func window() throws -> UIWindow {
        try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first)
    }

    /// A process's physical footprint in MB (rusage_info_v4.ri_phys_footprint,
    /// at byte 72); nil where the sandbox won't say (a device).
    static func footprint(_ pid: Int32) -> Double? {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 512, alignment: 8)
        defer { buffer.deallocate() }
        guard perfRusage(pid, 4, buffer) == 0 else { return nil }
        return Double(buffer.load(fromByteOffset: 72, as: UInt64.self)) / 1_048_576
    }

    static func webProcess(_ view: WKWebView) -> Int32? {
        guard view.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let pid = (view.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }

    /// This process's footprint now and at its height, in MB.
    static func app() -> (now: Double, peak: Double)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }

    static var device: [String: Any] {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        #if targetEnvironment(simulator)
        let simulated = true
        #else
        let simulated = false
        #endif
        return ["machine": String(cString: machine), "model": environment["SIMULATOR_MODEL_IDENTIFIER"] ?? UIDevice.current.model,
                "os": os, "simulator": simulated, "idiom": UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone"]
    }

    /// Printed as one line (SHIELD_PERF <name> <json>), attached to the
    /// result bundle, and written to YAB_PERF_OUT when it names a folder.
    static func emit(_ name: String, _ object: [String: Any], in test: XCTestCase) {
        var object = object
        object["device"] = device
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            XCTFail("\(name): not JSON")
            return
        }
        print("SHIELD_PERF \(name) " + (String(data: data, encoding: .utf8) ?? ""))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "shield-perf-\(name).json"
        attachment.lifetime = .keepAlways
        test.add(attachment)
        if let path = environment["YAB_PERF_OUT"], !path.isEmpty {
            let out = URL(fileURLWithPath: path, isDirectory: true)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try? data.write(to: out.appendingPathComponent("shield-perf-\(name).json"))
        }
    }

    @MainActor
    final class Watcher: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Bool, Never>?
        func finish(_ ok: Bool) { done?.resume(returning: ok); done = nil }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
    }

    /// Starts a navigation and waits for it to finish, fail or time out.
    static func navigate(_ view: WKWebView, seconds: Double, _ start: (WKWebView) -> Void) async -> Bool {
        let watcher = Watcher()
        let previous = view.navigationDelegate
        view.navigationDelegate = watcher
        defer { view.navigationDelegate = previous }
        return await withCheckedContinuation { done in
            watcher.done = done
            start(view)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                watcher.finish(false)
            }
        }
    }

    static func evaluate(_ view: WKWebView, _ script: String) async -> Any? {
        await withCheckedContinuation { done in
            view.evaluateJavaScript(script, in: nil, in: .page) { outcome in
                if case let .success(value) = outcome { done.resume(returning: value) } else { done.resume(returning: nil) }
            }
        }
    }

    /// Main-thread gaps of this process while it runs: a timer every 5 ms
    /// that should never be late by more than a frame.
    final class Lag {
        private var timer: DispatchSourceTimer?
        private var last = CACurrentMediaTime()
        private(set) var worst = 0.0
        private(set) var over50 = 0
        private(set) var over17 = 0

        func start() {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
            last = CACurrentMediaTime()
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let now = CACurrentMediaTime()
                let gap = (now - self.last) * 1000
                self.last = now
                self.worst = max(self.worst, gap)
                if gap > 17 { self.over17 += 1 }
                if gap > 50 { self.over50 += 1 }
            }
            timer.resume()
            self.timer = timer
        }

        func stop() {
            timer?.cancel()
            timer = nil
        }
    }
}
