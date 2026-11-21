import AppKit
import CoreText
import SwiftUI
import WebKit

// A request's details, as Chromium's Network shows the row picked: its tabs
// over what it sent and got, with yab's Copy for Agent and Ask in Chat at
// the end of the row of tabs (DevNet.swift).

struct NetDetails: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject var log: NetLog
    @ObservedObject var panel: NetPanel
    let row: NetRow
    /// Under the page there is room for Copy for Agent's words.
    var wide = true
    @State private var body_: NetBody?

    private var tabs: [NetDetailTab] {
        let r = row.resource
        var out: [NetDetailTab] = [.headers]
        let hasQuery = URLComponents(string: row.url)?.query?.isEmpty == false
        if hasQuery || (row.hop == nil && r.postData != nil) { out.append(.payload) }
        if row.hop != nil { return out + [.timing] }
        switch r.type {
        case "websocket": out.append(.messages)
        case "eventsource": out += [.eventStream, .response]
        default: out += [.preview, .response]
        }
        out += [.initiator, .timing]
        if !NetCookie.request(row).isEmpty || !NetCookie.response(row).cookies.isEmpty || !NetCookie.response(row).malformed.isEmpty { out.append(.cookies) }
        return out
    }

    var body: some View {
        let shown = tabs.contains(panel.detail) ? panel.detail : .headers
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                Button { panel.selected = nil } label: { Symbol("xmark", size: 11) }
                    .buttonStyle(.yab(.quiet, .small, tint: Palette.ink, icon: .square))
                    .keyTip("Close", keys: "esc")
                // Beside the page not every tab fits: the one open is kept in sight.
                ScrollViewReader { reader in
                    ThreadScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 1) {
                            ForEach(tabs, id: \.self) { item in
                                Button { panel.detail = item } label: {
                                    Text(item.rawValue).font(.system(size: 11.5, weight: .medium)).fixedSize()
                                }
                                .buttonStyle(.yab(shown == item ? .secondary : .quiet, .small, tint: Palette.ink))
                                .id(item)
                            }
                        }
                    }
                    .onAppear { reader.scrollTo(shown) }
                    .onChange(of: shown) { reader.scrollTo(shown) }
                }
                Spacer(minLength: 4)
                Button { browser.netCopyForAgent([row]) } label: {
                    HStack(spacing: 6) {
                        Symbol("doc.on.doc", size: 11)
                        if wide { Text("Copy for Agent").font(.system(size: 11.5, weight: .medium)).fixedSize() }
                    }
                }
                .buttonStyle(.yab(.quiet, .small, tint: Palette.ink, icon: wide ? nil : .square))
                .keyTip(wide ? "" : "Copy for Agent")
                Button { browser.netAsk([row], question: "") } label: { Symbol("bubble.sparkle", size: 11) }
                    .buttonStyle(.yab(.quiet, .small, tint: Palette.ink, icon: .square))
                    .keyTip("Ask in Chat")
            }
            .focusable(false)
            .padding(.horizontal, 4)
            .frame(height: 30)
            Rectangle().fill(Palette.ink.opacity(0.06)).frame(height: 1)
            Group {
                switch shown {
                case .headers: NetHeadersTab(browser: browser, panel: panel, row: row)
                case .payload: NetPayloadTab(row: row)
                case .preview: NetPreviewTab(row: row, content: body_)
                case .response: NetResponseTab(row: row, content: body_)
                case .messages: NetMessagesTab(row: row)
                case .eventStream: NetEventsTab(row: row)
                case .initiator: NetInitiatorTab(browser: browser, log: log, panel: panel, row: row)
                case .timing: NetTimingTab(log: log, row: row)
                case .cookies: NetCookiesTab(row: row)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear(perform: load)
        .onChange(of: panel.detail) { load() }
        .onChange(of: row.finished) { load() }
    }

    private func load() {
        guard body_ == nil, row.hop == nil, row.finished, !row.failed,
              panel.detail == .preview || panel.detail == .response else { return }
        browser.netBody(row) { body_ = $0 }
    }
}

// MARK: - parts

/// A section with its heading, closed with a click, as Chromium's.
struct NetSection<Content: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content
    @State private var closed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button { closed.toggle() } label: {
                    HStack(spacing: 6) {
                        // A mark 8 wide puts the title 24 in, where the rows under it start.
                        Symbol("chevron.down", size: 8)
                            .rotationEffect(.degrees(closed ? -90 : 0))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 8)
                        // A count after the name, "(5)", quiet, as the design has it.
                        if let open = title.range(of: " (", options: .backwards), title.hasSuffix(")") {
                            Text(title[..<open.lowerBound]).font(.system(size: 11.5, weight: .semibold))
                                + Text(title[open.lowerBound...]).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                        } else {
                            Text(title).font(.system(size: 11.5, weight: .semibold))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            if !closed { content.padding(.bottom, 8) }
            Rectangle().fill(Palette.ink.opacity(0.06)).frame(height: 1)
        }
    }
}

extension NetSection where Trailing == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = EmptyView()
        self.content = content()
    }
}

/// Names and values, one pair a line, the values selectable. The names
/// take a third of the room, never under 140, as the design lays them,
/// so the values start in one place across the sections.
struct NetPairs: View {
    let pairs: [(String, String)]
    var marked: Set<String> = []
    @State private var room: CGFloat = 0

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 2) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                GridRow {
                    HStack(spacing: 4) {
                        if marked.contains(pair.0.lowercased()) { Circle().fill(Color(nsColor: NetInk.accent)).frame(width: 5, height: 5) }
                        Text(pair.0).foregroundStyle(Palette.muted)
                    }
                    .frame(width: max(140, (room * 0.32).rounded()), alignment: .leading)
                    Text(pair.1)
                        .font(DevMono.font(11))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room = $0 }
        .font(.system(size: 11.5))
        .padding(.leading, 24) // design: under its section's title, as Chromium's
        .padding(.trailing, 10) // design: under its section's title, as Chromium's
    }
}

struct NetRaw: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DevMono.font(11))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Palette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            .padding(.leading, 24) // design: under its section's title, as Chromium's
            .padding(.trailing, 10) // design: under its section's title, as Chromium's
    }
}

struct NetNote: View {
    let words: String

    var body: some View {
        Text(words)
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
    }
}

// MARK: - Headers

struct NetHeadersTab: View {
    let browser: Browser
    @ObservedObject var panel: NetPanel
    let row: NetRow
    @State private var rawRequest = false
    @State private var rawResponse = false
    @State private var edits: [EditedHeader] = []

    struct EditedHeader: Identifiable {
        let id = UUID()
        var name: String
        var value: String
    }

