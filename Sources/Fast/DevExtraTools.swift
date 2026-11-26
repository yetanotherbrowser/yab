import AppKit
import SwiftUI

struct DevExtraTool: View {
    let browser: Browser
    @ObservedObject var model: DevWorkbench
    let tool: DevTool
    @State private var rows: [DevProperty] = []
    @State private var overviewColors: [DevProperty] = []
    @State private var overviewFonts: [DevProperty] = []
    @State private var overviewMedia: [String] = []
    @State private var query = ""
    @State private var searchResults: [[String: Any]] = []
    @State private var buffer = "new Uint8Array([1, 2, 3]).buffer"
    @State private var offset = "0"
    @State private var coverage = false
    @State private var paint = false
    @State private var rulers = false
    @State private var motion = false
    @State private var printMedia = false
    @State private var latitude = "37.7749"
    @State private var longitude = "-122.4194"
    @State private var language = "en-US"
    @State private var concurrency = "8"
    @State private var alpha = "0"
    @State private var beta = "0"
    @State private var gamma = "0"
    @State private var animationRows: [[String: Any]] = []
    @State private var speed = 1.0
    @State private var audioNodes: [[String: Any]] = []
    @State private var audioEdges: [[String: Any]] = []
    var body: some View {
        VStack(spacing: 0) {
            if !model.error.isEmpty { Text(model.error).font(.system(size: 11.5)).foregroundStyle(DevLook.errorInk).padding(8).frame(maxWidth: .infinity, alignment: .leading) }
            switch tool {
            case .rendering: rendering
            case .sensors: sensors
            case .animations: animations
            case .memoryInspector: memoryInspector
            case .webAuthn: DevQuiet(words: "Virtual WebAuthn authenticators are unavailable in WebKit")
            case .webAudio: webAudio
            default: generic
            }
        }
        .onChange(of: tool, initial: true) { rows = []; refresh() }
        .task(id: tool) {
            guard tool == .performanceMonitor || tool == .media else { return }
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)); if !Task.isCancelled { refresh() } }
        }
    }
    private var generic: some View {
        VStack(spacing: 0) {
            DevPanelBar {
                if tool == .search {
                    TextField("Search in all resources", text: $query).textFieldStyle(.plain).onSubmit(refresh)
                    Button("Search") { refresh() }
                } else if tool == .coverage {
                    Button(coverage ? "Stop and show coverage" : "Start coverage") {
                        if coverage { refreshCoverage { browser.workCall("Runtime.disableControlFlowProfiler"); coverage = false } }
                        else { browser.workCall("Runtime.enableControlFlowProfiler") { _ in coverage = model.error.isEmpty; if coverage { browser.active?.page.reload(fromOrigin: false) } } }
                    }
                    Text("JavaScript basic blocks").foregroundStyle(Palette.muted)
                } else {
                    Button("Refresh") { refresh() }
                }
                Spacer(minLength: 4)
                Button("Copy for Agent") { browser.copyForAgent(rows.map { $0.name + ": " + $0.value }.joined(separator: "\n"), "Copied " + tool.rawValue) }.disabled(rows.isEmpty)
            }
            Divider()
            ThreadScrollView {
                if tool == .search {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(searchResults.enumerated()), id: \.offset) { _, result in
                            let url = result["url"] as? String ?? ""
                            Button { openSearchResult(result) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(url).lineLimit(1)
                                    Text(verbatim: "\(result["matchesCount"] ?? 0) matches").foregroundStyle(Palette.muted)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }.buttonStyle(.plain)
                        }
                        if searchResults.isEmpty { Text("No matches").foregroundStyle(Palette.muted).padding(8) }
                    }.font(.system(size: 11.5))
                } else if tool == .cssOverview { cssOverview }
                else { DevDataRows(rows: rows) }
            }
        }
    }
    private var cssOverview: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            Text("Colors · \(overviewColors.count)").fontWeight(.semibold)
            ForEach(overviewColors, id: \.name) { row in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: Radius.small).fill(ConsoleCSS.color(row.name) ?? .clear)
                        .overlay(RoundedRectangle(cornerRadius: Radius.small).stroke(Palette.muted.opacity(0.4)))
                        .frame(width: 20, height: 20)
                    Text(row.name).font(DevMono.font(11.5)).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Text(row.value + " uses").foregroundStyle(Palette.muted)
                }
            }
            Divider()
            Text("Font families · \(overviewFonts.count)").fontWeight(.semibold)
            ForEach(overviewFonts, id: \.name) { row in
                HStack { Text(row.name); Spacer(); Text(row.value + " elements").foregroundStyle(Palette.muted) }
            }
            Divider()
            Text("Media queries · \(overviewMedia.count)").fontWeight(.semibold)
            if overviewMedia.isEmpty { Text("No media queries").foregroundStyle(Palette.muted) }
            ForEach(overviewMedia, id: \.self) { Text($0).textSelection(.enabled) }
        }.font(.system(size: 11.5)).padding(12)
    }
    private func openSearchResult(_ result: [String: Any]) {
        let url = result["url"] as? String ?? ""
        browser.workCall("Page.searchInResource", ["frameId": result["frameId"] ?? "", "url": url, "query": query, "caseSensitive": false, "isRegex": false]) { value in
            let line = (((value as? [String: Any])?["result"] as? [[String: Any]])?.first?["lineNumber"] as? Int) ?? 0
            browser.workCall("sources.files") { value in
                model.sources = (value as? [[String: Any]] ?? []).map { DevSource(script: $0["id"] as? String ?? "", url: $0["url"] as? String ?? "", target: $0["target"] as? String ?? "", frame: $0["frame"] as? String ?? "", kind: $0["type"] as? String ?? "script") }
                if let file = model.sources.first(where: { $0.url == url }) { browser.pickDevPane(.sources); browser.sourceOpen(file, line: line) }
            }
        }
    }
    private var rendering: some View {
        ThreadScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Paint flashing", isOn: $paint).onChange(of: paint) { browser.workCall("Page.setShowPaintRects", ["result": paint]) }
                Toggle("Show rulers", isOn: $rulers).onChange(of: rulers) { browser.workCall("Page.setShowRulers", ["result": rulers]) }
                Toggle("Emulate reduced motion", isOn: $motion).onChange(of: motion) { browser.workCall("Page.overrideUserPreference", ["name": "PrefersReducedMotion", "value": motion ? "Reduce" : "NoPreference"]) }
                Toggle("Emulate print media", isOn: $printMedia).onChange(of: printMedia) { browser.workCall("Page.setEmulatedMedia", ["media": printMedia ? "print" : ""]) }
                HStack(spacing: 8) {
                    Text("Color scheme")
                    Button("System") { browser.setDevAppearance(nil) }
                    Button("Light") { browser.setDevAppearance("Light") }
                    Button("Dark") { browser.setDevAppearance("Dark") }
                }
                ForEach([DevOverride.images, .styles, .scripts], id: \.self) { setting in
                    Button(setting.title) { browser.toggleDevOverride(setting) }
                }
                Text("Overrides last while DevTools is open. CPU throttling, forced colors and Chromium paint profiling are unavailable.").foregroundStyle(Palette.muted)
            }.font(.system(size: 11.5)).padding(16).buttonStyle(.yab(.quiet, .small))
        }
    }
    private var sensors: some View {
        ThreadScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Latitude").frame(width: 100, alignment: .leading); TextField("Latitude", text: $latitude); Text("Longitude"); TextField("Longitude", text: $longitude) }
                HStack { Text("Locale").frame(width: 100, alignment: .leading); TextField("Language", text: $language); Text("CPU threads"); TextField("Concurrency", text: $concurrency) }
                HStack { Text("Orientation").frame(width: 100, alignment: .leading); TextField("α", text: $alpha); TextField("β", text: $beta); TextField("γ", text: $gamma) }
                HStack { Button("Apply to current document") {
                    guard let lat = Double(latitude), let lon = Double(longitude), (-90...90).contains(lat), (-180...180).contains(lon) else { model.error = "Latitude or longitude is out of range"; return }
                    browser.workCall("tools.sensors", ["latitude": lat, "longitude": lon, "language": language, "concurrency": max(1, Int(concurrency) ?? 8), "alpha": Double(alpha) ?? 0, "beta": Double(beta) ?? 0, "gamma": Double(gamma) ?? 0])
                }; Button("Reset overrides") { browser.workCall("tools.sensorsReset") } }
                Text("These are script overrides for the current document. WebKit does not emulate a timezone, touch hardware or the Idle Detector.").foregroundStyle(Palette.muted)
            }.font(.system(size: 11.5)).padding(16).textFieldStyle(.roundedBorder).buttonStyle(.yab(.quiet, .small))
        }
    }
    private var animations: some View {
        VStack(spacing: 0) {
            DevPanelBar {
                Button("Refresh") { refresh() }
                Button("Pause all") { animationRows.forEach { control($0, "pause") } }
                Button("Play all") { animationRows.forEach { control($0, "play") } }
                Picker("Speed", selection: $speed) { Text("100%").tag(1.0); Text("25%").tag(0.25); Text("10%").tag(0.1) }.frame(width: 120).onChange(of: speed) { animationRows.forEach { control($0, "rate", speed) } }
                Spacer(minLength: 0)
            }
            Divider()
            ThreadScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(animationRows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 8) {
                            Text(row["name"] as? String ?? "Animation").fontWeight(.medium)
                            Text(row["state"] as? String ?? "").foregroundStyle(Palette.muted)
                            Button("Pause") { control(row, "pause") }; Button("Play") { control(row, "play") }; Button("Replay") { control(row, "time", 0); control(row, "play") }
                        }.font(.system(size: 11.5))
                        if let id = row["id"] {
                            let timing = row["timing"] as? [String: Any] ?? [:]
                            let duration = max(1, timing["duration"] as? Double ?? 1000)
                            Slider(value: Binding(get: { min(duration, max(0, row["time"] as? Double ?? row["currentTime"] as? Double ?? 0)) }, set: { browser.workCall("tools.animation", ["id": id, "action": "time", "value": $0]) { _ in refresh() } }), in: 0...duration).keyTip("Scrub animation")
                        }
                        DevDataRows(rows: [DevProperty(name: "Timing", value: DevWorkbench.string(row["timing"])), DevProperty(name: "Keyframes", value: DevWorkbench.string(row["keyframes"]))])
                    }
                    if animationRows.isEmpty { Text("No active animations").foregroundStyle(Palette.muted).font(.system(size: 11.5)).padding(8) }
                }.padding(8).buttonStyle(.yab(.quiet, .small))
            }
        }
    }
    private var memoryInspector: some View {
        VStack(spacing: 0) {
            DevPanelBar {
                TextField("ArrayBuffer expression", text: $buffer).textFieldStyle(.plain).onSubmit(refresh)
                TextField("Offset", text: $offset).textFieldStyle(.plain).frame(width: 70)
                Button("Inspect") { refresh() }
            }
            Text("Runs the expression when you press Inspect. 256 bytes are shown from the selected offset.").font(.system(size: 10)).foregroundStyle(Palette.muted).padding(8)
            ThreadScrollView { DevDataRows(rows: rows) }
        }
    }
    private var webAudio: some View {
        VStack(spacing: 0) {
            DevPanelBar {
                Button("Track new AudioContexts") { browser.workCall("tools.audioStart") { _ in refresh() } }
                Button("Refresh") { refresh() }
                Button("Stop tracking") { browser.workCall("tools.audioStop") { _ in rows = []; audioNodes = []; audioEdges = [] } }
                Spacer(minLength: 0)
            }
            Text("Only AudioContexts created after tracking starts can be inspected. Reload resets tracking.").font(.system(size: 10)).foregroundStyle(Palette.muted).padding(8)
            if !audioNodes.isEmpty {
                ThreadScrollView(.horizontal) {
                    Canvas { context, size in
                        for edge in audioEdges {
                            guard let from = edge["from"] as? Int, let to = edge["to"] as? Int else { continue }
                            var path = Path(); path.move(to: CGPoint(x: Double(from) * 150 + 135, y: 36)); path.addLine(to: CGPoint(x: Double(to) * 150 + 8, y: 36))
                            context.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
                        }
                        for node in audioNodes {
                            let id = node["id"] as? Int ?? 0
                            let rect = CGRect(x: Double(id) * 150 + 8, y: 12, width: 127, height: 48)
                            context.fill(Path(roundedRect: rect, cornerRadius: Radius.small), with: .color(Palette.ink.opacity(0.08)))
                            context.draw(Text(node["type"] as? String ?? "AudioNode").font(.system(size: 10)), at: CGPoint(x: rect.midX, y: rect.midY))
                        }
                    }.frame(width: Double(audioNodes.count) * 150, height: 72)
                }
            }
            ThreadScrollView { DevDataRows(rows: rows) }
        }
    }
    private func control(_ row: [String: Any], _ action: String, _ value: Double = 0) { browser.workCall("tools.animation", ["id": row["id"] ?? 0, "action": action, "value": value]) { _ in refresh() } }
    private func refreshCoverage(_ done: @escaping () -> Void = {}) {
        browser.workCall("tools.coverage") { value in
            rows = (value as? [[String: Any]] ?? []).map { file in
                let blocks = file["blocks"] as? [[String: Any]] ?? []
                let used = blocks.filter { ($0["hasExecuted"] as? Bool ?? false) }.count
                return DevProperty(name: URL(string: file["url"] as? String ?? "")?.lastPathComponent ?? "script", value: "\(used)/\(blocks.count) blocks executed")
            }
            done()
        }
    }
    private func refresh() {
        switch tool {
        case .animations: browser.workCall("tools.animations") { animationRows = $0 as? [[String: Any]] ?? [] }
        case .coverage: refreshCoverage()
        case .changes: rows = model.changes
        case .cssOverview:
            browser.workCall("tools.cssOverview") { value in
                let data = value as? [String: Any] ?? [:]
                @MainActor func counts(_ key: String) -> [DevProperty] {
                    (data[key] as? [String: Any] ?? [:]).map { DevProperty(name: $0.key, value: DevWorkbench.string($0.value)) }
                        .sorted { (Int($0.value) ?? 0) == (Int($1.value) ?? 0) ? $0.name < $1.name : (Int($0.value) ?? 0) > (Int($1.value) ?? 0) }
                }
                overviewColors = counts("colors"); overviewFonts = counts("fonts")
                overviewMedia = Array(Set(data["media"] as? [String] ?? [])).sorted()
                rows = overviewColors + overviewFonts + overviewMedia.map { DevProperty(name: "Media query", value: $0) }
            }
        case .issues: rows = browser.toolsFront?.devLog.entries.map { DevProperty(name: $0.level.rawValue, value: $0.text) } ?? []
        case .search:
            guard !query.isEmpty else { return }
            browser.workCall("Page.searchInResources", ["text": query, "caseSensitive": false, "isRegex": false]) { value in
                searchResults = (value as? [String: Any])?["result"] as? [[String: Any]] ?? []
                var seen: Set<String> = []
                searchResults = searchResults.filter { seen.insert(($0["frameId"] as? String ?? "") + "|" + ($0["url"] as? String ?? "")).inserted }
                rows = searchResults.map { DevProperty(name: $0["url"] as? String ?? "", value: DevWorkbench.string($0)) }
            }
        case .developerResources:
            browser.workCall("sources.files") { value in rows = (value as? [[String: Any]] ?? []).map { DevProperty(name: URL(string: $0["url"] as? String ?? "")?.lastPathComponent ?? "Resource", value: $0["url"] as? String ?? "") } }
        case .memoryInspector:
            browser.workCall("tools.buffer", ["expression": buffer, "offset": max(0, Int(offset) ?? 0)]) { value in
                let data = value as? [String: Any] ?? [:]; let bytes = data["bytes"] as? [Int] ?? []
                rows = stride(from: 0, to: bytes.count, by: 16).map { at in
                    let chunk = Array(bytes[at..<min(bytes.count, at + 16)])
                    return DevProperty(name: String(format: "%08x", (Int(offset) ?? 0) + at), value: chunk.map { String(format: "%02x", $0) }.joined(separator: " ") + "  " + chunk.map { (32...126).contains($0) ? String(UnicodeScalar($0)!) : "." }.joined())
                }
            }
        case .media: read("tools.media")
        case .performanceMonitor: read("tools.performanceMonitor")
        case .layers: read("tools.layers")
        case .autofill: read("tools.forms")
        case .webAudio:
            browser.workCall("tools.audio") { value in
                let data = value as? [String: Any] ?? [:]
                audioNodes = data["nodes"] as? [[String: Any]] ?? []; audioEdges = data["edges"] as? [[String: Any]] ?? []
                rows = (data["contexts"] as? [[String: Any]] ?? []).enumerated().map { DevProperty(name: "Context \($0.offset)", value: DevWorkbench.string($0.element)) }
            }
        default: break
        }
    }
    private func read(_ method: String) {
        browser.workCall(method) { value in
            if let data = value as? [String: Any] { rows = data.keys.sorted().map { DevProperty(name: $0, value: DevWorkbench.string(data[$0])) } }
            else if let list = value as? [[String: Any]] { rows = list.enumerated().map { DevProperty(name: "#\($0.offset)", value: DevWorkbench.string($0.element)) } }
        }
    }
}
