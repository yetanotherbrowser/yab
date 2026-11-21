import SwiftUI
import UIKit

/// The chat's own screen, grown out of its face as Telegram's profile: ‹ and
/// ✎ (Rename) on glass, the face, the name, who answers and when with a chip
/// saying where, round actions with their words under them (Pin, Unread,
/// Open on Mac, Archive), one grouped card (Copy Answer, its page), and under
/// it what the chat touched in tabs: the sites its agent worked on, the
/// links said in it, its photos and its files. A tab with nothing in it
/// isn't there; with nothing at all, the page ends at the card.
///
/// The first frame is cheap so UIKit's zoom starts at once: the head and the
/// actions read only the chat's own fields, and the tabs' contents come from
/// ChatInfoMemo (kept per chat as it is, read off the main thread once).
struct ChatDetails: View {
    @Environment(AppModel.self) private var app
    let chat: Chat
    let presentation: ChatInfoPresentation
    @State private var copied = false
    @State private var opened = false
    @State private var linkCopied = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var contents: ChatInfoContents?
    @State private var tab: ChatInfoContents.Tab?
    private typealias R = Metrics.Chats

    init(chat: Chat, presentation: ChatInfoPresentation) {
        self.chat = chat
        self.presentation = presentation
        // Kept contents are there in the first frame: nothing pops in.
        _contents = State(initialValue: ChatInfoMemo.cached(chat))
        _tab = State(initialValue: ChatInfoScroll.tab)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                top
                card
                    .padding(.top, 38)
                if let contents, !contents.tabs.isEmpty {
                    // Its rows are the stack's own children: modifiers here
                    // would land on each of them.
                    ChatInfoTabs(contents: contents, chat: chat.id, presentation: presentation, tab: $tab)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, R.infoCardInset)
            .padding(.bottom, Metrics.Chats.trayFullComposeBottom)
        }
        .scrollIndicators(.hidden)
        // The page's identifier on its scroller only: set on the whole, it
        // would replace the header buttons' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.info")
        .overlay(alignment: .top) { head }
        .task(id: ChatInfoMemo.key(chat)) {
            // After the zoom's first frames: a long chat's steps and links
            // are read off the main thread, once per change of the chat.
            if contents != nil, ChatInfoMemo.cached(chat) == contents { return }
            let opening = contents == nil
            let started = ContinuousClock.now
            let read = await ChatInfoMemo.contents(of: chat)
            // Read for the first time as Info opens: its rows come in once the
            // zoom has landed, never as a long frame in the middle of it.
            if opening { try? await Task.sleep(until: started + .milliseconds(450)) }
            if !Task.isCancelled, read != contents { contents = read }
        }
        .task(id: copied) { await settle($copied) }
        .task(id: opened) { await settle($opened) }
        .task(id: linkCopied) { await settle($linkCopied) }
        .alert("Rename Chat", isPresented: Binding(get: {
            renaming && presentation.isCurrent(in: app)
        }, set: { if !$0 { renaming = false } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = false }
            Button("Rename") {
                renaming = false
                guard presentation.isCurrent(in: app) else { return }
                // The commit's frames are measured (UITests: chatInfoRename).
                let signpost = MotionSignposts.begin("chatRename", expected: 0.3)
                app.rename(chat.id, to: renameText)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MotionSignposts.end("chatRename", signpost) }
            }
        }
    }

    /// The face, the name, who answers and when, where, and the actions.
    private var top: some View {
        VStack(spacing: 0) {
            ChatAvatar(chat: chat, large: true)
                .frame(width: R.infoFace, height: R.infoFace)
                .padding(.top, R.infoFaceTop)
            Text(chat.title.isEmpty ? "Chat" : chat.title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.top, 14)
                .accessibilityIdentifier("chat.info.title")
            Text(line)
                .font(.system(size: 15))
                .foregroundStyle(Ink.tertiary)
                .lineLimit(1)
                .padding(.top, 3)
                .accessibilityIdentifier("chat.info.line")
            HStack(spacing: 6) {
                Glyph(onMac ? .macbook : .phone, size: 15, color: Ink.primary)
                Text(onMac ? "on your Mac" : "on this \(DeviceWord.name)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Ink.primary)
            }
            .padding(.horizontal, 14)
            .frame(height: R.infoChip)
            .background(ChatInk.fill(0.12), in: Capsule())
            .padding(.top, 14)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat.info.where")
            HStack(alignment: .top, spacing: 0) {
                action(chat.pinned ? "Unpin" : "Pin", glyph: chat.pinned ? .pinSlash : .pin, id: "chat.info.pin") {
                    app.setPinned(chat.id, !chat.pinned)
                }
                action(chat.unread ? "Read" : "Unread", glyph: chat.unread ? .yabChat : .yabChatDot, id: "chat.info.unread") {
                    app.setUnread(chat.id, !chat.unread)
                }
                if app.canOpenChatOnMac {
                    action(opened ? "Opened" : "Open on Mac", glyph: .yabLaptopRight, id: "chat.info.mac") {
                        Haptics.play(.light, reason: Haptics.Reason.openOnMac)
                        opened = true
                    }
                }
                action(chat.archived ? "Unarchive" : "Archive", glyph: chat.archived ? .yabArchiveUp : .yabArchive, id: "chat.info.archive") {
                    if chat.archived { app.unarchive(chat.id) } else { app.archiveOpenChat() }
                }
            }
            .padding(.top, 40)
        }
    }

    /// ‹ back into the chat on the left, ✎ Rename on the right: glass 44s.
    private var head: some View {
        HStack {
            RoundSheetButton(glyph: .chevronLeft, size: R.headerSymbol, id: "chat.info.back", label: "Back to Chat", tray: true) {
                app.closeChatInfo(presentation)
            }
            Spacer()
            Button {
                guard presentation.isCurrent(in: app) else { return }
                renameText = chat.title; renaming = true
            } label: {
                Image("Pencil")
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: R.infoPencil, height: R.infoPencil)
                    .foregroundStyle(Ink.primary)
                    .frame(width: R.headerButton, height: R.headerButton)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.info.rename")
            .accessibilityLabel("Rename Chat")
        }
        .padding(.horizontal, R.trayCloseLead)
        .padding(.top, R.trayFullHeaderTop + R.trayButtonInset)
        .padding(.bottom, 8)
        .background(alignment: .top) { ChatScrollVeil().padding(.bottom, -16) }
    }

    /// The one grouped card: the answer to copy and the page it was asked on.
    @ViewBuilder private var card: some View {
        let page = page
        if chat.lastAnswer != nil || page != nil {
            Group {
                if chat.lastAnswer != nil {
                    InfoRow(title: copied ? "Copied" : "Copy Answer", id: "chat.info.copy", icon: {
                        if copied { Glyph(.checkmark1, size: R.infoRowIcon, color: Ink.primary) } else { Glyph(mac: .yabCopyframeText, size: R.infoRowIcon, color: Ink.primary) }
                    }) {
                        guard presentation.isCurrent(in: app), let answer = app.chats.chat(chat.id)?.lastAnswer else { return }
                        UIPasteboard.general.string = AppModel.copyText(answer)
                        Haptics.play(.soft, reason: Haptics.Reason.copied)
                        copied = true
                    }
                }
                if let page {
                    let open = app.browser.tab(page.id) != nil
                    let go: (() -> Void)? = open ? {
                        guard presentation.isCurrent(in: app), app.browser.tab(page.id) == page else { return }
                        app.browser.select(page.id); app.closeSheet()
                    } : nil
                    InfoRow(title: page.title, value: page.addressHost, chevron: open, id: "chat.info.page", icon: {
                        Favicon(icon: page.icon, host: page.addressHost, size: R.infoRowIcon, url: page.navigationURL, isPrivate: page.isPrivate, mark: page.customMark)
                    }, run: go)
                    InfoRow(title: linkCopied ? "Link Copied" : "Copy Page Link", id: "chat.info.pageCopy", icon: {
                        if linkCopied { Glyph(.checkmark1, size: R.infoRowIcon, color: Ink.primary) } else { Glyph(mac: .link, size: R.infoRowIcon, color: Ink.primary) }
                    }) {
                        guard presentation.isCurrent(in: app) else { return }
                        UIPasteboard.general.string = app.link(of: page)?.absoluteString
                        Haptics.play(.soft, reason: Haptics.Reason.copied)
                        linkCopied = true
                    }
                }
            }
            .modifier(InfoCard())
        }
    }

    /// A round white button 72 with its glyph, its word under it in ink.
    private func action(_ text: String, glyph: MacGlyph, id: String, run: @escaping () -> Void) -> some View {
        Button {
            guard presentation.isCurrent(in: app) else { return }
            run()
        } label: {
            VStack(spacing: 10) {
                Glyph(mac: glyph, size: R.infoRowIcon, color: Ink.primary)
                    .frame(width: R.infoAction, height: R.infoAction)
                    .background(ChatDetails.tile, in: Circle())
                Text(text)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            // Four fit a small iPhone: each column gives way down to the circle.
            .frame(minWidth: R.infoAction, maxWidth: R.infoActionColumn)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    private func settle(_ flag: Binding<Bool>) async {
        guard flag.wrappedValue else { return }
        try? await Task.sleep(for: .seconds(1.6))
        if !Task.isCancelled { flag.wrappedValue = false }
    }

    /// Its project, who answers and when: "Lisbon Trip · Claude · today at 20:36".
    private var line: String {
        [app.project(of: chat)?.name, model, when].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    private var model: String {
        if !onMac { return "Apple Intelligence" }
        if app.isFixture { return "Claude Opus" }
        return chat.macAgentName ?? "Your Mac"
    }

    /// The row's time said as a day: "today at 20:36", "Aug 14".
    private var when: String? {
        guard !chat.time.isEmpty else { return nil }
        let clock = chat.time.contains(":")
        switch chat.day {
        case .today: return clock ? "today at " + chat.time : chat.time
        case .yesterday: return clock ? "yesterday at " + chat.time : chat.time
        case .earlier: return chat.time
        }
    }

    /// Answered on the Mac (Claude), or on this iPhone.
    private var onMac: Bool {
        if chat.task != nil { return true }
        if app.isFixture { return chat.messages.contains { $0.by == .claude || $0.role == .pick } }
        return chat.by != .iphone
    }

    private var page: Tab? {
        guard let id = app.chatSheet.pages[chat.id] else { return nil }
        return app.browser.tab(id) ?? app.chatSheet.pageSources[chat.id]
    }

    /// Info's page and its card: #f2f2f4 under white, as X's profile.
    static let page = AppearanceColors.color(0xF2F2F4, 0x000000)
    static let tile = AppearanceColors.color(0xFFFFFF, 0x1C1C1E)
}

/// Named states open Info on a tab of their choice (chat.info.long.3, .4).
@MainActor
enum ChatInfoScroll {
    static var tab: ChatInfoContents.Tab?
}

// MARK: - what the chat touched

/// Telegram's shared-media tabs under the card: a segmented control of the
/// tabs that have something, the chosen one's rows in a card. Rows are built
/// as they scroll in (the page is a LazyVStack), so a chat of hundreds of
/// links costs only what is on screen.
private struct ChatInfoTabs: View {
    @Environment(AppModel.self) private var app
    let contents: ChatInfoContents
    let chat: Chat.ID
    let presentation: ChatInfoPresentation
    @Binding var tab: ChatInfoContents.Tab?
    private typealias R = Metrics.Chats

    var body: some View {
        let tabs = contents.tabs
        let current = tab.flatMap { tabs.contains($0) ? $0 : nil } ?? tabs[0]
        Picker("Shared", selection: Binding(get: { current }, set: { tab = $0 })) {
            ForEach(tabs) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("chat.info.tabs")
        .padding(.top, 38)
        .padding(.bottom, 12)
        switch current {
        case .sites:
            rows(contents.sites) { site in
                LinkRow(title: site.host, detail: siteDetail(site), host: site.host, id: "chat.info.site") { open(site.url) }
            }
            if let work = contents.workLine {
                Text("\(agent) worked \(work) in this chat.")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, R.infoRowInset)
                    .padding(.top, 8)
                    .accessibilityIdentifier("chat.info.work")
            }
        case .links:
            rows(contents.links) { link in
                LinkRow(title: link.title, detail: ChatInfoContents.shortAddress(link.url), host: link.host, id: "chat.info.link") { open(link.url) }
            }
        case .media:
            MediaGrid(items: contents.media)
        case .files:
            rows(contents.files) { item in FileRow(file: item.file) }
        }
    }

    /// Each row on its own piece of the card, so the stack stays lazy.
    @ViewBuilder
    private func rows<Item: Identifiable, Row: View>(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            row(item).modifier(CardPiece(first: index == 0, last: index == items.count - 1))
        }
    }

    private var agent: String {
        app.chats.chat(chat)?.macAgentName ?? (app.isFixture ? "Claude" : "The agent")
    }

    private func siteDetail(_ site: ChatInfoContents.Site) -> String {
        let visits = site.visits == 1 ? "1 step" : "\(site.visits) steps"
        guard let last = site.last else { return visits }
        return visits + " \u{00B7} " + Self.when(last)
    }

    static func when(_ date: Date) -> String {
        (Calendar.current.isDateInToday(date) ? today : earlier).string(from: date)
    }

    private static let today = formatter("'today at' HH:mm")
    private static let earlier = formatter("MMM d")
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter
    }

    /// A new tab in front, as a link in the chat opens one.
    private func open(_ url: URL) {
        guard presentation.isCurrent(in: app) else { return }
        _ = ChatMarkdown.openInNewTab(url, from: chat, app: app)
    }
}

/// A site or a link: its mark, its name, the address or what was done there.
private struct LinkRow: View {
    let title: String
    let detail: String
    let host: String
    let id: String
    let run: () -> Void
    private typealias R = Metrics.Chats

    var body: some View {
        Button(action: run) {
            HStack(spacing: 14) {
                // A site with no picture yet reads as its initial, as a tab's does.
                Favicon(icon: host, host: host, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 14))
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Glyph(.chevronRight, size: 14, color: Ink.faint)
            }
            .padding(.horizontal, R.infoRowInset)
            .padding(.vertical, 10)
            .frame(minHeight: R.infoRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(InfoRowStyle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
        .accessibilityHint("Opens in a new tab")
    }
}

/// A file sent with words: its mark, its name, its kind and size.
private struct FileRow: View {
    let file: Message.File
    private typealias R = Metrics.Chats

    var body: some View {
        HStack(spacing: 14) {
            Glyph(.pageText, size: 20, color: Ink.primary)
                .frame(width: 32, height: 32)
                .background(ChatInk.fill(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 17))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Self.kind(file) + " \u{00B7} " + ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, R.infoRowInset)
        .padding(.vertical, 10)
        .frame(minHeight: R.infoRow)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.info.file")
    }

    static func kind(_ file: Message.File) -> String {
        let ending = (file.name as NSString).pathExtension.uppercased()
        if !ending.isEmpty { return ending }
        return file.type.split(separator: "/").last.map { $0.uppercased() } ?? "File"
    }
}

/// Photos three across, square, in one rounded card.
private struct MediaGrid: View {
    let items: [ChatInfoContents.Item]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(items) { item in
                MediaThumb(file: item.file)
                    .aspectRatio(1, contentMode: .fill)
                    .accessibilityElement()
                    .accessibilityLabel(item.file.name)
                    .accessibilityIdentifier("chat.info.photo")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.Chats.infoCardRadius, style: .continuous))
    }
}

/// A photo's kept picture, read off the main thread.
private struct MediaThumb: View {
    let file: Message.File
    @State private var image: UIImage?

    init(file: Message.File) {
        self.file = file
        _image = State(initialValue: ChatThumbs.inMemory(file.digest))
    }

    var body: some View {
        Color.clear
            .background(ChatInk.fill(0.08))
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: file.digest) {
                if image == nil { image = await ChatThumbs.load(file.digest) }
            }
    }
}

/// A piece of Info's card: white, the card's corners on its first and last,
/// a hairline under all but the last.
private struct CardPiece: ViewModifier {
    let first: Bool
    let last: Bool

    func body(content: Content) -> some View {
        let r = Metrics.Chats.infoCardRadius
        let shape = UnevenRoundedRectangle(topLeadingRadius: first ? r : 0, bottomLeadingRadius: last ? r : 0,
                                           bottomTrailingRadius: last ? r : 0, topTrailingRadius: first ? r : 0, style: .continuous)
        content
            .background(ChatDetails.tile)
            .overlay(alignment: .bottom) {
                if !last {
                    Rectangle().fill(ChatInk.gray(0.18)).frame(height: 0.5)
                        .padding(.leading, Metrics.Chats.infoRowInset + 32 + 14)
                }
            }
            .clipShape(shape)
    }
}

/// A row of Info's card: 60 tall, its glyph 24 on the left, the title, a gray
/// value, a chevron when it goes somewhere; a hairline under all but the last.
struct InfoRow<Icon: View>: View {
    let title: String
    var value: String? = nil
    var chevron = false
    let id: String
    @ViewBuilder var icon: () -> Icon
    var run: (() -> Void)? = nil
    private typealias R = Metrics.Chats

    var body: some View {
        let row = HStack(spacing: 16) {
            icon().frame(width: R.infoRowIcon, height: R.infoRowIcon)
            Text(title)
                .font(.system(size: 17))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let value {
                // The value is said whole; a long title gives way.
                Text(value)
                    .font(.system(size: 17))
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if chevron { Glyph(.chevronRight, size: 14, color: Ink.faint) }
        }
        .padding(.horizontal, R.infoRowInset)
        .frame(minHeight: R.infoRow)
        .contentShape(Rectangle())
        Group {
            if let run {
                Button(action: run) { row }.buttonStyle(InfoRowStyle())
            } else {
                row.accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier(id)
    }
}

struct InfoRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(ChatInk.fill(configuration.isPressed ? 0.12 : 0))
    }
}

/// Info's grouped card: white, 24 round, a hairline between its rows.
struct InfoCard: ViewModifier {
    func body(content: Content) -> some View {
        Group(subviews: content) { rows in
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    row
                    if index < rows.count - 1 {
                        Rectangle().fill(ChatInk.gray(0.18)).frame(height: 0.5)
                            .padding(.leading, Metrics.Chats.infoRowInset + Metrics.Chats.infoRowIcon + 16)
                            .padding(.trailing, Metrics.Chats.infoRowInset)
                    }
                }
            }
        }
        .background(ChatDetails.tile, in: RoundedRectangle(cornerRadius: Metrics.Chats.infoCardRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.Chats.infoCardRadius, style: .continuous))
    }
}