    var body: some View {
        let r = row.resource
        ThreadScrollView {
            VStack(alignment: .leading, spacing: 0) {
                NetSection(title: "General") {
                    NetPairs(pairs: general)
                }
                if !row.failed || !row.responseHeaders.isEmpty {
                    NetSection(title: "Response headers (\(row.responseHeaders.count))") {
                        HStack(spacing: 10) {
                            Toggle("Raw", isOn: $rawResponse).toggleStyle(NetCheckboxStyle()).controlSize(.small)
                            if row.hop == nil, row.finished, !row.failed, !browser.netEditingHeaders {
                                Button("Override headers") { startEditing() }
                                    .buttonStyle(.link)
                                    .font(.system(size: 11.5))
                            }
                        }
                    } content: {
                        if browser.netEditingHeaders {
                            editor
                        } else if rawResponse {
                            NetRaw(text: statusLine + "\n" + NetCopy.headers(row.responseHeaders))
                        } else {
                            NetPairs(pairs: row.responseHeaders.map { ($0.name, $0.value) }, marked: overridden)
                        }
                    }
                }
                NetSection(title: "Request headers (\(row.requestHeaders.count))") {
                    Toggle("Raw", isOn: $rawRequest).toggleStyle(NetCheckboxStyle()).controlSize(.small)
                } content: {
                    if provisional {
                        HStack(spacing: 6) {
                            Symbol("exclamationmark.triangle", size: 10).foregroundStyle(DevLook.amber)
                            Text(row.fromCache ? "Provisional headers are shown. Disable cache to see full headers." : "Provisional headers are shown.")
                        }
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 4)
                    }
                    if rawRequest {
                        NetRaw(text: "\(row.method) \(row.path) \(r.proto.isEmpty || r.proto == "http/1.1" ? "HTTP/1.1" : r.proto.uppercased())\n" + NetCopy.headers(row.requestHeaders))
                    } else {
                        NetPairs(pairs: row.requestHeaders.map { ($0.name, $0.value) })
                    }
                }
            }
        }
    }

    private var overridden: Set<String> {
        guard panel.overridden[row.url] != nil else { return [] }
        return Set(row.responseHeaders.map { $0.name.lowercased() })
    }

    private var provisional: Bool {
        row.hop == nil && (row.fromCache || (row.resource.requestHeaderBytes == 0 && row.requestHeaders.count < 3))
    }

    private var statusLine: String {
        let proto = row.resource.proto
        return (proto.isEmpty || proto == "http/1.1" ? "HTTP/1.1" : proto.uppercased()) + " \(row.status) \(row.statusText)"
    }

    private var general: [(String, String)] {
        let r = row.resource
        var out: [(String, String)] = [("Request URL", row.url), ("Request method", row.method)]
        if row.hop == nil, r.blockedBy != nil || r.failed {
            out.append(("Status code", row.statusLabel + (r.failure.isEmpty ? "" : " " + r.failure)))
        } else {
            let cache = row.fromCache ? " (from \(r.source == "memory-cache" ? "memory" : "disk") cache)" : ""
            out.append(("Status code", row.status > 0 ? "● \(row.status) \(row.statusText)\(cache)" : row.statusLabel))
        }
        if row.hop == nil, !r.remote.isEmpty { out.append(("Remote address", r.remote)) }
        if row.hop == nil, !r.referrerPolicy.isEmpty { out.append(("Referrer policy", r.referrerPolicy)) }
        if row.hop == nil, let protocolName = r.security["protocol"], !protocolName.isEmpty {
            out.append(("Connection", protocolName + (r.security["cipher"].map { ", " + $0 } ?? "")))
        }
        return out
    }

    private func startEditing() {
        edits = row.responseHeaders.map { EditedHeader(name: $0.name, value: $0.value) }
        browser.netEditingHeaders = true
    }

    /// Override headers: the response's headers to change, add or take
    /// away; kept as a WebKit override from the next load.
    private var editor: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach($edits) { $header in
                HStack(spacing: 6) {
                    TextField("Header name", text: $header.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    TextField("Value", text: $header.value)
                        .textFieldStyle(.roundedBorder)
                    Button { edits.removeAll { $0.id == header.id } } label: { Symbol("xmark", size: 11) }
                        .buttonStyle(.yab(.quiet, .small, icon: .square))
                        .keyTip("Remove this header override")
                }
            }
            HStack(spacing: 6) {
                Button("Add header") { edits.append(EditedHeader(name: "", value: "")) }
                    .buttonStyle(.yab(.quiet, .small))
                Spacer()
                Button("Cancel") { browser.netEditingHeaders = false }
                    .buttonStyle(.yab(.quiet, .small))
                Button("Save") { save() }
                    .buttonStyle(.yab(.primary, .small))
            }
        }
        .font(.system(size: 11.5))
        .padding(.leading, 24) // design: under its section's title, as Chromium's
        .padding(.trailing, 10) // design: under its section's title, as Chromium's
        .onAppear { if edits.isEmpty { edits = row.responseHeaders.map { EditedHeader(name: $0.name, value: $0.value) } } }
    }

    private func save() {
        var headers: [String: String] = [:]
        let kept = Set(edits.map { $0.name.lowercased() })
        for header in row.responseHeaders where !kept.contains(header.name.lowercased()) { headers[header.name] = "" }
        for edit in edits where !edit.name.trimmingCharacters(in: .whitespaces).isEmpty {
            // Chrome splits "Name: value" pasted into the name.
            if edit.value.isEmpty, let colon = edit.name.firstIndex(of: ":") {
                headers[String(edit.name[..<colon]).trimmingCharacters(in: .whitespaces)] = String(edit.name[edit.name.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            } else {
                headers[edit.name.trimmingCharacters(in: .whitespaces)] = edit.value
            }
        }
        browser.netOverrideHeaders(row, headers)
        browser.netEditingHeaders = false
    }
}

// MARK: - Payload

struct NetPayloadTab: View {
    let row: NetRow
    @State private var source = false
    @State private var encoded = false
    @State private var bodySource = false

    var body: some View {
        let query = URLComponents(string: row.url)
        ThreadScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let items = query?.queryItems, !items.isEmpty {
                    NetSection(title: "Query string parameters (\(items.count))") {
                        HStack(spacing: 10) {
                            Button(source ? "View parsed" : "View source") { source.toggle() }.buttonStyle(.link)
                            if !source { Button(encoded ? "View decoded" : "View URL-encoded") { encoded.toggle() }.buttonStyle(.link) }
                        }
                        .font(.system(size: 11.5))
                    } content: {
                        if source {
                            NetRaw(text: query?.percentEncodedQuery ?? "")
                        } else {
                            NetPairs(pairs: encoded ? (query?.percentEncodedQueryItems ?? []).map { ($0.name, $0.value ?? "") } : items.map { ($0.name, $0.value ?? "") })
                        }
                    }
                }
                if row.hop == nil, let post = row.resource.postData {
                    let type = (row.resource.postType ?? row.requestHeaders.value("Content-Type") ?? "").lowercased()
                    if type.contains("x-www-form-urlencoded") {
                        let items = URLComponents(string: "?" + post)?.queryItems ?? []
                        NetSection(title: "Form data") {
                            Button(bodySource ? "View parsed" : "View source") { bodySource.toggle() }.buttonStyle(.link).font(.system(size: 11.5))
                        } content: {
                            if bodySource { NetRaw(text: post) } else { NetPairs(pairs: items.map { ($0.name, $0.value ?? "") }) }
                        }
                    } else {
                        NetSection(title: "Request payload") {
                            Button(bodySource ? "View parsed" : "View source") { bodySource.toggle() }.buttonStyle(.link).font(.system(size: 11.5))
                        } content: {
                            if !bodySource, let json = NetJSON.parse(post) {
                                NetJSONTree(value: json).padding(.leading, 16)
                            } else {
                                NetRaw(text: post)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Preview and Response

/// What Preview draws for a body, as Chromium picks it: a picture, a font's
/// letters, JSON's tree, the page drawn, or the words.
enum NetPreviewKind: String {
    case image, font, json, html, binary, text

    static func of(_ row: NetRow, _ body: NetBody) -> NetPreviewKind {
        let mime = row.resource.mime.lowercased()
        if mime.hasPrefix("image/"), body.data.flatMap(NSImage.init(data:)) != nil { return .image }
        if row.resource.type == "font" || mime.contains("font") || mime.hasSuffix("woff2"), body.data.flatMap({ NetFonts.font($0, size: 24) }) != nil { return .font }
        if !body.base64, NetJSON.looksLike(body.text) { return .json }
        if mime.contains("html"), !body.base64 { return .html }
        return body.base64 ? .binary : .text
    }
}

struct NetPreviewTab: View {
    let row: NetRow
    let content: NetBody?
    /// JSON read once, off the main thread when it is large.
    @State private var json: NetJSONReply?
    @State private var read = false

    var body: some View {
        if row.failed {
            NetNote(words: "Failed to load response data: \(row.resource.failure.isEmpty ? "no data found for resource with given identifier" : row.resource.failure)")
        } else if !row.finished {
            NetNote(words: "This request is still loading.")
        } else if let body = content {
            if let error = body.error {
                NetNote(words: error == "gone" ? "This request has no response data available." : "Failed to load response data: \(error)")
            } else {
                preview(body)
            }
        } else {
            NetNote(words: "Loading…")
        }
    }

    @ViewBuilder private func preview(_ body: NetBody) -> some View {
        let mime = row.resource.mime.lowercased()
        switch NetPreviewKind.of(row, body) {
        case .image:
            if let data = body.data, let image = NSImage(data: data) {
                VStack(spacing: 8) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: min(image.size.width, 480), maxHeight: min(image.size.height, 320))
                        .padding(6)
                        .background(Palette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                    Text("\(Int(image.size.width)) × \(Int(image.size.height)) · \(NetFormat.size(data.count)) · \(mime)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .font:
            if let data = body.data, let font = NetFonts.font(data, size: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(["ABCDEFGHIJKLM", "NOPQRSTUVWXYZ", "abcdefghijklm", "nopqrstuvwxyz", "1234567890"], id: \.self) { line in
                        Text(line).font(Font(font))
                    }
                    Text("\(font.familyName ?? "") · \(NetFormat.size(data.count))").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        case .json:
            Group {
                if let json {
                    ThreadScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            // What guards the reply, or the JSONP call round it, as Chromium shows it.
                            if !json.prefix.isEmpty { Text(json.prefix).foregroundStyle(Palette.muted).padding(.leading, 12) }
                            NetJSONTree(value: json.value)
                            if !json.suffix.isEmpty { Text(json.suffix).foregroundStyle(Palette.muted).padding(.leading, 12) }
                        }
                        .font(DevMono.font(11.5))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if read {
                    NetCode(text: body.text, mime: mime, lines: true)
                } else {
                    NetNote(words: "Loading…")
                }
            }
            .task(id: body.text.utf8.count) {
                let text = body.text
                json = text.utf8.count < NetPretty.inline ? NetJSON.reply(text)
                    : await Task.detached(priority: .userInitiated) { NetJSON.reply(text) }.value
                read = true
            }
        case .html:
            NetHTMLPreview(html: body.text)
        case .binary:
            NetNote(words: "Binary data. See Response for its bytes.")
        case .text:
            NetCode(text: body.text, mime: mime, lines: true)
        }
    }
}

struct NetResponseTab: View {
    let row: NetRow
    let content: NetBody?
    /// Chrome's "Automatically pretty print minified sources": on unless
    /// `{ }` turned it off, kept for every request and the next launch.
    @AppStorage(NetPretty.key, store: Store.settings) private var pretty = true
    /// The words formatted, once for a body and a choice, off the main
    /// thread when they are large; nil where there is nothing to format.
    @State private var formatted: NetFormatted?

    var body: some View {
        if row.failed {
            NetNote(words: "Failed to load response data: \(row.resource.failure.isEmpty ? "no data found for resource with given identifier" : row.resource.failure)")
        } else if !row.finished, row.resource.type != "eventsource" {
            NetNote(words: "This request is still loading.")
        } else if let body = content {
            if let error = body.error {
                NetNote(words: error == "gone" ? "This request has no response data available." : "Failed to load response data: \(error)")
            } else if body.base64 {
                if row.resource.mime.hasPrefix("image/") {
                    NetNote(words: "This request has no response text. See Preview.")
                } else {
                    NetCode(text: NetHex.dump(body.data ?? Data()), mime: "")
                }
            } else {
                words(body)
            }
        } else {
            NetNote(words: "Loading…")
        }
    }

    @ViewBuilder private func words(_ body: NetBody) -> some View {
        let mime = row.resource.mime.lowercased()
        let key = "\(body.text.utf8.count)-\(pretty)"
        let large = body.text.utf8.count >= NetPretty.inline
        // Small ones at once, from the few kept; large ones once formatted.
        let shown = formatted?.key == key ? formatted?.text : large && pretty ? nil : NetPretty.now(body.text, mime: mime, pretty: pretty)
        VStack(spacing: 0) {
            if let shown {
                NetCode(text: shown, mime: mime, lines: true)
            } else {
                NetNote(words: "Formatting…")
            }
            Rectangle().fill(Palette.ink.opacity(0.06)).frame(height: 1)
            HStack(spacing: 6) {
                Button { pretty.toggle() } label: { Text("{ }").font(DevMono.font(11.5, weight: .semibold)) }
                    .buttonStyle(.yab(pretty ? .secondary : .quiet, .small))
                    .keyTip("Pretty print")
                Text(pretty && shown != nil && shown != body.text ? "Pretty printed" : "\(body.text.utf8.count.formatted()) bytes")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
        }
        .task(id: key) {
            guard pretty, large else { return }
            let text = body.text
            let done = await Task.detached(priority: .userInitiated) { NetPretty.auto(text, mime: mime) ?? text }.value
            formatted = NetFormatted(key: key, text: done)
        }
    }
}

/// A body's words as Response shows them, for one choice of `{ }`.
struct NetFormatted: Equatable {
    let key: String
    let text: String
}

/// Text as code: selectable, in a fixed-width face, colored as Chromium
/// colors JSON, scripts, styles and markup; past a few hundred kilobytes
/// plain, as the colors would cost more than they show.
struct NetCode: NSViewRepresentable {
    let text: String
    let mime: String
    /// Each line's number down the side, as Chromium's Response has them.
    var lines = false

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        if let view = scroll.documentView as? NSTextView {
            AppleWritingTools.shared.apply(to: view)
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.textContainerInset = NSSize(width: 8, height: 8)
            view.isRichText = true
            view.usesFindBar = true
            view.isIncrementalSearchingEnabled = true
            if lines {
                // Chrome's Response wraps none: a long line runs on, scrolled to.
                view.isHorizontallyResizable = true
                view.textContainer?.widthTracksTextView = false
                view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                scroll.hasHorizontalScroller = true
                let ruler = NetLineRuler(view: view)
                scroll.verticalRulerView = ruler
                scroll.hasVerticalRuler = true
                scroll.rulersVisible = true
            }
        }
        ThreadScroller.put(on: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, context.coordinator.shown != text else { return }
        context.coordinator.shown = text
        view.textStorage?.setAttributedString(NetHighlight.attributed(text, mime: mime))
        (scroll.verticalRulerView as? NetLineRuler)?.read(text)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var shown: String? }
}

/// The numbers down the side of code, each at its line's first row, quiet,
/// as Chromium's gutter. Where each line starts is read once with the words.
final class NetLineRuler: NSRulerView {
    private weak var view: NSTextView?
    private var starts: [Int] = [0]
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    init(view: NSTextView) {
        self.view = view
        super.init(scrollView: view.enclosingScrollView, orientation: .verticalRuler)
        clientView = view
        ruleThickness = 32
        // Numbers past the bottom line stay in the ruler, not over the bar under it.
        clipsToBounds = true
        NotificationCenter.default.addObserver(self, selector: #selector(moved), name: NSView.boundsDidChangeNotification, object: view.enclosingScrollView?.contentView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func moved() { needsDisplay = true }

    func read(_ text: String) {
        var out = [0], at = 0
        for unit in text.utf16 {
            at += 1
            if unit == 10 { out.append(at) }
        }
        starts = out
        let digits = max(2, String(out.count).count)
        ruleThickness = CGFloat(digits) * 7 + 12
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let view, let layout = view.layoutManager, let container = view.textContainer else { return }
        let visible = view.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Palette.NS.muted]
        // The first line in sight, then each after it while it is.
        var line = max(0, (starts.firstIndex { $0 > chars.location } ?? starts.count) - 1)
        let inset = view.textContainerInset.height
        while line < starts.count, starts[line] <= NSMaxRange(chars) {
            let start = starts[line]
            guard start <= (view.string as NSString).length else { break }
            let glyph = layout.glyphIndexForCharacter(at: start)
            var box = layout.lineFragmentRect(forGlyphAt: min(glyph, max(0, layout.numberOfGlyphs - 1)), effectiveRange: nil)
            if layout.numberOfGlyphs == 0 { box = .zero }
            let y = convert(NSPoint(x: 0, y: box.minY + inset), from: view).y
            if y > bounds.maxY { break }
            let label = NSAttributedString(string: String(line + 1), attributes: attributes)
            let size = label.size()
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y + (box.height - size.height) / 2))
            line += 1
        }
    }
}

/// HTML as Chromium previews it: drawn, with no scripts and nothing loaded.
struct NetHTMLPreview: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = Web.pool
        AppleWritingTools.configure(configuration)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.setValue(false, forKey: "drawsBackground")
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "yab-net-preview",
                                                                encodedContentRuleList: #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#) { list, _ in
            if let list { web.configuration.userContentController.add(list) }
            web.loadHTMLString(html, baseURL: nil)
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}
}

enum NetFonts {
    static func font(_ data: Data, size: CGFloat) -> CTFont? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor], let first = descriptors.first else { return nil }
        return CTFontCreateWithFontDescriptor(first, size, nil)
    }
}

extension CTFont {
    var familyName: String? { CTFontCopyFamilyName(self) as String }
}

enum NetHex {
    /// Bytes as Chromium's binary view: offset, sixteen bytes, their text.
    static func dump(_ data: Data, limit: Int = 65536) -> String {
        var lines: [String] = []
        let bytes = [UInt8](data.prefix(limit))
        var offset = 0
        while offset < bytes.count {
            let chunk = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let text = String(chunk.map { (32..<127).contains($0) ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08x  ", offset) + hex.padding(toLength: 48, withPad: " ", startingAt: 0) + "  " + text)
            offset += 16
        }
        if data.count > limit { lines.append("… \(NetFormat.size(data.count - limit)) more") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - JSON, in its own order

/// JSON as it was written, its keys in their order, as Chromium's preview
/// keeps them (JSONSerialization would sort them as it pleased).
indirect enum NetJSON: Equatable, Sendable {
    case object([(String, NetJSON)])
    case array([NetJSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    static func == (a: NetJSON, b: NetJSON) -> Bool {
        switch (a, b) {
        case let (.object(x), .object(y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.array(x), .array(y)): return x == y
        case let (.string(x), .string(y)), let (.number(x), .number(y)): return x == y
        case let (.bool(x), .bool(y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    /// What APIs put before a reply so a page can't run it as a script,
    /// read past by Chrome's preview as by the page's own code.
    static let guards = [")]}',", ")]}'", "while(1);", "while (1);", "for(;;);", "for (;;);", "{}&&"]

    /// A reply as Chromium's preview reads it: plain JSON, or JSON after a
    /// guard or inside a JSONP call, the words round it kept to be shown.
    static func reply(_ text: String) -> NetJSONReply? {
        var body = Substring(text)
        if body.first == "\u{FEFF}" { body = body.dropFirst() }
        body = body.drop { $0.isWhitespace || $0.isNewline }
        if let value = parse(String(body)) { return NetJSONReply(prefix: "", value: value, suffix: "") }
        if let guarded = guards.first(where: { body.hasPrefix($0) }) {
            guard let value = parse(String(body.dropFirst(guarded.count))) else { return nil }
            return NetJSONReply(prefix: guarded, value: value, suffix: "")
        }
        // JSONP: callback({...}) or a.b.c([...]);
        guard let open = body.firstIndex(of: "("), body[..<open].allSatisfy({ $0.isLetter || $0.isNumber || "_$.".contains($0) }),
              !body[..<open].isEmpty, let first = body[..<open].first, !first.isNumber else { return nil }
        var end = body.endIndex
        while end > open, body[body.index(before: end)].isWhitespace || body[body.index(before: end)] == ";" { end = body.index(before: end) }
        guard end > body.index(after: open), body[body.index(before: end)] == ")" else { return nil }
        let inner = body[body.index(after: open)..<body.index(before: end)]
        guard let value = parse(String(inner)) else { return nil }
        return NetJSONReply(prefix: String(body[...open]), value: value, suffix: String(body[body.index(before: end)...]))
    }

    /// Cheap first look, for which pane draws it: its first character an
    /// object's or an array's, after a guard or a call; reply() decides.
    static func looksLike(_ text: String) -> Bool {
        var body = Substring(text.prefix(512))
        if body.first == "\u{FEFF}" { body = body.dropFirst() }
        body = body.drop { $0.isWhitespace || $0.isNewline }
        if let guarded = guards.first(where: { body.hasPrefix($0) }) { body = body.dropFirst(guarded.count).drop { $0.isWhitespace || $0.isNewline } }
        if body.first == "{" || body.first == "[" { return text.utf8.count < 64_000 ? reply(text) != nil : true }
        if let open = body.firstIndex(of: "("), open > body.startIndex, body[..<open].allSatisfy({ $0.isLetter || $0.isNumber || "_$.".contains($0) }) {
            return text.utf8.count < 64_000 ? reply(text) != nil : true
        }
        return false
    }

    static func parse(_ text: String) -> NetJSON? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[", trimmed.utf8.count < 8_000_000 else { return nil }
        var parser = Parser(Array(trimmed.utf8))
        guard let value = parser.value() else { return nil }
        parser.space()
        return parser.at == parser.bytes.count ? value : nil
    }

    private struct Parser {
        let bytes: [UInt8]
        var at = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func space() { while at < bytes.count, [32, 9, 10, 13].contains(bytes[at]) { at += 1 } }

        mutating func value() -> NetJSON? {
            space()
            guard at < bytes.count else { return nil }
            switch bytes[at] {
            case UInt8(ascii: "{"):
                at += 1
                var pairs: [(String, NetJSON)] = []
                space()
                if at < bytes.count, bytes[at] == UInt8(ascii: "}") { at += 1; return .object(pairs) }
                while true {
                    space()
                    guard case .string(let key)? = string() else { return nil }
                    space()
                    guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { return nil }
                    at += 1
                    guard let v = value() else { return nil }
                    pairs.append((key, v))
                    space()
                    guard at < bytes.count else { return nil }
                    if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                    if bytes[at] == UInt8(ascii: "}") { at += 1; return .object(pairs) }
                    return nil
                }
            case UInt8(ascii: "["):
                at += 1
                var items: [NetJSON] = []
                space()
                if at < bytes.count, bytes[at] == UInt8(ascii: "]") { at += 1; return .array(items) }
                while true {
                    guard let v = value() else { return nil }
                    items.append(v)
                    space()
                    guard at < bytes.count else { return nil }
                    if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                    if bytes[at] == UInt8(ascii: "]") { at += 1; return .array(items) }
                    return nil
                }
            case UInt8(ascii: "\""): return string()
            case UInt8(ascii: "t"): return literal("true", .bool(true))
            case UInt8(ascii: "f"): return literal("false", .bool(false))
            case UInt8(ascii: "n"): return literal("null", .null)
            default:
                let start = at
                while at < bytes.count, "+-0123456789.eE".utf8.contains(bytes[at]) { at += 1 }
                guard at > start, let number = String(bytes: bytes[start..<at], encoding: .utf8), Double(number) != nil else { return nil }
                return .number(number)
            }
        }

        mutating func literal(_ word: String, _ v: NetJSON) -> NetJSON? {
            let w = Array(word.utf8)
            guard at + w.count <= bytes.count, Array(bytes[at..<at + w.count]) == w else { return nil }
            at += w.count
            return v
        }

        mutating func string() -> NetJSON? {
            guard at < bytes.count, bytes[at] == UInt8(ascii: "\"") else { return nil }
            let start = at
            at += 1
            var escaped = false
            while at < bytes.count {
                let b = bytes[at]
                if escaped { escaped = false } else if b == UInt8(ascii: "\\") { escaped = true } else if b == UInt8(ascii: "\"") { break }
                at += 1
            }
            guard at < bytes.count else { return nil }
            at += 1
            let raw = Data(bytes[start..<at])
            guard let decoded = try? JSONSerialization.jsonObject(with: raw, options: .fragmentsAllowed) as? String else { return nil }
            return .string(decoded)
        }
    }

    /// One line's preview of an object or array, as Chromium writes it.
    var preview: String {
        switch self {
        case .object(let pairs):
            let shown = pairs.prefix(4).map { "\($0.0): \($0.1.short)" }.joined(separator: ", ")
            return "{" + shown + (pairs.count > 4 ? ", …" : "") + "}"
        case .array(let items): return "Array(\(items.count))"
        default: return short
        }
    }

    var short: String {
        switch self {
        case .object: return "{…}"
        case .array(let items): return "Array(\(items.count))"
        case .string(let s): return "\"" + (s.count > 40 ? String(s.prefix(40)) + "…" : s) + "\""
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        }
    }

    /// Written again with two spaces a level, its keys where they were.
    func pretty(_ depth: Int = 0) -> String {
        let pad = String(repeating: "  ", count: depth + 1), end = String(repeating: "  ", count: depth)
        switch self {
        case .object(let pairs):
            if pairs.isEmpty { return "{}" }
            return "{\n" + pairs.map { pad + NetJSON.string($0.0).pretty() + ": " + $0.1.pretty(depth + 1) }.joined(separator: ",\n") + "\n" + end + "}"
        case .array(let items):
            if items.isEmpty { return "[]" }
            return "[\n" + items.map { pad + $0.pretty(depth + 1) }.joined(separator: ",\n") + "\n" + end + "]"
        case .string(let s):
            return (try? String(data: JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]), encoding: .utf8)).map { String($0.dropFirst().dropLast()) } ?? "\"\""
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        }
    }
}

/// JSON as Chromium's preview draws it: a tree, its keys purple, strings
/// red, numbers blue, the first level open.
struct NetJSONTree: View {
    let value: NetJSON
    var key: String? = nil
    var depth = 0
    @State private var open: Bool?

    var body: some View {
        let isOpen = open ?? (depth < 1)
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                switch value {
                case .object, .array:
                    Button { open = !isOpen } label: {
                        Symbol("chevron.right", size: 7)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 10)
                    }
                    .buttonStyle(.plain)
                default:
                    Color.clear.frame(width: 10, height: 1)
                }
                if let key { Text(key + ":").foregroundStyle(Color(nsColor: NetHighlight.key)) }
                Text(value.leaf ?? value.preview)
                    .foregroundStyle(value.leaf != nil ? Color(nsColor: value.color) : Palette.muted)
                    .textSelection(.enabled)
                    .lineLimit(value.leaf != nil ? 4 : 1)
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 1) {
                    switch value {
                    case .object(let pairs):
                        ForEach(Array(pairs.prefix(500).enumerated()), id: \.offset) { _, pair in
                            NetJSONTree(value: pair.1, key: pair.0, depth: depth + 1)
                        }
                        if pairs.count > 500 { Text("… \(pairs.count - 500) more").foregroundStyle(Palette.muted) }
                    case .array(let items):
                        ForEach(Array(items.prefix(500).enumerated()), id: \.offset) { index, item in
                            NetJSONTree(value: item, key: String(index), depth: depth + 1)
                        }
                        if items.count > 500 { Text("… \(items.count - 500) more").foregroundStyle(Palette.muted) }
                    default: EmptyView()
                    }
                }
                .padding(.leading, 12)
            }
        }
        .font(DevMono.font(11.5))
    }
}

extension NetJSON {
    var leaf: String? {
        switch self {
        case .object, .array: return nil
        case .string(let s): return "\"" + s + "\""
        default: return short
        }
    }

    var color: NSColor {
        switch self {
        case .string: return NetHighlight.string
        case .number: return NetHighlight.number
        case .bool, .null: return NetHighlight.literal
        default: return Palette.NS.ink
        }
    }
}

/// JSON as a reply carries it, with the guard or the call round it.
struct NetJSONReply: Equatable, Sendable {
    let prefix: String
    let value: NetJSON
    let suffix: String
}

enum NetPretty {
    /// Where `{ }` is kept.
    static let key = "dev.net.pretty"
    /// Larger than this, formatted off the main thread.
    static let inline = 200_000

    /// Response's words with `{ }` on, as Chromium shows them: JSON always
    /// laid out, its every character kept as written; styles and scripts
    /// when they are minified (a line past 500 characters, Chrome's test).
    /// Nil where there is nothing to lay out.
    static func auto(_ text: String, mime: String) -> String? {
        if let reply = NetJSON.reply(text) {
            // The guard or the call round it kept as it came, on its own line.
            var body = Substring(text)
            if body.first == "\u{FEFF}" { body = body.dropFirst() }
            body = body.drop { $0.isWhitespace || $0.isNewline }.dropFirst(reply.prefix.count)
            while let last = body.last, last.isWhitespace || last.isNewline { body = body.dropLast() }
            body = body.dropLast(reply.suffix.count)
            let laid = json(String(body))
            let out = reply.prefix.isEmpty && reply.suffix.isEmpty ? laid
                : reply.prefix + (reply.suffix.isEmpty ? "\n" : "") + laid + reply.suffix
            return out == text ? nil : out
        }
        guard mime.contains("css") || mime.contains("javascript") || mime.contains("ecmascript"), minified(text) else { return nil }
        let out = format(text, mime: mime)
        return out == text ? nil : out
    }

    static func minified(_ text: String) -> Bool {
        var run = 0
        for unit in text.utf8 {
            if unit == 10 { run = 0 } else { run += 1; if run > 500 { return true } }
        }
        return false
    }

    /// A few small ones kept, so a row drawn again doesn't lay out again.
    @MainActor private static var kept: [String: String] = [:]

    @MainActor static func now(_ text: String, mime: String, pretty: Bool) -> String {
        guard pretty, text.utf8.count < inline else { return text }
        if let done = kept[text] { return done }
        let done = auto(text, mime: mime) ?? text
        if kept.count > 8 { kept.removeAll() }
        kept[text] = done
        return done
    }

    /// JSON laid out two spaces a level, as Chromium's formatter does: only
    /// the space between tokens changes, a string, a number and a guard
    /// stay as they were written; `{}` and `[]` stay closed.
    static func json(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 2)
        var depth = 0, i = 0
        var quoted = false, escaped = false
        func newline() {
            out.append(10)
            for _ in 0..<(depth * 2) { out.append(32) }
        }
        func next(after index: Int) -> UInt8? {
            var j = index + 1
            while j < bytes.count, [32, 9, 10, 13].contains(bytes[j]) { j += 1 }
            return j < bytes.count ? bytes[j] : nil
        }
        while i < bytes.count {
            let b = bytes[i]
            if quoted {
                out.append(b)
                if escaped { escaped = false } else if b == 92 { escaped = true } else if b == 34 { quoted = false }
                i += 1
                continue
            }
            switch b {
            case 32, 9, 10, 13: break
            case 34: quoted = true; out.append(b)
            case 123, 91: // { [
                out.append(b)
                let close: UInt8 = b == 123 ? 125 : 93
                if next(after: i) == close {
                    var j = i + 1
                    while bytes[j] != close { j += 1 }
                    out.append(close)
                    i = j
                } else {
                    depth += 1
                    newline()
                }
            case 125, 93: // } ]
                depth = max(0, depth - 1)
                newline()
                out.append(b)
            case 44: out.append(b); if depth > 0 { newline() }
            case 58: out.append(b); out.append(32)
            default: out.append(b)
            }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func format(_ text: String, mime: String) -> String {
        if NetJSON.reply(text) != nil { return auto(text, mime: mime) ?? text }
        if mime.contains("css") { return css(text) }
        if mime.contains("javascript") { return script(text) }
        return text
    }

    /// Minified styles a rule a line, a declaration a line.
    static func css(_ text: String) -> String {
        var out = "", depth = 0
        for ch in text {
            switch ch {
            case "{": depth += 1; out += " {\n" + String(repeating: "  ", count: depth)
            case "}": depth = max(0, depth - 1); out = out.trimmingTrailingSpaces() + "\n" + String(repeating: "  ", count: depth) + "}\n" + String(repeating: "  ", count: depth)
            case ";": out += ";\n" + String(repeating: "  ", count: depth)
            default: out.append(ch)
            }
        }
        return out
    }

    /// Minified script broken at its braces and statements; strings kept.
    static func script(_ text: String) -> String {
        var out = "", depth = 0, quote: Character?, escaped = false, paren = 0
        for ch in text {
            if let q = quote {
                out.append(ch)
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == q { quote = nil }
                continue
            }
            switch ch {
            case "\"", "'", "`": quote = ch; out.append(ch)
            case "(": paren += 1; out.append(ch)
            case ")": paren = max(0, paren - 1); out.append(ch)
            case "{": depth += 1; out += "{\n" + String(repeating: "    ", count: depth)
            case "}": depth = max(0, depth - 1); out = out.trimmingTrailingSpaces() + "\n" + String(repeating: "    ", count: depth) + "}"
            case ";" where paren == 0: out += ";\n" + String(repeating: "    ", count: depth)
            case "\n": out += "\n" + String(repeating: "    ", count: depth)
            default: out.append(ch)
            }
        }
        return out
    }
}

private extension String {
    func trimmingTrailingSpaces() -> String {
        var s = self
        while s.last == " " || s.last == "\n" { s.removeLast() }
        return s
    }
}

/// Chrome's colors for code.
enum NetHighlight {
    /// JSON's four, as numbers, light and dark: these colors and the JSON
    /// viewer's page (JSONView.colors) are one source.
    static let json: [(name: String, light: Int, dark: Int)] = [
        ("key", 0x881280, 0xE36EEC), ("string", 0xC41A16, 0xF28B54),
        ("number", 0x1C00CF, 0x9980FF), ("literal", 0x0D22AA, 0x7AB6FF),
    ]
    static let key = NetInk.pair(json[0].light, json[0].dark)
    static let string = NetInk.pair(json[1].light, json[1].dark)
    static let number = NetInk.pair(json[2].light, json[2].dark)
    static let literal = NetInk.pair(json[3].light, json[3].dark)
    static let tag = NetInk.pair(0x881280, 0x5DB0D7)
    static let attribute = NetInk.pair(0x994500, 0x9BBBDC)
    static let comment = NetInk.pair(0x6E7781, 0x8B949E)

    static func attributed(_ text: String, mime: String) -> NSAttributedString {
        let font = DevMono.nsFont(11.5, weight: .regular)
        let out = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: Palette.NS.ink])
        guard text.utf8.count < 400_000 else { return out }
        let ns = text as NSString
        func paint(_ pattern: String, _ color: NSColor, group: Int = 0, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let range = match.range(at: group)
                if range.location != NSNotFound { out.addAttribute(.foregroundColor, value: color, range: range) }
            }
        }
        if mime.contains("json") || NetJSON.looksLike(text) {
            paint(#"-?\b\d+(\.\d+)?([eE][+-]?\d+)?\b"#, number)
            paint(#"\b(true|false|null)\b"#, literal)
            paint(#""(?:[^"\\]|\\.)*""#, string)
            paint(#"("(?:[^"\\]|\\.)*")\s*:"#, key, group: 1)
        } else if mime.contains("html") || mime.contains("xml") || mime.contains("svg") {
            paint(#"</?([A-Za-z][\w:-]*)"#, tag, group: 1)
            paint(#"\s([\w:-]+)="#, attribute, group: 1)
            paint(#""[^"]*""#, string)
            paint(#"<!--[\s\S]*?-->"#, comment)
        } else if mime.contains("css") {
            paint(#"([\w-]+)\s*:"#, attribute, group: 1)
            paint(#""[^"]*"|'[^']*'"#, string)
            paint(#"/\*[\s\S]*?\*/"#, comment)
        } else if mime.contains("javascript") || mime.contains("ecmascript") {
            paint(#"\b(const|let|var|function|return|if|else|for|while|import|from|export|default|new|class|extends|async|await|try|catch|throw|typeof|instanceof|this|null|undefined|true|false)\b"#, tag)
            paint(#"-?\b\d+(\.\d+)?\b"#, number)
            paint(#""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`(?:[^`\\]|\\.)*`"#, string)
            paint(#"//[^\n]*|/\*[\s\S]*?\*/"#, comment)
        }
        return out
    }
}

// MARK: - Initiator

struct NetInitiatorTab: View {
    let browser: Browser
    @ObservedObject var log: NetLog
    @ObservedObject var panel: NetPanel
    let row: NetRow

    var body: some View {
        let r = row.resource
        ThreadScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !r.initiator.stack.isEmpty {
                    NetSection(title: "Request call stack") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(r.initiator.stack.enumerated()), id: \.offset) { _, frame in
                                HStack(spacing: 6) {
                                    Text(frame.function).frame(minWidth: 180, alignment: .leading)
                                    Text("@")
                                        .foregroundStyle(Palette.muted)
                                    Button("\(NetRow.shortName(frame.url)):\(frame.line)") {
                                        browser.revealSource(DevPlace(url: frame.url, line: frame.line, column: frame.column))
                                    }
                                    .buttonStyle(.link)
                                    .pointerTip(frame.url)
                                }
                            }
                        }
                        .font(DevMono.font(11.5))
                        .padding(.leading, 24) // design: under its section's title, as Chromium's
                    }
                }
                NetSection(title: "Request initiator chain") {
                    VStack(alignment: .leading, spacing: 2) {
                        let chain = ancestors
                        ForEach(Array(chain.enumerated()), id: \.offset) { index, item in
                            link(item.url, id: item.id).padding(.leading, CGFloat(index) * 14)
                        }
                        Text(row.url).fontWeight(.semibold).padding(.leading, CGFloat(chain.count) * 14).textSelection(.enabled)
                        ForEach(children, id: \.id) { child in
                            link(child.url, id: child.id).padding(.leading, CGFloat(chain.count + 1) * 14)
                        }
                    }
                    .font(DevMono.font(11.5))
                    .padding(.leading, 24) // design: under its section's title, as Chromium's
                }
                if r.initiator.kind == .other, r.initiator.stack.isEmpty, row.from == nil {
                    NetNote(words: "This request has no initiator data.")
                }
            }
        }
    }

    private func link(_ url: String, id: Int?) -> some View {
        Button(url) { if let id { panel.selected = id } }
            .buttonStyle(.link)
            .lineLimit(1)
            .truncationMode(.middle)
            .disabled(id == nil)
    }

    private var ancestors: [(url: String, id: Int?)] {
        var out: [(url: String, id: Int?)] = []
        var current = row.resource
        if let from = row.from, let previous = log.rows.first(where: { $0.id == from }) { out.append((previous.url, previous.id)) }
        var seen = Set<Int>()
        while let parent = current.initiator.resource, !seen.contains(parent),
              let parentRow = log.rows.last(where: { $0.resource.id == parent && $0.hop == nil }) {
            seen.insert(parent)
            out.insert((parentRow.url, parentRow.id), at: 0)
            current = parentRow.resource
        }
        if out.isEmpty, !row.resource.initiator.url.isEmpty, row.resource.initiator.url != row.url { out.append((row.resource.initiator.url, nil)) }
        return out
    }

    private var children: [NetRow] {
        log.rows.filter { $0.hop == nil && $0.resource.initiator.resource == row.resource.id && $0.id != row.id }.prefix(200).map { $0 }
    }
}

// MARK: - Timing

struct NetTimingTab: View {
    @ObservedObject var log: NetLog
    let row: NetRow

    var body: some View {
        let origin = log.origin ?? row.span.start
        ThreadScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let phases = row.phases {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Queued at \(NetFormat.time((row.span.start - origin) * 1000))")
                        Text("Started at \(NetFormat.time((row.span.start - origin) * 1000 + phases.queueing))")
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                        heading("Resource scheduling", trailing: "DURATION")
                        bar("Queueing", phases.queueing, .queueing, phases)
                        heading("Connection start")
                        bar("Stalled", phases.stalled, .stalled, phases)
                        if phases.dns > 0 { bar("DNS lookup", phases.dns, .dns, phases) }
                        if phases.initialConnection > 0 { bar("Initial connection", phases.initialConnection, .connecting, phases) }
                        if phases.ssl > 0 { bar("SSL", phases.ssl, .ssl, phases) }
                        heading("Request/Response")
                        if phases.sending > 0 { bar("Request sent", phases.sending, .sending, phases) }
                        bar("Waiting for server response", phases.waiting, .waiting, phases)
                        bar("Content download", phases.download, .download, phases)
                        Divider().gridCellColumns(3)
                        GridRow {
                            Text("Explanation").foregroundStyle(Palette.muted)
                            Color.clear.frame(height: 1)
                            Text(row.pending ? "Pending" : NetFormat.time(row.duration ?? phases.total)).fontWeight(.semibold).gridColumnAlignment(.trailing)
                        }
                    }
                    .font(.system(size: 11.5))
                } else if row.fromCache {
                    NetNote(words: "This request was served from the \(row.resource.source == "memory-cache" ? "memory" : "disk") cache, so there is no timing to show.")
                } else if row.failed {
                    NetNote(words: row.resource.failure.isEmpty ? "The request was not sent." : row.resource.failure)
                } else {
                    NetNote(words: "WebKit measured no timing for this request: it was loaded before Developer Tools listened.")
                }
                serverTiming
            }
            .padding(10)
        }
    }

    private func heading(_ title: String, trailing: String = "") -> some View {
        GridRow {
            Text(title).fontWeight(.semibold).fixedSize().padding(.top, 6)
            Color.clear.frame(height: 1)
            Text(trailing).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted).gridColumnAlignment(.trailing)
        }
    }

    private func bar(_ title: String, _ value: Double, _ phase: NetPhases.Phase, _ phases: NetPhases) -> some View {
        let total = max(phases.total, 0.001)
        let before: Double = {
            var sum = 0.0
            for p in NetPhases.Phase.allCases {
                if p == phase || (phase == .connecting && p == .connecting) { break }
                sum += phases.value(p)
            }
            return sum
        }()
        return GridRow {
            Text(title).fixedSize().padding(.leading, 12)
            GeometryReader { geo in
                Rectangle()
                    .fill(Color(nsColor: NetInk.phase(phase)))
                    .overlay(phase == .queueing ? Rectangle().strokeBorder(Palette.ink.opacity(0.25)) : nil)
                    .frame(width: max(1, geo.size.width * value / total), height: 8)
                    .offset(x: geo.size.width * before / total, y: 3)
            }
            .frame(minWidth: 48, maxWidth: .infinity, minHeight: 14, maxHeight: 14)
            Text(NetFormat.time(value)).monospacedDigit().gridColumnAlignment(.trailing)
        }
    }

    /// Server Timing, read off its header: name, what it says, how long.
    @ViewBuilder private var serverTiming: some View {
        let entries = NetServerTiming.parse(row.responseHeaders.filter { $0.name.lowercased() == "server-timing" }.map(\.value).joined(separator: ", "))
        if entries.isEmpty {
            Text("During development, you can use the Server Timing API to add insights into the server-side timing of this request.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .padding(.top, 6)
        } else {
            let longest = max(entries.compactMap(\.duration).max() ?? 1, 0.001)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text("Server Timing").fontWeight(.semibold)
                    Color.clear.frame(height: 1)
                    Text("TIME").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted).gridColumnAlignment(.trailing)
                }
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    GridRow {
                        HStack(spacing: 4) {
                            Text(entry.name)
                            if !entry.description.isEmpty { Text(entry.description).foregroundStyle(Palette.muted) }
                        }
                        .padding(.leading, 12)
                        GeometryReader { geo in
                            if let duration = entry.duration {
                                Rectangle().fill(Palette.muted.opacity(0.5)).frame(width: max(1, geo.size.width * duration / longest), height: 8).offset(y: 3)
                            }
                        }
                        .frame(minWidth: 48, maxWidth: .infinity, minHeight: 14, maxHeight: 14)
                        Text(entry.duration.map(NetFormat.time) ?? "").monospacedDigit()
                    }
                }
            }
            .font(.system(size: 11.5))
            .padding(.top, 6)
        }
    }
}

struct NetServerTiming: Equatable {
    var name: String
    var description = ""
    var duration: Double?

    /// `db;dur=38.2;desc="Postgres", cache;desc=miss`.
    static func parse(_ header: String) -> [NetServerTiming] {
        header.split(separator: ",").compactMap { part in
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = pieces.first, !name.isEmpty else { return nil }
            var entry = NetServerTiming(name: name)
            for piece in pieces.dropFirst() {
                let kv = piece.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                let value = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                switch kv[0].lowercased() {
                case "dur": entry.duration = Double(value)
                case "desc": entry.description = value
                default: break
                }
            }
            return entry
        }
    }
}

// MARK: - Cookies

struct NetCookiesTab: View {
    let row: NetRow

    var body: some View {
        let response = NetCookie.response(row)
        ThreadScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                let request = NetCookie.request(row)
                if !request.isEmpty { NetSection(title: "Request cookies") { table(request) } }
                if !response.cookies.isEmpty { NetSection(title: "Response cookies") { table(response.cookies) } }
                if !response.malformed.isEmpty {
                    NetSection(title: "Malformed response cookies") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(response.malformed, id: \.self) { Text($0).font(DevMono.font(11)) }
                        }
                        .padding(.leading, 24) // design: under its section's title, as Chromium's
                    }
                }
            }
        }
        // Scrolling both ways centers what is smaller than the pane: Chrome's
        // tables start at the top left.
        .defaultScrollAnchor(.topLeading, for: .alignment)
    }

    private func table(_ cookies: [NetCookie]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            GridRow {
                ForEach(["Name", "Value", "Domain", "Path", "Expires / Max-Age", "Size", "HttpOnly", "Secure", "SameSite", "Partition key site", "Priority"], id: \.self) {
                    Text($0).foregroundStyle(Palette.muted).fixedSize()
                }
            }
            ForEach(Array(cookies.enumerated()), id: \.offset) { _, c in
                GridRow {
                    Text(c.name).fixedSize()
                    Text(c.value).lineLimit(1).frame(maxWidth: 220, alignment: .leading)
                    Text(c.domain).fixedSize()
                    Text(c.path).fixedSize()
                    Text(c.expires).fixedSize()
                    Text(String(c.size)).fixedSize()
                    Text(c.httpOnly ? "✓" : "")
                    Text(c.secure ? "✓" : "")
                    Text(c.sameSite).fixedSize()
                    Text(c.partitioned ? "✓" : "")
                    Text(c.priority).fixedSize()
                }
                .font(DevMono.font(11))
                .textSelection(.enabled)
            }
        }
        .font(.system(size: 11.5))
        .padding(.leading, 24) // design: under its section's title, as Chromium's
        .padding(.trailing, 10) // design: under its section's title, as Chromium's
    }
}

// MARK: - Messages and EventStream

struct NetMessagesTab: View {
    let row: NetRow
    @State private var words = ""
    @State private var direction = "all"
    @State private var from = 0
    @State private var picked: Int?

    var body: some View {
        let frames = row.resource.frames
        let regex = words.isEmpty ? nil : try? NSRegularExpression(pattern: words, options: .caseInsensitive)
        let shown = frames.indices.filter { index in
            guard index >= from else { return false }
            let frame = frames[index]
            if direction == "send", !frame.outgoing { return false }
            if direction == "receive", frame.outgoing { return false }
            guard !words.isEmpty, let data = frame.data else { return true }
            return regex.map { $0.firstMatch(in: data, range: NSRange(data.startIndex..., in: data)) != nil } ?? data.localizedCaseInsensitiveContains(words)
        }
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { from = frames.count; picked = nil } label: { Symbol("nosign", size: 11) }
                    .buttonStyle(.yab(.quiet, .small, icon: .square))
                    .keyTip("Clear all")
                TextField("Filter using regex (example: (web)?socket)", text: $words)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5))
                Picker("", selection: $direction) {
                    Text("All").tag("all")
                    Text("Send").tag("send")
                    Text("Receive").tag("receive")
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            .padding(6)
            Rectangle().fill(Palette.ink.opacity(0.06)).frame(height: 1)
            ThreadScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Data").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Length").frame(width: 56, alignment: .trailing)
                        Text("Time").frame(width: 92, alignment: .trailing)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    ForEach(shown, id: \.self) { index in
                        let frame = frames[index]
                        Button { picked = index } label: {
                            HStack(spacing: 6) {
                                Text(frame.outgoing ? "↑" : "↓").foregroundStyle(frame.outgoing ? Color(nsColor: NetInk.waiting) : Palette.muted)
                                Text(frame.data ?? (frame.opcode == 8 ? "Connection Close Frame" : "Binary Message"))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(String(frame.length)).frame(width: 56, alignment: .trailing)
                                Text(NetClock.time(frame.wall)).frame(width: 92, alignment: .trailing)
                            }
                            .font(DevMono.font(11))
                            .padding(.horizontal, 8)
                            .frame(height: 20)
                            .background(picked == index ? Color(nsColor: NetInk.picked) : frame.outgoing ? Color(nsColor: NetInk.up) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let picked, picked < frames.count {
                Rectangle().fill(Palette.ink.opacity(0.06)).frame(height: 1)
                let data = frames[picked].data ?? ""
                ThreadScrollView {
                    if let json = NetJSON.parse(data) {
                        NetJSONTree(value: json).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(data.isEmpty ? "Binary Message" : data).font(DevMono.font(11)).textSelection(.enabled).padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxHeight: 140)
            }
        }
    }
}

struct NetEventsTab: View {
    let row: NetRow
    @State private var words = ""
    @State private var from = 0

    var body: some View {
        let events = row.resource.events
        let regex = words.isEmpty ? nil : try? NSRegularExpression(pattern: words, options: .caseInsensitive)
        let shown = events.indices.filter { index in
            guard index >= from else { return false }
            guard let regex else { return true }
            let e = events[index], line = e.type + " " + e.data
            return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { from = events.count } label: { Symbol("nosign", size: 11) }
                    .buttonStyle(.yab(.quiet, .small, icon: .square))
                    .keyTip("Clear all")
                TextField("Filter using regex", text: $words)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5))
            }
            .padding(6)
            Rectangle().fill(Palette.ink.opacity(0.06)).frame(height: 1)
            if events.isEmpty {
                NetNote(words: "No events yet. Yab hears an EventSource's events from the page while Network is open.")
            }
            ThreadScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow {
                        ForEach(["ID", "Type", "Data", "Time"], id: \.self) { Text($0).foregroundStyle(Palette.muted) }
                    }
                    ForEach(shown, id: \.self) { index in
                        let e = events[index]
                        GridRow {
                            Text(e.id)
                            Text(e.type)
                            Text(e.data).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            Text(NetClock.time(e.wall))
                        }
                        .font(DevMono.font(11))
                        .textSelection(.enabled)
                    }
                }
                .font(.system(size: 11.5))
                .padding(8)
            }
        }
    }
}

enum NetClock {
    /// 16:42:11.284, the time of day a frame or an event came.
    static func time(_ wall: Double) -> String {
        guard wall > 0 else { return "" }
        let formatter = AppDates.formatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date(timeIntervalSince1970: wall))
    }
}
