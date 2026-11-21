import AppKit
import SwiftUI

/// Chrome's Application hierarchy, backed by the inspected tab's real origins.
struct DevApplicationPane: View {
    let browser: Browser
    @ObservedObject var model: DevWorkbench
    @ObservedObject var app: DevApplicationModel
    @ObservedObject private var net = NetPrefs.shared
    @State private var editor = false
    @State private var key = ""
    @State private var value = ""
    @State private var cookie: [String: Any] = [:]
    @State private var previewTab = "Preview"
    @State private var pushPayload = ""
    init(browser: Browser, model: DevWorkbench) { self.browser = browser; self.model = model; app = model.application }
    private var section: ApplicationSection { app.selection.section }
    /// A table of one origin's data. A category row shows Chrome's category
    /// page, a database its summary, and neither has rows to filter or count.
    private var table: Bool {
        let s = app.selection
        return section.isTable && !s.category && !(section == .indexedDB && s.store.isEmpty) && !(section == .cache && s.cache.isEmpty)
    }
    var body: some View {
        DevApplicationSplit(sidebar: AnyView(navigation), detail: AnyView(
            VStack(spacing: 0) {
                toolbar
                Divider()
                if !app.error.isEmpty { errorBanner }
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if table { Divider(); status }
            }.frame(minWidth: 180, maxWidth: .infinity, maxHeight: .infinity)
        ))
        .font(.system(size: 11.5)).foregroundStyle(Palette.ink).background(Palette.ground)
        .onAppear {
            if let web = browser.toolsFront?.webKitOnly("WebKit application inspection", build: false) { app.install(web) }
            model.error = ""; refreshTree()
        }
        .onChange(of: model.navigationRevision) { refreshTree() }
        .onChange(of: app.selectionRevision) { model.applicationSection = app.selection.section.rawValue; refresh() }
        .sheet(isPresented: $editor) { recordEditor }
    }
    private var navigation: some View {
        ThreadScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(tree) { item in ApplicationTreeRow(item: item, depth: 0, app: app, select: select, expand: expand) }
            }.padding(.vertical, 8)
        }.background(Palette.ink.opacity(0.025)).accessibilityLabel("Application navigation")
    }
    private var tree: [ApplicationTreeItem] {
        func leaf(_ section: ApplicationSection) -> ApplicationTreeItem {
            let selection = section.category != nil ? ApplicationSelection(section: section, category: true) : ApplicationSelection(section: section, origin: app.origins.first?["origin"] as? String ?? "")
            return ApplicationTreeItem(id: "section:" + section.rawValue, title: section.rawValue, selection: selection, symbol: section.symbol)
        }
        var storage: [ApplicationTreeItem] = []
        for section in [ApplicationSection.local, .session, .indexedDB, .cookies, .cache] {
            var node = leaf(section)
            for info in app.origins {
                let origin = info["origin"] as? String ?? ""
                var selection = ApplicationSelection(section: section, origin: origin)
                var originNode = ApplicationTreeItem(id: "origin:" + selection.id, title: origin, selection: selection, symbol: section.symbol)
                if section == .indexedDB {
                    for database in info["databases"] as? [[String: Any]] ?? [] {
                        selection.database = database["name"] as? String ?? ""
                        var dbNode = ApplicationTreeItem(id: "db:" + selection.id, title: selection.database, selection: selection, symbol: "application.database")
                        let schemas = app.schemas[origin + "\u{1f}" + selection.database] ?? []
                        for schema in schemas {
                            var storeSelection = selection; storeSelection.store = schema["name"] as? String ?? ""
                            var storeNode = ApplicationTreeItem(id: "store:" + storeSelection.id, title: storeSelection.store, selection: storeSelection, symbol: "application.table")
                            for index in schema["indexes"] as? [[String: Any]] ?? [] {
                                var indexSelection = storeSelection; indexSelection.index = index["name"] as? String ?? ""
                                storeNode.children.append(ApplicationTreeItem(id: "index:" + indexSelection.id, title: indexSelection.index, selection: indexSelection, symbol: "list.bullet"))
                            }
                            dbNode.children.append(storeNode)
                        }
                        originNode.children.append(dbNode)
                    }
                } else if section == .cache {
                    for name in info["caches"] as? [String] ?? [] {
                        var s = selection; s.cache = name
                        originNode.children.append(ApplicationTreeItem(id: "cache:" + s.id, title: name, selection: s, symbol: "application.table"))
                    }
                }
                node.children.append(originNode)
            }
            storage.append(node)
        }
        storage += [leaf(.shared), leaf(.privateTokens), leaf(.interestGroups)]
        var frameNodes: [ApplicationTreeItem] = []
        func frameNode(_ frame: [String: Any]) -> ApplicationTreeItem {
            let id = frame["id"] as? String ?? "", url = frame["url"] as? String ?? ""
            let selection = ApplicationSelection(section: .frames, origin: frame["origin"] as? String ?? "", frame: id)
            let frameName = frame["name"] as? String ?? ""
            var node = ApplicationTreeItem(id: "frame:" + id, title: (frame["depth"] as? Int ?? 0) == 0 ? "top" : !frameName.isEmpty ? frameName : URL(string: url)?.host ?? "frame", selection: selection, symbol: "application.frame")
            for child in app.frames where child["parentId"] as? String == id { node.children.append(frameNode(child)) }
            let resources = frame["resources"] as? [[String: Any]] ?? []
            for type in Set(resources.compactMap { $0["type"] as? String }).sorted() {
                var group = ApplicationTreeItem(id: "resources:" + id + ":" + type, title: type.capitalized, selection: nil, symbol: "folder")
                for resource in resources where resource["type"] as? String == type {
                    let address = resource["url"] as? String ?? ""; var s = selection; s.resource = address
                    group.children.append(ApplicationTreeItem(id: s.id, title: URL(string: address)?.lastPathComponent ?? address, selection: s, symbol: "doc.text"))
                }
                node.children.append(group)
            }
            return node
        }
        for frame in app.frames where (frame["depth"] as? Int ?? 0) == 0 { frameNodes.append(frameNode(frame)) }
        return [
            ApplicationTreeItem(id: "application", title: "Application", selection: nil, symbol: "", children: [.manifest, .workers, .storage, .webmcp].map(leaf)),
            ApplicationTreeItem(id: "storage", title: "Storage", selection: nil, symbol: "", children: storage),
            ApplicationTreeItem(id: "background", title: "Background services", selection: nil, symbol: "", children: [.backForward, .backgroundFetch, .backgroundSync, .notifications, .payment, .periodicSync, .push, .reporting, .speculative].map(leaf)),
            ApplicationTreeItem(id: "frames", title: "Frames", selection: ApplicationSelection(section: .frames), symbol: "", children: frameNodes)
        ]
    }
    private var toolbar: some View {
        DevPanelBar {
            if table {
                icon("arrow.clockwise", "Refresh data") { refresh() }
                if [.local, .session, .cookies, .indexedDB].contains(section) { icon("plus", "Add entry") { beginAdd() }.disabled(section == .indexedDB && app.selection.store.isEmpty) }
                icon("trash", "Delete selected entry") { deleteSelected() }.disabled(app.row == nil)
                if [.local, .session, .cookies].contains(section) { icon("broom", "Clear all entries") { clearEntries() } }
                Divider().frame(height: 16)
                Symbol("funnel", size: 11).foregroundStyle(Palette.muted)
                TextField("Filter", text: $app.filter).textFieldStyle(.plain).frame(minWidth: 80, idealWidth: 180).accessibilityLabel("Filter application data")
                if !app.filter.isEmpty { icon("xmark", "Clear filter") { app.filter = "" } }
            } else {
                Text(app.selection.title).fontWeight(.medium)
                Spacer(minLength: 8)
                if app.busy { ProgressView().controlSize(.mini) }
                icon("arrow.clockwise", "Refresh " + section.rawValue) { refreshTree() }
            }
        }
    }
    private var errorBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Symbol("exclamationmark.triangle.fill", size: 11).foregroundStyle(DevLook.red)
            Text(app.error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { app.error = "" } label: { Symbol("xmark", size: 11) }.buttonStyle(.plain).accessibilityLabel("Dismiss Application error")
        }.padding(8).background(DevLook.red.opacity(0.08))
    }
    @ViewBuilder private var content: some View {
        if app.selection.category, let category = section.category {
            empty(app.origins.isEmpty ? category.empty : category.title, category.text, section.symbol)
        } else {
            switch section {
            case .manifest: manifest
            case .workers: workers
            case .storage: storageUsage
            case .webmcp: DevWebMCPPane(browser: browser)
            case .local, .session, .cookies: gridAndPreview
            case .indexedDB:
                if app.selection.database.isEmpty { empty("Select a database", "Expand IndexedDB in the sidebar to inspect databases and object stores.", "application.database") }
                else if app.selection.store.isEmpty { databaseSummary }
                else { VStack(spacing: 0) { indexedToolbar; Divider(); gridAndPreview } }
            case .cache:
                if app.selection.cache.isEmpty { empty("Select a cache", "Expand Cache storage in the sidebar to inspect cached responses.", "archivebox") }
                else { gridAndPreview }
            case .frames: frameDetails
            case .backForward: backForward
            case .backgroundFetch: backgroundFetch
            default: background
            }
        }
    }
    private var gridAndPreview: some View {
        VSplitView {
            ZStack {
                DevApplicationGrid(columns: columns, rows: app.visibleRows, selected: app.selectedRow, editable: editableColumns, pick: pick, edit: editCell, remove: deleteSelected)
                if app.visibleRows.isEmpty && !app.busy { empty("No entries", app.filter.isEmpty ? "This storage is empty." : "No entries match the filter.", "application.table").allowsHitTesting(false) }
            }.frame(minHeight: 80, maxHeight: .infinity)
            if !app.selectedRow.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        ForEach(section == .cache ? ["Preview", "Response", "Headers"] : ["Value"], id: \.self) { title in
                            Button(title) { previewTab = title }.buttonStyle(.plain).foregroundStyle(previewTab == title || section != .cache ? Palette.ink : Palette.muted)
                        }
                        Spacer(minLength: 0)
                        if [.cookies, .indexedDB].contains(section) { Button("Edit") { beginEdit() }.buttonStyle(.plain).disabled(section == .indexedDB && app.row?.data["editable"] as? Bool == false) }
                        if section == .cache, app.previewDocument["truncated"] as? Bool == true { Button("Load full response") { loadCacheEntry(full: true) }.buttonStyle(.plain) }
                        icon("xmark", "Close value preview") { app.selectedRow = "" }
                    }.padding(.horizontal, 8).frame(height: 28).background(Palette.ink.opacity(0.025))
                    Divider()
                    ThreadScrollView {
                        if previewTab == "Headers", let headers = app.previewDocument["headers"] as? [String: Any] { ApplicationProperties(values: headers) }
                        else if previewTab == "Response" { Text(app.preview).font(DevMono.font(11.5)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                        else if app.previewDocument["base64"] as? Bool == true {
                            if let bytes = Data(base64Encoded: app.preview), let image = NSImage(data: bytes) { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 240).padding(8) }
                            else { Text("Binary response · \(app.previewDocument["length"] as? Int ?? 0) bytes").foregroundStyle(Palette.muted).padding(8) }
                        }
                        else { ApplicationJSON(value: DevWorkbench.parse(app.preview) ?? app.preview).padding(8).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }.frame(minHeight: 70, idealHeight: 140, maxHeight: .infinity)
            }
        }
    }
    private var columns: [DevApplicationGrid.Column] {
        switch section {
        case .cookies: return zip(["Name", "Value", "Domain", "Path", "Expires / Max-Age", "Size", "HttpOnly", "Secure", "SameSite", "Partition key"], [150.0, 220, 150, 80, 160, 60, 70, 65, 75, 160]).map { .init(title: $0.0, width: CGFloat($0.1)) }
        case .indexedDB: return [.init(title: "Key", width: 180), .init(title: "Primary key", width: 180), .init(title: "Value", width: 400)]
        case .cache: return [.init(title: "Name", width: 280), .init(title: "Status", width: 70), .init(title: "Type", width: 100), .init(title: "Content-Type", width: 180)]
        default: return [.init(title: "Key", width: 200), .init(title: "Value", width: 420)]
        }
    }
    private var editableColumns: Set<Int> { [.local, .session].contains(section) ? [0, 1] : section == .cookies ? [0, 1, 2, 3] : [] }
    private var status: some View {
        HStack(spacing: 8) {
            Text("\(app.visibleRows.count) \(app.visibleRows.count == 1 ? "entry" : "entries")")
            if app.busy { ProgressView().controlSize(.mini) }
            Spacer(minLength: 8)
            Text(app.selection.origin).lineLimit(1).truncationMode(.middle)
        }.foregroundStyle(Palette.muted).padding(.horizontal, 8).frame(height: 24).background(Palette.ink.opacity(0.025))
    }
    private var indexedToolbar: some View {
        DevPanelBar {
            icon("chevron.left", "Previous page") { app.offset = max(0, app.offset - 200); refresh() }.disabled(app.offset == 0)
            icon("chevron.right", "Next page") { app.offset += 200; refresh() }.disabled(!app.hasNext)
            Text("\(app.offset + 1)–\(app.offset + app.rows.count)").foregroundStyle(Palette.muted)
            TextField("Start from key (JSON)", text: $app.startKey).textFieldStyle(.plain).frame(minWidth: 120).onSubmit { app.offset = 0; refresh() }
            Button("Clear object store") { app.call(browser, "application.clearStore", ["name": app.selection.database, "store": app.selection.store]) { _ in refresh() } }
        }
    }
    private var databaseSummary: some View {
        ThreadScrollView {
            VStack(alignment: .leading, spacing: 12) {
                heading(app.selection.database)
                property("Version", DevApplicationModel.text(app.document["version"]))
                Button("Delete database") { app.call(browser, "application.deleteDatabase", ["name": app.selection.database]) { _ in var s = app.selection; s.database = ""; select(s); refreshTree() } }.buttonStyle(.yab(.quiet, .small))
                ForEach(Array((app.document["schemas"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, schema in
                    let name = schema["name"] as? String ?? ""
                    Button { var s = app.selection; s.store = name; select(s) } label: { Label { Text(name) } icon: { Symbol("application.table", size: 11) } }.buttonStyle(.plain)
                    ApplicationProperties(values: schema.filter { $0.key != "name" })
                }
            }.padding(16)
        }
    }
    private var manifest: some View {
        ThreadScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if app.document["missing"] as? Bool == true { empty("No manifest detected", "Add a web app manifest to inspect the app's identity, presentation and icons.", "doc.text") }
                else if let data = app.document["manifest"] as? [String: Any] {
                    heading("Manifest")
                    Link(app.document["url"] as? String ?? "", destination: URL(string: app.document["url"] as? String ?? "about:blank")!).font(.system(size: 11.5)).lineLimit(2)
                    if let warnings = app.document["warnings"] as? [String], !warnings.isEmpty {
                        heading("Errors and warnings")
                        ForEach(warnings, id: \.self) { warning in Label { Text(warning) } icon: { Symbol("exclamationmark.triangle", size: 11) }.foregroundStyle(DevLook.amber).fixedSize(horizontal: false, vertical: true) }
                    }
                    heading("Identity")
                    manifestProperties(data, keys: ["name", "short_name", "description", "id", "lang", "dir"])
                    heading("Presentation")
                    property("Start URL", app.document["start"] as? String ?? "")
                    property("Scope", app.document["scope"] as? String ?? "")
                    manifestProperties(data, keys: ["display", "display_override", "orientation", "theme_color", "background_color"])
                    heading("Icons")
                    manifestImages(app.document["icons"] as? [[String: Any]] ?? [])
                    if let shots = app.document["screenshots"] as? [[String: Any]], !shots.isEmpty { heading("Screenshots"); manifestImages(shots) }
                    ForEach(["shortcuts", "protocol_handlers", "file_handlers", "share_target", "related_applications", "categories"].filter { data[$0] != nil }, id: \.self) { field in
                        heading(field.replacingOccurrences(of: "_", with: " ").capitalized)
                        ApplicationJSON(value: data[field]!)
                    }
                    heading("Installability")
                    Text("Manifest validation is available. Installing a standalone PWA from this panel is not supported by Yab.").foregroundStyle(Palette.muted)
                } else if !app.busy { empty("Manifest", "Refresh to load the manifest.", "doc.text") }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func manifestProperties(_ data: [String: Any], keys: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) { ForEach(keys.filter { data[$0] != nil }, id: \.self) { key in property(key.replacingOccurrences(of: "_", with: " ").capitalized, DevApplicationModel.text(data[key])) } }
    }
    private func manifestImages(_ images: [[String: Any]]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if images.isEmpty { Text("No icons specified").foregroundStyle(Palette.muted) }
            ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                HStack(alignment: .top, spacing: 12) {
                    if let store = browser.toolsFront?.webKitOnly("WebKit application inspection", build: false)?.configuration.websiteDataStore {
                        DevApplicationImage(url: image["url"] as? String ?? "", origin: app.selection.origin, store: store)
                            .id(browser.toolsFront?.id).frame(width: 64, height: 64).background(Palette.ink.opacity(0.025))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(image["url"] as? String ?? "").lineLimit(2).textSelection(.enabled)
                        Text([image["sizes"] as? String, image["type"] as? String, image["purpose"] as? String].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(Palette.muted)
                    }
                }
            }
        }
    }
    private var workers: some View {
        ThreadScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Toggle("Offline", isOn: Binding(get: { net.throttle == NetThrottle.offline.id }, set: { net.throttle = $0 ? NetThrottle.offline.id : NetThrottle.none.id; browser.netApplyConditions() }))
                    Toggle("Update on reload", isOn: $app.updateOnReload)
                }.toggleStyle(NetCheckboxStyle())
                ForEach(app.origins, id: \.originID) { info in
                    ForEach(Array((info["workers"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, worker in
                        workerCard(worker, origin: info["origin"] as? String ?? "")
                    }
                }
                if app.origins.allSatisfy({ ($0["workers"] as? [Any] ?? []).isEmpty }) { empty("No service workers", "No service worker is registered for the loaded origins.", "gearshape") }
                Divider()
                heading("Emulation")
                Text("Sync, Stop and Bypass for network controls require service-worker commands that this WebKit connection does not expose.").foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                HStack { Button("Sync") {}.disabled(true); Button("Stop") {}.disabled(true) }.buttonStyle(.yab(.quiet, .small))
            }.padding(16)
        }
    }
    private func workerCard(_ worker: [String: Any], origin: String) -> some View {
        let canPush = app.origins.first { $0["origin"] as? String == origin }?["notificationPermission"] as? String == "granted"
        return VStack(alignment: .leading, spacing: 8) {
            heading(worker["scope"] as? String ?? "")
            ForEach(["active", "waiting", "installing"], id: \.self) { phase in
                if let state = worker[phase] as? [String: Any] {
                    HStack(spacing: 8) {
                        Circle().fill(phase == "active" ? Color.green : DevLook.amber).frame(width: 6, height: 6)
                        Text(state["state"] as? String ?? phase)
                        Button(URL(string: state["url"] as? String ?? "")?.lastPathComponent ?? "Source") {
                            browser.sourcesRefresh(); browser.pickDevPane(DevTab.sources.pane)
                            browser.workCall("sources.files") { files in
                                if let file = (files as? [[String: Any]])?.first(where: { $0["url"] as? String == state["url"] as? String }) {
                                    browser.sourceOpen(DevSource(script: file["id"] as? String ?? "", url: file["url"] as? String ?? "", target: file["target"] as? String ?? "", frame: file["frame"] as? String ?? "", kind: file["type"] as? String ?? "script"))
                                }
                            }
                        }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                }
            }
            TextField("Push payload", text: $pushPayload).textFieldStyle(.roundedBorder)
            if !canPush { Text("Allow notifications in the site controls to emulate Push, then refresh.").foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) }
            property("Clients", app.frames.filter { ($0["url"] as? String ?? "").hasPrefix(worker["scope"] as? String ?? "") }.map { $0["url"] as? String ?? "" }.joined(separator: "\n"))
            HStack(spacing: 12) {
                Button("Push") { app.call(browser, "application.push", ["origin": origin, "scope": worker["scope"] as? String ?? "", "payload": pushPayload]) { value in if value as? Bool != true { app.error = "WebKit did not confirm successful processing of this push event." } } }.disabled(!canPush)
                Button("Update") { workerAction(worker, origin: origin, action: "update") }
                Button("Unregister") { workerAction(worker, origin: origin, action: "unregister") }
                if worker["waiting"] is [String: Any] { Button("Skip waiting") { workerAction(worker, origin: origin, action: "skipWaiting") }.keyTip("Sends SKIP_WAITING to a worker that handles this message") }
            }.buttonStyle(.yab(.quiet, .small))
            Divider()
        }
    }
    private var storageUsage: some View {
        ThreadScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heading("Usage")
                Picker("Origin", selection: Binding(get: { app.selection.origin }, set: { var s = app.selection; s.origin = $0; select(s) })) {
                    ForEach(app.origins, id: \.originID) { Text($0.originID).tag($0.originID) }
                }.pickerStyle(.menu)
                let usage = (app.document["usage"] as? NSNumber)?.doubleValue ?? 0
                let quota = (app.document["quota"] as? NSNumber)?.doubleValue ?? 0
                if quota > 0 {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle().stroke(Palette.faint, lineWidth: 12)
                            Circle().trim(from: 0, to: min(1, usage / quota)).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 12, lineCap: .butt)).rotationEffect(.degrees(-90))
                        }.frame(width: 80, height: 80).padding(8)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(usage), countStyle: .file)) used out of \(ByteCountFormatter.string(fromByteCount: Int64(quota), countStyle: .file))")
                            Text("\(String(format: "%.2f", usage / quota * 100))% of storage quota").foregroundStyle(Palette.muted)
                            if let persistent = app.document["persistent"] as? Bool { Text(persistent ? "Persistent storage" : "Best-effort storage").foregroundStyle(Palette.muted) }
                        }
                    }
                } else { Text("Storage quota reporting is unavailable for this origin.").foregroundStyle(Palette.muted) }
                if let details = app.document["usageDetails"] as? [String: Any] { ApplicationProperties(values: details) }
                Divider(); heading("Clear storage")
                ForEach([("workers", "Unregister service workers"), ("local", "Local storage"), ("session", "Session storage"), ("indexedDB", "IndexedDB"), ("cache", "Cache storage"), ("cookies", "Cookies")], id: \.0) { id, title in
                    Toggle(title, isOn: Binding(get: { app.clearTypes.contains(id) }, set: { if $0 { app.clearTypes.insert(id) } else { app.clearTypes.remove(id) } })).toggleStyle(NetCheckboxStyle())
                }
                Button("Clear site data") { clearSiteData() }.buttonStyle(.yab(.quiet, .small)).disabled(app.busy || app.clearTypes.isEmpty)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var frameDetails: some View {
        ThreadScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if app.selection.frame.isEmpty { empty("Select a frame", "Expand Frames in the sidebar to inspect documents and their resources.", "application.frame") }
                else if !app.selection.resource.isEmpty {
                    heading(app.selection.resource)
                    Text(app.preview).font(DevMono.font(11.5)).textSelection(.enabled)
                } else {
                    heading("Document")
                    ApplicationProperties(values: app.document.filter { ["url", "origin", "title", "referrer", "mimeType", "name"].contains($0.key) })
                    heading("Security & Isolation")
                    property("Secure context", app.document["secure"] as? Bool == true ? "Yes" : "No")
                    property("Cross-origin isolated", app.document["isolated"] as? Bool == true ? "Yes" : "No")
                    if let headers = app.document["headers"] as? [String: Any] {
                        ApplicationProperties(values: headers.filter { ["cross-origin-embedder-policy", "cross-origin-opener-policy"].contains($0.key.lowercased()) })
                    }
                    heading("Content Security Policy")
                    let csp = app.document["csp"] as? [String] ?? []
                    if csp.isEmpty { Text("No policy reported").foregroundStyle(Palette.muted) } else { ForEach(csp, id: \.self) { Text($0).textSelection(.enabled) } }
                    heading("API availability")
                    ApplicationProperties(values: app.document["api"] as? [String: Any] ?? [:])
                    heading("Permissions Policy")
                    let policies = app.document["policy"] as? [String] ?? []
                    Text(policies.isEmpty ? "Permissions Policy inspection is unavailable in this document." : policies.joined(separator: ", ")).foregroundStyle(Palette.muted).textSelection(.enabled)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var backForward: some View {
        ThreadScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heading("Back/forward cache")
                Text("Navigate away and back to test whether this page is restored from the browser cache.").foregroundStyle(Palette.muted)
                Button("Test back/forward cache") { app.testBackForward() }.buttonStyle(.yab(.quiet, .small))
                if !app.backForwardStatus.isEmpty { Label { Text(app.backForwardStatus) } icon: { Symbol(app.backForwardStatus.hasPrefix("Restored") ? "checkmark.circle" : "info.circle", size: 11) } }
                Text("WebKit reports the restoration result through pageshow.persisted. Detailed Chromium eviction reasons are unavailable.").foregroundStyle(Palette.muted)
            }.padding(16)
        }
    }
    private var backgroundFetch: some View {
        ThreadScrollView {
            VStack(alignment: .leading, spacing: 12) {
                heading("Background fetch")
                let fetches = app.document["fetches"] as? [[String: Any]] ?? []
                if fetches.isEmpty { empty("No background fetches", "No background fetch is registered for this origin.", "arrow.down.circle") }
                ForEach(Array(fetches.enumerated()), id: \.offset) { _, fetch in
                    ApplicationProperties(values: fetch.filter { $0.key != "id" })
                    HStack {
                        Button(fetch["IsPaused"] as? Bool == true ? "Resume" : "Pause") { app.call(browser, "application.backgroundFetchAction", ["id": fetch["id"] as? String ?? "", "action": fetch["IsPaused"] as? Bool == true ? "resume" : "pause"]) { _ in refresh() } }
                        Button("Abort") { app.call(browser, "application.backgroundFetchAction", ["id": fetch["id"] as? String ?? "", "action": "abort"]) { _ in refresh() } }
                    }.buttonStyle(.yab(.quiet, .small))
                    Divider()
                }
            }.padding(16)
        }
    }
    private var background: some View {
        VStack(spacing: 0) {
            DevPanelBar {
                Button(app.recordingEvents ? "Stop recording" : "Start recording") { app.recordingEvents.toggle() }
                icon("broom", "Clear recorded events") { app.events = [] }
                Spacer(minLength: 0)
            }
            Divider()
            if [.reporting, .push, .notifications].contains(section) {
                let events = app.events.filter { section == .reporting ? ["Report", "CSP violation"].contains($0["kind"] as? String ?? "") : $0["kind"] as? String == (section == .notifications ? "Notification" : "Push emulation") }
                if events.isEmpty { empty(section.rawValue, section == .reporting ? "Record page reports and Content Security Policy violations. ReportingObserver availability depends on the page's engine." : section == .notifications ? "Record site notifications handled by Yab after allowing notifications for the site." : "Record Push emulation sent from Service workers. Incoming Web Push logs are not exposed by the current WebKit connection.", "clock.arrow.circlepath") }
                else { ThreadScrollView { VStack(alignment: .leading, spacing: 8) { ForEach(Array(events.enumerated()), id: \.offset) { _, event in ApplicationJSON(value: event); Divider() } }.padding(8) } }
            } else {
                empty(section.rawValue, [.shared, .privateTokens, .interestGroups, .speculative].contains(section) ? "This Chromium feature is not exposed by the current WebKit engine." : "The current WebKit connection does not expose browser-level events for this service.", section.symbol)
            }
        }
    }
    private var recordEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(app.row == nil ? "Add entry" : "Edit entry")
            if !app.error.isEmpty { Text(app.error).foregroundStyle(DevLook.red).fixedSize(horizontal: false, vertical: true) }
            TextField(section == .indexedDB ? "Key (JSON)" : "Name", text: $key).textFieldStyle(.roundedBorder)
            ThreadTextEditor(text: $value).font(DevMono.font(11.5)).frame(minHeight: 100).overlay(Rectangle().stroke(Palette.hairline))
            if section == .cookies { ApplicationCookieEditor(cookie: $cookie) }
            HStack { Spacer(); Button("Cancel") { editor = false }; Button("Save") { saveEntry() }.keyboardShortcut(.defaultAction) }.buttonStyle(.yab(.quiet, .small))
        }.padding(16).frame(width: 480).font(.system(size: 11.5))
    }
    private func icon(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Symbol(symbol, size: 12).frame(width: 16, height: 16) }.buttonStyle(.plain).keyTip(label).accessibilityLabel(label)
    }
    private func heading(_ text: String) -> some View { Text(text).font(.system(size: 13, weight: .semibold)).textSelection(.enabled) }
    private func property(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) { Text(title).foregroundStyle(Palette.muted).frame(width: 110, alignment: .leading); Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
    }
    private func empty(_ title: String, _ description: String, _ symbol: String) -> some View {
        VStack(spacing: 12) {
            Symbol(symbol, size: 18).foregroundStyle(Palette.muted)
            Text(title).fontWeight(.semibold)
            Text(description).foregroundStyle(Palette.muted).multilineTextAlignment(.center).frame(maxWidth: 360)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func select(_ selection: ApplicationSelection) { app.select(selection); model.applicationSection = selection.section.rawValue; app.expanded.insert("section:" + selection.section.rawValue) }
    private func expand(_ item: ApplicationTreeItem) {
        if app.expanded.contains(item.id) { app.expanded.remove(item.id) } else {
            app.expanded.insert(item.id)
            if let s = item.selection, s.section == .indexedDB, !s.database.isEmpty, s.store.isEmpty {
                browser.workCall("application.database", s.params.merging(["name": s.database]) { _, new in new }) { value in
                    if let data = value as? [String: Any] { app.schemas[s.origin + "\u{1f}" + s.database] = data["schemas"] as? [[String: Any]] ?? [] }
                }
            }
        }
    }
    private func refreshTree(attempt: Int = 0) {
        let tab = browser.toolsFront?.id, navigation = model.navigationRevision
        // The wire announces its connection before all panel modules and frame
        // execution contexts have finished installing. Retry this bounded setup.
        func retry() {
            guard attempt < 8 else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard browser.toolsFront?.id == tab, model.navigationRevision == navigation else { return }
                refreshTree(attempt: attempt + 1)
            }
        }
        var failed = false
        browser.wire("application.snapshot", failed: { error in
            failed = true
            guard browser.toolsFront?.id == tab, model.navigationRevision == navigation else { return }
            if attempt < 8 { retry() } else { app.error = error }
        }) { value in
            guard !failed, browser.toolsFront?.id == tab, model.navigationRevision == navigation else { return }
            let decoded = (value as? String).flatMap(DevWorkbench.parse) ?? value
            if let data = decoded as? [String: Any] {
                let revision = app.selectionRevision; app.acceptSnapshot(data)
                if app.selectionRevision == revision { refresh() }
                if (data["origins"] as? [[String: Any]] ?? []).contains(where: { $0["error"] != nil }) { retry() }
            }
        }
    }
    private func refresh() {
        app.selectedRow = ""; app.preview = ""; app.previewDocument = [:]
        let s = app.selection
        guard !s.category else { return }
        switch section {
        case .backgroundFetch: app.call(browser, "application.backgroundFetch") { app.document = ["fetches": $0 as? [[String: Any]] ?? []] }
        case .manifest, .storage: app.call(browser, section == .manifest ? "application.manifest" : "application.quota") { app.document = $0 as? [String: Any] ?? [:] }
        case .local, .session:
            app.call(browser, "application.storage", ["origin": s.origin, "local": section == .local]) { value in
                app.rows = ((value as? [String: Any])?["entries"] as? [[String]] ?? []).filter { $0.count >= 2 }.map { ApplicationGridRow(id: $0[0], cells: [$0[0], $0[1]]) }
            }
        case .cookies: app.call(browser, "Page.getCookies") { value in loadCookies((value as? [String: Any])?["cookies"] as? [[String: Any]] ?? []) }
        case .indexedDB:
            guard !s.database.isEmpty else { return }
            if s.store.isEmpty {
                app.call(browser, "application.database", ["name": s.database]) { value in
                    app.document = value as? [String: Any] ?? [:]; app.schemas[app.schemaKey] = app.document["schemas"] as? [[String: Any]] ?? []
                    app.expanded.insert("origin:" + ApplicationSelection(section: .indexedDB, origin: s.origin).id); app.expanded.insert("db:" + s.id)
                }
            } else {
                app.call(browser, "application.records", ["name": s.database, "store": s.store, "index": s.index, "offset": app.offset, "limit": 201, "startKey": app.startKey]) { value in
                    let records = value as? [[String: Any]] ?? []; app.hasNext = records.count > 200
                    app.rows = records.prefix(200).enumerated().map { i, record in ApplicationGridRow(id: DevApplicationModel.json(record["primaryKey"] ?? record["key"]), cells: [DevApplicationModel.text(record["key"]), DevApplicationModel.text(record["primaryKey"] ?? record["key"]), DevApplicationModel.text(record["value"])], data: record) }
                }
            }
        case .cache:
            guard !s.cache.isEmpty else { return }
            app.call(browser, "application.cache", ["name": s.cache]) { value in app.rows = (value as? [[String: Any]] ?? []).map { ApplicationGridRow(id: $0["url"] as? String ?? "", cells: [$0["url"] as? String ?? "", DevApplicationModel.text($0["status"]), DevApplicationModel.text($0["type"]), DevApplicationModel.text($0["mime"])], data: $0) } }
        case .frames:
            guard !s.frame.isEmpty else { return }
            if !s.resource.isEmpty { app.call(browser, "application.resource", ["url": s.resource]) { value in let data = value as? [String: Any] ?? [:]; app.preview = data["base64"] as? Bool == true ? "Binary resource (base64)\n" + (data["body"] as? String ?? "") : data["body"] as? String ?? "" } }
            else { app.call(browser, "application.frame") { app.document = $0 as? [String: Any] ?? [:] } }
        default: break
        }
    }
    private func loadCookies(_ cookies: [[String: Any]]) {
        app.rows = cookies.filter { DevApplicationModel.cookie($0, belongsTo: app.selection.origin) }.map { c in
            let name = c["name"] as? String ?? "", value = c["value"] as? String ?? ""
            let expires = (c["expires"] as? NSNumber)?.doubleValue ?? 0
            let expiry = c["session"] as? Bool == true ? "Session" : Date(timeIntervalSince1970: expires / 1000).englishFormatted(date: .numeric, time: .shortened)
            let id = [name, c["domain"] as? String ?? "", c["path"] as? String ?? "", DevApplicationModel.text(c["partitionKey"])].joined(separator: "\u{1f}")
            return ApplicationGridRow(id: id, cells: [name, value, c["domain"] as? String ?? "", c["path"] as? String ?? "/", expiry, String(name.utf8.count + value.utf8.count), c["httpOnly"] as? Bool == true ? "✓" : "", c["secure"] as? Bool == true ? "✓" : "", c["sameSite"] as? String ?? "", DevApplicationModel.text(c["partitionKey"])], data: c)
        }
    }
    private func pick(_ row: ApplicationGridRow) {
        app.selectedRow = row.id; previewTab = section == .cache ? "Preview" : "Value"
        if section == .cache { loadCacheEntry() }
        else { app.preview = section == .indexedDB ? DevApplicationModel.text(row.data["value"]) : row.cells.count > 1 ? row.cells[1] : "" }
    }
    private func loadCacheEntry(full: Bool = false) {
        guard let row = app.row else { return }; let id = row.id
        app.call(browser, "application.cacheEntry", ["name": app.selection.cache, "url": id, "full": full]) { value in
            guard app.selectedRow == id else { return }; app.previewDocument = value as? [String: Any] ?? [:]; app.preview = app.previewDocument["body"] as? String ?? ""
        }
    }
    private func beginAdd() {
        app.selectedRow = ""; key = ""; value = section == .indexedDB ? "{}" : ""
        cookie = ["domain": URL(string: app.selection.origin)?.host ?? "", "path": "/", "secure": app.selection.origin.hasPrefix("https:"), "httpOnly": false, "sameSite": "Lax", "session": true, "expires": Date().addingTimeInterval(86400).timeIntervalSince1970 * 1000]
        editor = true
    }
    private func beginEdit() {
        guard let row = app.row else { return }; if section == .indexedDB && row.data["editable"] as? Bool == false { app.error = "Structured-clone values can be inspected and deleted, but cannot be edited as JSON."; return }; key = section == .indexedDB ? DevApplicationModel.json(row.data["primaryKey"] ?? row.data["key"]) : row.cells[0]
        value = section == .indexedDB ? DevApplicationModel.text(row.data["value"]) : row.cells[1]; cookie = row.data; editor = true
    }
    private func saveEntry() {
        if section == .cookies {
            var c = cookie; c["name"] = key; c["value"] = value
            guard !key.isEmpty else { app.error = "Enter a cookie name"; return }
            app.call(browser, "Page.setCookie", ["cookie": c]) { _ in editor = false; refresh() }
        } else if section == .indexedDB {
            guard key.isEmpty || DevWorkbench.parse(key) != nil, DevWorkbench.parse(value) != nil else { app.error = "Enter valid JSON for the key and value"; return }
            app.call(browser, "application.writeRecord", ["name": app.selection.database, "store": app.selection.store, "key": key, "value": value]) { _ in editor = false; refresh() }
        } else {
            app.call(browser, "application.setStorage", ["origin": app.selection.origin, "local": section == .local, "key": key, "value": value]) { _ in editor = false; refresh() }
        }
    }
    private func editCell(_ row: ApplicationGridRow, _ column: Int, _ text: String) {
        if section == .cookies {
            var c = row.data; let field = ["name", "value", "domain", "path"][column]; c[field] = text
            app.call(browser, "Page.setCookie", ["cookie": c]) { _ in
                if [0, 2, 3].contains(column) { deleteCookie(row.data) { refresh() } } else { refresh() }
            }
        } else {
            let oldKey = row.cells[0], newKey = column == 0 ? text : oldKey, newValue = column == 1 ? text : row.cells[1]
            app.call(browser, "application.setStorage", ["origin": app.selection.origin, "local": section == .local, "key": newKey, "value": newValue]) { _ in
                if newKey != oldKey { app.call(browser, "application.removeStorage", ["origin": app.selection.origin, "local": section == .local, "key": oldKey]) { _ in refresh() } } else { refresh() }
            }
        }
    }
    private func deleteSelected() {
        guard let row = app.row else { return }
        switch section {
        case .cookies: deleteCookie(row.data) { refresh() }
        case .indexedDB: app.call(browser, "application.writeRecord", ["name": app.selection.database, "store": app.selection.store, "key": DevApplicationModel.json(row.data["primaryKey"] ?? row.data["key"]), "remove": true]) { _ in refresh() }
        case .cache: app.call(browser, "application.cacheEntry", ["name": app.selection.cache, "url": row.id, "remove": true]) { _ in refresh() }
        case .local, .session: app.call(browser, "application.removeStorage", ["origin": app.selection.origin, "local": section == .local, "key": row.id]) { _ in refresh() }
        default: break
        }
    }
    private func deleteCookie(_ cookie: [String: Any], done: @escaping () -> Void) {
        guard let web = browser.toolsFront?.webKitOnly("WebKit application inspection", build: false) else { return }
        Task { @MainActor in
            let store = web.configuration.websiteDataStore.httpCookieStore
            for c in await store.allCookies() where c.name == cookie["name"] as? String && c.domain == cookie["domain"] as? String && c.path == cookie["path"] as? String { await store.delete(c) }
            done()
        }
    }
    private func clearEntries() {
        if section == .cookies { clearCookies(origin: app.selection.origin) { refresh() } }
        else { app.call(browser, "application.clearDOMStorage", ["origin": app.selection.origin, "local": section == .local]) { _ in refresh() } }
    }
    private func clearCookies(origin: String, done: @escaping () -> Void) {
        guard let web = browser.toolsFront?.webKitOnly("WebKit application inspection", build: false) else { return }
        Task { @MainActor in
            let store = web.configuration.websiteDataStore.httpCookieStore
            for c in await store.allCookies() where DevApplicationModel.cookie(["domain": c.domain], belongsTo: origin) { await store.delete(c) }
            done()
        }
    }
    private func clearSiteData() {
        let origin = app.selection.origin, cookies = app.clearTypes.contains("cookies")
        app.call(browser, "application.clearStorage", ["types": Array(app.clearTypes.subtracting(["cookies"]))]) { _ in
            if cookies { clearCookies(origin: origin) { refreshTree() } } else { refreshTree() }
        }
    }
    private func workerAction(_ worker: [String: Any], origin: String, action: String) {
        app.call(browser, "application.workerAction", ["origin": origin, "scope": worker["scope"] as? String ?? "", "action": action]) { _ in refreshTree() }
    }
}

private extension Dictionary where Key == String, Value == Any { var originID: String { self["origin"] as? String ?? "" } }

private struct ApplicationTreeRow: View {
    let item: ApplicationTreeItem
    let depth: Int
    @ObservedObject var app: DevApplicationModel
    var select: (ApplicationSelection) -> Void
    var expand: (ApplicationTreeItem) -> Void
    @State private var hovered = false
    private var group: Bool { depth == 0 }
    private var expandable: Bool { !item.children.isEmpty || item.id.hasPrefix("db:") }
    private var indent: CGFloat { CGFloat(depth * 12 + 8) }
    private var picked: Bool { item.selection == app.selection }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Symbol(app.expanded.contains(item.id) ? "chevron.down" : "chevron.right", size: 8).frame(width: 12)
                    .opacity(expandable || group ? 1 : 0)
                HStack(spacing: 6) {
                    if !item.symbol.isEmpty { Symbol(item.symbol, size: 11).frame(width: 16).foregroundStyle(Palette.muted) }
                    Text(item.title).font(.system(size: 11.5, weight: group ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
            }
            .padding(.leading, indent).padding(.trailing, 8).frame(height: group ? 26 : 23) // design: tree depth adds indentation to the leading edge; each row keeps an 8-point trailing inset
            .background(picked ? Color.accentColor.opacity(0.15) : hovered ? Palette.ink.opacity(0.04) : .clear)
            .overlay(TreeRowPress(id: item.id, title: item.title, picked: picked) { press(at: $0, clicks: $1) })
            .onHover { hovered = $0 }
            .pointerTip(item.title)
            .accessibilityElement(children: .ignore).accessibilityLabel(item.title).accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { press(at: indent + 20, clicks: 1) }
            .accessibilityAction(named: app.expanded.contains(item.id) ? "Collapse" : "Expand") { expand(item) }
            if app.expanded.contains(item.id) {
                ForEach(item.children) { child in ApplicationTreeRow(item: child, depth: depth + 1, app: app, select: select, expand: expand) }
            }
        }
    }
    /// Chrome's TreeElement: mouse down anywhere on the row selects it, the
    /// disclosure triangle toggles, a double click opens a closed parent, and
    /// a row that shows nothing of its own (a group, a resource folder) toggles.
    private func press(at x: CGFloat, clicks: Int) {
        let open = app.expanded.contains(item.id)
        if expandable, x >= indent - 6, x < indent + 16 { expand(item); return }
        if clicks >= 2 { if expandable, !open { expand(item) }; return }
        if let selection = item.selection { select(selection) } else { expand(item) }
    }
}

/// The row's press on mouse down, as a native view takes it: the whole row,
/// its indent included, answers the first click even in a window that isn't
/// key. Plain SwiftUI buttons answered on mouse up, only over the title and a
/// chevron 8 points tall.
private struct TreeRowPress: NSViewRepresentable {
    var id: String
    var title: String
    var picked: Bool
    var press: (CGFloat, Int) -> Void
    final class Target: NSView {
        var id = "", title = "", picked = false
        var press: (CGFloat, Int) -> Void = { _, _ in }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { press(convert(event.locationInWindow, from: nil).x, event.clickCount) }
    }
    func makeNSView(context: Context) -> Target { let view = Target(); updateNSView(view, context: context); return view }
    func updateNSView(_ view: Target, context: Context) { view.id = id; view.title = title; view.picked = picked; view.press = press }
    /// Every row on screen with its frame, top-left in the window's content.
    @MainActor static func probe(_ window: NSWindow?) -> [[String: Any]] {
        guard let content = window?.contentView else { return [] }
        var rows: [[String: Any]] = []
        func walk(_ view: NSView) {
            if let row = view as? Target, !row.isHiddenOrHasHiddenAncestor, row.window != nil {
                let r = row.convert(row.bounds, to: nil)
                rows.append(["id": row.id, "title": row.title, "picked": row.picked, "frame": [r.minX, content.bounds.height - r.maxY, r.width, r.height]])
            }
            view.subviews.forEach(walk)
        }
        walk(content)
        return rows
    }
}

enum DevApplicationTree {
    @MainActor static func probe(_ window: NSWindow?) -> [[String: Any]] { TreeRowPress.probe(window) }
}

struct ApplicationProperties: View {
    var values: [String: Any]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(values.keys.sorted(), id: \.self) { key in
                HStack(alignment: .top, spacing: 12) {
                    Text(key).foregroundStyle(Palette.muted).frame(width: 130, alignment: .leading)
                    Text(DevApplicationModel.text(values[key])).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.font(.system(size: 11.5))
    }
}

struct ApplicationJSON: View {
    var value: Any
    var name = ""
    var depth = 0
    @State private var limit = 100
    private var count: Int { (value as? [String: Any])?.count ?? (value as? [Any])?.count ?? 0 }
    private var children: [(String, Any)] {
        if let dictionary = value as? [String: Any] { return dictionary.keys.sorted().prefix(limit).map { ($0, dictionary[$0]!) } }
        if let array = value as? [Any] { return array.prefix(limit).enumerated().map { (String($0.offset), $0.element) } }
        return []
    }
    var body: some View {
        if !children.isEmpty && depth < 20 {
            DisclosureGroup {
                ForEach(Array(children.enumerated()), id: \.offset) { _, pair in AnyView(ApplicationJSON(value: pair.1, name: pair.0, depth: depth + 1)) }
                if count > limit { Button("Show next \(min(100, count - limit)) items") { limit += 100 }.buttonStyle(.plain).foregroundStyle(Color.accentColor) }
            } label: {
                Text((name.isEmpty ? "" : name + ": ") + (value is [Any] ? "Array" : "Object") + " (\(count))").textSelection(.enabled)
            }.font(DevMono.font(11.5))
        } else {
            Text((name.isEmpty ? "" : name + ": ") + DevApplicationModel.text(value)).font(DevMono.font(11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ApplicationCookieEditor: View {
    @Binding var cookie: [String: Any]
    private func text(_ key: String, default value: String = "") -> Binding<String> { Binding(get: { cookie[key] as? String ?? value }, set: { cookie[key] = $0 }) }
    private func flag(_ key: String) -> Binding<Bool> { Binding(get: { cookie[key] as? Bool ?? false }, set: { cookie[key] = $0 }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { TextField("Domain", text: text("domain")); TextField("Path", text: text("path", default: "/")) }.textFieldStyle(.roundedBorder)
            HStack { Toggle("HttpOnly", isOn: flag("httpOnly")); Toggle("Secure", isOn: flag("secure")); Toggle("Session", isOn: flag("session")) }.toggleStyle(NetCheckboxStyle())
            Picker("SameSite", selection: text("sameSite", default: "Lax")) { ForEach(["None", "Lax", "Strict"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu)
            if cookie["session"] as? Bool != true {
                DatePicker("Expires", selection: Binding(get: { Date(timeIntervalSince1970: ((cookie["expires"] as? NSNumber)?.doubleValue ?? 0) / 1000) }, set: { cookie["expires"] = $0.timeIntervalSince1970 * 1000 }))
                    .environment(\.locale, AppDates.locale)
            }
            if let partition = cookie["partitionKey"] { Text("Partition key: " + DevApplicationModel.text(partition)).foregroundStyle(Palette.muted) }
        }
    }
}

extension Browser {
    func applicationInfo() { workCall("application.info") { [weak self] in self?.workbench?.applicationInfo = $0 as? [String: Any] ?? [:] } }
    func applicationStorage(local: Bool) {
        guard let url = toolsFront?.address else { return }
        let origin = (url.scheme ?? "http") + "://" + (url.host() ?? "") + (url.port.map { ":\($0)" } ?? "")
        workCall("application.storage", ["origin": origin, "local": local]) { [weak self] value in self?.workbench?.storage = ((value as? [String: Any])?["entries"] as? [[String]] ?? []).compactMap { $0.count >= 2 ? DevProperty(name: $0[0], value: $0[1]) : nil } }
    }
}
