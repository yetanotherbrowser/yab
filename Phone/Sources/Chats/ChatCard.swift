import PhotosUI
import SwiftUI
import SyncKit

/// The card's words, laid out in the sheet's frame as it is now: the grabber, a
/// head that is an answer's (who answered, Hide) or a chat's (‹ back to the
/// Chats page, the face over its name, ⋯), the turns, Copy and Open in Chat under
/// an answer, the page's pill and the follow-up field.
struct ChatCardContent: View {
    @Environment(AppModel.self) private var app
    let chat: Chat
    let geometry: SheetGeometry
    @Namespace private var infoTransition

    @State private var footHeight: CGFloat = Metrics.Chats.trayComposeHeight + Metrics.Chats.trayFullComposeBottom
    private typealias C = Metrics.Chat

    var body: some View {
        let sheet = app.chatSheet
        let t = geometry.pose.t
        let gutter = geometry.gutter
        let fresh = sheet.fresh.contains(chat.id)
        let head = geometry.tray ? Metrics.Chats.conversationHeader + Metrics.Chats.trayFullHeaderTop * CGFloat(t) : geometry.headHeight + Metrics.Column.grabTop + Metrics.Column.grabHeight
        ZStack(alignment: .top) {
            ChatBody(chat: chat, full: geometry.tray || t > 0.5, gutter: gutter, fresh: fresh, tray: geometry.tray,
                     morphing: geometry.pose.o > 0.001 || geometry.pose.p > 0.001,
                     topInset: head, bottomInset: footHeight)
                // Info is a modal cover over it, which VoiceOver reads alone:
                // hiding a long transcript's every element as it opens cost
                // the zoom its first frames (chatInfoLong).
                .allowsHitTesting(!sheet.info)
            if geometry.tray, !geometry.cover {
                // A finger from the left edge takes the chat back into its card
                // on New Tab's Chats page, as ‹ does. In its cover the
                // system's own edge swipe does.
                Color.clear
                    .frame(width: Metrics.Chats.edgePanWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(ChatEdgePan(app: app))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 0) {
                if !geometry.tray {
                    Capsule().fill(ChatInk.gray(0.3))
                        .frame(width: Metrics.Column.grabWidth, height: Metrics.Column.grabHeight)
                        .padding(.top, Metrics.Column.grabTop)
                }
                ZStack {
                    if geometry.tray {
                        TrayChatHead(chat: chat, fresh: fresh, width: geometry.current.rect.width, infoTransition: infoTransition)
                            .padding(.top, Metrics.Chats.trayFullHeaderTop * CGFloat(t))
                    } else {
                        AnswerHead(chat: chat, gutter: gutter)
                            .opacity(geometry.answerHeadOpacity).allowsHitTesting(t < 0.5)
                    }
                }
                .frame(height: geometry.tray ? Metrics.Chats.conversationHeader + Metrics.Chats.trayFullHeaderTop * CGFloat(t) : geometry.headHeight)
            }
            .background(alignment: .top) { ChatScrollVeil(solid: Metrics.Chats.headSolid).frame(height: head).opacity(geometry.tray ? 1 : 0) }
            .contentShape(Rectangle())
            .gesture(SheetDrag(app: app, presentationPose: geometry.pose))
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    if !geometry.tray, t < 0.5 {
                        AnswerActions(gutter: gutter)
                            .opacity(geometry.answerHeadOpacity)
                            .contentShape(Rectangle()).gesture(SheetDrag(app: app, presentationPose: geometry.pose))
                    }
                    ChatFoot(chat: chat, full: t > 0.5, gutter: gutter, fresh: fresh, tray: geometry.tray, trayProgress: t)
                }
                .background(alignment: .bottom) {
                    ChatScrollVeil(from: .bottom, to: .top).padding(.top, -Metrics.Chats.scrollFootFade)
                        .opacity(geometry.tray ? 1 : 0)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footHeight = $0 }
                .opacity(sheet.info ? 0 : 1)
                .allowsHitTesting(!sheet.info)
                .accessibilityHidden(sheet.info)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(.named(ChatSpace.card))
        .fullScreenCover(item: ChatInfoPresentation.binding(app: app, chat: chat.id)) { presentation in
            ChatInfoPage(presentation: presentation)
                .environment(app)
                .navigationTransition(.zoom(sourceID: presentation.chat, in: infoTransition))
        }
    }
}

/// Who answered, in words, and Hide.
private struct AnswerHead: View {
    @Environment(AppModel.self) private var app
    let chat: Chat
    let gutter: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            if chat.by == .iphone {
                Glyph(.sparkle, size: Metrics.Chat.whoIcon)
            } else {
                AgentFace(size: Metrics.Chat.whoIcon)
            }
            Text(ChatWords.providerName(chat, app: app))
                .font(.system(size: Metrics.Chat.whoFont, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .fixedSize()
            Text(chat.by == .iphone ? "on this \(DeviceWord.name)" : "on your Mac")
                .font(.system(size: Metrics.Chat.wherePill, weight: .medium))
                .foregroundStyle(ChatInk.gray(0.62))
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .lineLimit(1)
                // On a narrow iPhone the pill's words get a little smaller
                // rather than cut: where it was answered is always said.
                .minimumScaleFactor(0.8)
                .background(ChatInk.fill(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .layoutPriority(-1)
                .accessibilityIdentifier("chat.where")
            Spacer(minLength: 0)
            Button { app.park() } label: {
                Text("Hide")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .fixedSize()
                    .padding(.horizontal, 14)
                    .frame(height: Metrics.capsuleButton)
                    .background(ChatInk.fill(0.12), in: Capsule(style: .continuous))
                    .frame(minHeight: Metrics.touch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.hide")
        }
        .padding(.leading, gutter)
        .padding(.trailing, gutter)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.answerHead")
    }
}

/// A chat's head, as X's: ‹ with the unread count on the left (back to the
/// Chats page), the agent's face in the middle drawn edge to edge with the chat's
/// name in one line on a glass capsule tucked under it, ⋯ on the right. Who
/// answers and where is said in Chat Info, which grows out of the face.
private struct TrayChatHead: View {
    @Environment(AppModel.self) private var app
    let chat: Chat
    let fresh: Bool
    let width: CGFloat
    let infoTransition: Namespace.ID
    @State private var heldTitle = false
    private typealias R = Metrics.Chats

    var body: some View {
        let line = ChatWords.line(chat, app: app, fresh: fresh)
        ZStack(alignment: .top) {
            HStack(spacing: R.headerGap) {
                ChatBackButton(count: unreadElsewhere) { app.openHistory() }
                Spacer(minLength: 0)
                ChatNativeMenu(chat: chat.id).frame(width: Metrics.touch, height: Metrics.touch)
            }
            // Messages' 16, on the line of the bubbles' outer edge.
            .padding(.horizontal, R.trayEdge)
            .padding(.top, R.trayButtonInset)
            // The face drawn over the capsule, which tucks under it as X's does.
            ZStack(alignment: .top) {
                Button {
                    if heldTitle { heldTitle = false; return }
                    if !fresh { app.openChatInfo() }
                } label: {
                    Text(fresh ? "New Chat" : chat.title)
                        .font(.system(size: R.nameFont))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: R.nameCapsule)
                        .frame(maxWidth: min(R.nameCapsuleMax, max(80, width - 2 * (R.trayEdge + 2 * R.headerButton + R.headerGap))))
                        .fixedSize(horizontal: true, vertical: false)
                        .glassEffect(.regular, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.title")
                .accessibilityLabel(fresh ? "New Chat" : chat.title)
                // Who answers, said to VoiceOver with the name.
                .accessibilityValue(line)
                .simultaneousGesture(LongPressGesture(minimumDuration: Metrics.Hold.duration).onEnded { _ in heldTitle = true; app.toggleMoreMenu() })
                .onChange(of: app.chatSheet.moreMenu) { _, shown in if !shown { heldTitle = false } }
                .accessibilityAction(named: "More") { app.toggleMoreMenu() }
                .padding(.top, R.face - R.nameTuck)
                ChatAvatar(chat: chat)
                    .frame(width: R.face, height: R.face)
                    .matchedTransitionSource(id: chat.id, in: infoTransition)
                    // In a project: its circle on the face, as a group's in Messages.
                    .overlay(alignment: .topTrailing) {
                        if let project = app.project(of: chat) {
                            ProjectCircle(project: project, size: 22)
                                .overlay(Circle().stroke(ChatInk.list, lineWidth: 2))
                                .offset(x: 9, y: -5)
                                .allowsHitTesting(false)
                                .accessibilityElement()
                                .accessibilityIdentifier("chat.projectBadge")
                                .accessibilityLabel("In \(project.name)")
                        }
                    }
            }
            .padding(.top, R.faceTop)
        }
        .frame(height: R.conversationHeader, alignment: .top)
    }

    /// New answers in the other chats, as X counts unread conversations.
    private var unreadElsewhere: Int {
        let sheet = app.chatSheet
        return app.chats.visibleChats.lazy.filter { $0.unread && $0.id != chat.id && sheet.isListed($0) }.count
    }
}

/// ‹ back to the Chats page: a glass capsule 44 tall, the unread count beside the
/// chevron in an ink capsule; a 44 circle when nothing is unread.
private struct ChatBackButton: View {
    let count: Int
    let action: () -> Void
    private typealias R = Metrics.Chats

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ChatGlyph(.chevronLeft, size: R.headerSymbol)
                if count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(.system(size: R.backCount, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Ink.onNewAnswer)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 22, minHeight: 20)
                        .background(Ink.newAnswer, in: Capsule())
                }
            }
            .padding(.leading, count > 0 ? 10 : 0)
            .padding(.trailing, count > 0 ? 12 : 0)
            .frame(minWidth: R.headerButton, minHeight: R.headerButton)
            .glassEffect(.regular.interactive(), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.history")
        .accessibilityLabel("Back to Chats")
        .accessibilityValue(count > 0 ? "\(count) unread" : "")
    }
}

/// A finger from the left edge of a chat in the sheet: back to its card on
/// New Tab's Chats page, as ‹ (ChatFlow.openHistory). In its cover the
/// system's own edge swipe takes it, with the finger.
private struct ChatEdgePan: UIGestureRecognizerRepresentable {
    let app: AppModel

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        guard recognizer.state == .began, app.chatSheet.shown, app.chatSheet.mode == .chat, app.chatSheet.page == nil,
              !app.chatSheet.info, !app.chatSheet.moreMenu, app.chatSheet.renaming == nil, app.chatSheet.deleting == nil else { return }
        // Out of the gesture's own UIKit callback.
        DispatchQueue.main.async { [app] in app.openHistory() }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: nil)
            return v.x > 0 && abs(v.x) > abs(v.y)
        }
    }
}

/// A round 44 button of the sheet's heads: white .7, a hairline, a soft shadow.
struct RoundSheetButton: View {
    let glyph: GlyphName
    var size: CGFloat = 22
    let id: String
    let label: String
    var tray = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChatGlyph(glyph, size: glyph == .crossSmall ? Metrics.Chats.headerSymbol : size)
                .frame(width: Metrics.Chats.headerButton, height: Metrics.Chats.headerButton)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
    }
}

/// The turns, scrolled to the newest; a new chat's ideas stand over the field.
private struct ChatBody: View {
    @Environment(AppModel.self) private var app
    @Environment(\.chatScrollAccess) private var scrollAccess
    let chat: Chat
    let full: Bool
    let gutter: CGFloat
    let fresh: Bool
    var tray = false
    let morphing: Bool
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    @State private var followNewest = true

    /// Content and viewport changes are layout, not a reader moving up.
    private struct ScrollPlace: Equatable {
        var gap: CGFloat
        var content: CGSize
        var viewport: CGSize
    }

    var body: some View {
        let sheet = app.chatSheet
        if fresh {
            // Where the field below starts its words (ChatFoot).
            // With + in the field its words start after it: 6 + 32 + 6 + 2.
            NewChatIdeas(gutter: gutter, lead: (tray ? Metrics.Chats.composeInset(keyboard: app.chatSheet.keyboard > 0) : gutter)
                         + (app.canAttach(chat.id) ? Metrics.Chats.fieldButton + 14 : Metrics.Chat.fieldTextInset))
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        } else {
            ScrollView {
                Group {
                    if let id = chat.task, let def = app.tasks.definition(id), let run = app.tasks.run(id) {
                        TaskTurns(run: run, def: def, failure: app.taskDesk.failures[id]?.long ?? run.failure,
                                  waiting: app.taskDesk.yeses[id]?.waiting, codeSender: app.taskDesk.codes[id]?.sender,
                                  asleepSince: run.asleepSince ?? app.taskDesk.macAsleepSince) {
                            app.taskDesk.retry(id)
                        }
                    } else {
                        TurnsView(chat: chat, full: full, arrival: sheet.arrival,
                                  flyingInto: sheet.flight.map(\.bubble), task: taskTurns) { index, frame in
                            sheet.bubbleFrames[index] = frame
                        }
                        .equatable()
                    }
                }
                .padding(.horizontal, gutter)
                .padding(.top, Metrics.Chat.turnsTop + topInset)
                .padding(.bottom, Metrics.Chat.turnsBottom + bottomInset)
                .background {
                    ChatScrollBinding(owner: chat.id)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .scrollIndicators(.hidden)
            // A chat opens on its newest turns; an answer on its question.
            .defaultScrollAnchor(sheet.mode == .answer ? .top : .bottom, for: .initialOffset)
            // Like the Mac transcript, growth follows the newest only while
            // the reader is at the end. Reading above stays at the same offset.
            .defaultScrollAnchor(morphing || (sheet.mode == .chat && !(scrollAccess.atEnd(chat.id) ?? followNewest)) ? .top : .bottom, for: .sizeChanges)
            .onScrollGeometryChange(for: ScrollPlace.self) { geometry in
                ScrollPlace(gap: max(0, geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY),
                            content: geometry.contentSize, viewport: geometry.containerSize)
            } action: { old, now in
                if now.gap <= 8 {
                    followNewest = true
                } else if now.gap > old.gap + 0.5,
                          abs(now.content.height - old.content.height) < 0.5,
                          abs(now.content.width - old.content.width) < 0.5,
                          abs(now.viewport.height - old.viewport.height) < 0.5,
                          abs(now.viewport.width - old.viewport.width) < 0.5 {
                    followNewest = false
                }
            }
            .onChange(of: chat.id, initial: true) { _, _ in followNewest = true }
            // Each chat its own scroller, so each opens at its own place.
            .id(chat.id)
            .scrollEdgeEffectHidden(topInset > 0, for: .all)
            .accessibilityIdentifier("chat.body")
        }
    }

    private var taskTurns: TurnsView.TaskTurns? {
        guard let id = chat.task, let def = app.tasks.definition(id) else { return nil }
        let run = app.tasks.run(id)
        return .init(definition: def, run: run, macAsleepSince: run?.status == .waits ? app.chatSheet.macAsleepSince() : nil)
    }
}

/// Copy, Open in Chat: under an answer, before it is a chat.
private struct AnswerActions: View {
    @Environment(AppModel.self) private var app
    let gutter: CGFloat

    var body: some View {
        HStack(spacing: Metrics.Chat.actionGap) {
            action(.squareBehindSquare1, "Copy", id: "chat.copy") { app.copyAnswer() }
            action(.expand45, "Open in Chat", id: "chat.open") { app.expand() }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, gutter)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private func action(_ glyph: GlyphName, _ words: String, id: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 5) {
                Glyph(glyph, size: Metrics.Chat.actionIcon, color: ChatInk.gray(0.62))
                Text(words)
                    .font(.system(size: Metrics.Chat.actionFont, weight: .medium))
                    .foregroundStyle(ChatInk.gray(0.62))
            }
            .frame(height: 15)
            .contentShape(Rectangle().inset(by: -12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// The page's pill and the follow-up field: the microphone becomes an ink
/// send button once there are words.
private struct ChatFoot: View {
    @Environment(AppModel.self) private var app
    let chat: Chat
    let full: Bool
    let gutter: CGFloat
    let fresh: Bool
    var tray = false
    var trayProgress: Double = 1
    @FocusState private var focus: Bool
    @State private var picked: [PhotosPickerItem] = []
    /// The field's width, to know when words need a second row.
    @State private var fieldWidth: CGFloat = 0

    var body: some View {
        @Bindable var sheet = app.chatSheet
        let hasWords = !sheet.draft.trimmingCharacters(in: .whitespaces).isEmpty
        let attachable = app.canAttach(chat.id)
        let files = attachable ? sheet.attached[chat.id] ?? [] : []
        let canSend = hasWords || !files.isEmpty
        VStack(alignment: .leading, spacing: 8) {
            if !fresh, !chat.choices.isEmpty {
                ChatChoices(choices: chat.choices) { app.send($0) }
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            if !fresh, let tabID = sheet.pages[chat.id], let tab = app.browser.tab(tabID) {
                HStack(spacing: 6) {
                    Favicon(icon: tab.icon, host: tab.addressHost, size: 14, url: tab.navigationURL, isPrivate: tab.isPrivate, mark: tab.customMark)
                    Text(tab.short)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(height: Metrics.Chat.pagePill)
                .background(ChatInk.fill(0.1), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .padding(.horizontal, 4)
                .accessibilityIdentifier("chat.pagePill")
            }
            // A new chat in a project wears the project: another can be picked.
            if fresh, let project = app.project(of: chat) {
                ProjectPill(chat: chat, project: project)
            }
            // A new chat whose Mac is down says so before anything is sent.
            if fresh, let line = app.newChatMacLine {
                Text(line)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ChatInk.gray(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("chat.macLine")
            }
            field(sheet: sheet, attachable: attachable, files: files, canSend: canSend)
        }
        .padding(.horizontal, tray ? Metrics.Chats.composeInset(keyboard: sheet.keyboard > 0) : gutter)
        // Over the keyboard 16, as Messages; without it, clear of the home indicator.
        .padding(.bottom, tray ? (sheet.keyboard > 0 ? Metrics.Chats.trayComposeOverKeyboard
                                  : SheetGeometry.lerp(Metrics.Chats.trayComposeBottom, Metrics.Chats.trayFullComposeBottom, trayProgress))
                              : (full ? Metrics.Chat.footFull : Metrics.Chat.footAnswer))
        .onChange(of: focus) { _, on in
            if on, app.chatSheet.mode == .answer { app.expand() }
            if app.chatSheet.focused != on { app.chatSheet.focused = on }
        }
        .onChange(of: sheet.focused, initial: true) { _, on in
            if focus != on { focus = on }
        }
        .fileImporter(isPresented: $sheet.attachFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { app.attachFiles(urls, to: chat.id) }
        }
        // Photos is the system's own picker: it needs no photo library access,
        // which a Default Web Browser may not ask for.
        .photosPicker(isPresented: $sheet.attachLibrary, selection: $picked,
                      maxSelectionCount: max(1, SyncSendFile.mostCount - (sheet.attached[chat.id]?.count ?? 0)), matching: .images)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            app.attachPicked(items, to: chat.id)
            picked = []
        }
        .fullScreenCover(isPresented: $sheet.attachCamera) {
            CameraPicker { image in
                app.chatSheet.attachCamera = false
                if let image { app.attachCamera(image, to: chat.id) }
            }
            .ignoresSafeArea()
        }
    }

    /// The field, as the Mac's chat field: one line, + · words · send, until
    /// photos or files go with the words or the words need the room; then
    /// two rows, the words over + · chips · send. It grows up, the turns
    /// over it moving up with it.
    @ViewBuilder
    private func field(sheet: ChatSheet, attachable: Bool, files: [ChatAttachment], canSend: Bool) -> some View {
        @Bindable var sheet = sheet
        let fontSize = tray ? Metrics.Chats.trayComposeFont : 16
        let room = fieldWidth - 16 - (attachable ? Metrics.Chats.fieldButton + 6 : 8) - Metrics.Chats.fieldButton - 6
        let long = !files.isEmpty || sheet.draft.contains("\n")
            || (fieldWidth > 0 && Markup.width(sheet.draft, size: fontSize) > room)
        let minHeight = tray ? Metrics.Chats.fieldMin : Metrics.Chat.field
        let radius = tray ? Metrics.Chats.fieldMin / 2 : Metrics.Chat.fieldRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            // The words keep their place whichever shape the field has, so
            // the cursor stays in them when it opens up.
            HStack(alignment: .center, spacing: 6) {
                if attachable, !long { FieldPlus() }
                TextField("", text: $sheet.draft, prompt: Text(placeholder).foregroundStyle(ChatInk.gray(0.5)), axis: .vertical)
                    .font(.system(size: fontSize))
                    .tracking(tray ? 0 : -0.16)
                    .foregroundStyle(Ink.black)
                    .lineLimit(1...6)
                    .focused($focus)
                    .submitLabel(.return)
                    .padding(.leading, attachable && !long ? 2 : (long ? 4 : Metrics.Chat.fieldTextInset - 6))
                    .frame(minHeight: Metrics.Chats.fieldButton)
                    .background { ChatFieldWindowFrame(owner: chat.id) }
                    .accessibilityIdentifier("chat.field")
                if !long, canSend { sendButton }
            }
            if long {
                HStack(spacing: 6) {
                    if attachable { FieldPlus() }
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(files) { item in
                                FieldChip(item: item) { app.unattach(item, from: chat.id) }
                                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .scrollBounceBehavior(.basedOnSize)
                    // Chips past the edge fade out, as the Mac's row does.
                    .mask {
                        HStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 18)
                        }
                    }
                    .accessibilityIdentifier("chat.attachments")
                    Spacer(minLength: 0)
                    if canSend { sendButton }
                }
            }
        }
        .padding(.leading, long ? 8 : 6)
        .padding(.trailing, 6)
        .padding(.vertical, long ? 8 : 6)
        .frame(minHeight: minHeight)
        .background {
            if !tray, full {
                shape.fill(Ink.card.opacity(0.9))
                    .overlay(shape.stroke(Ink.outline.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: Ink.shadow.opacity(0.18), radius: 7, y: 4)
            } else if !tray {
                shape.fill(ChatInk.fill(0.1))
            }
        }
        .chatGlass(in: shape, enabled: tray)
        .contentShape(Rectangle())
        .onTapGesture { focus = true }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fieldWidth = $0 }
        .animation(Motion.disabled ? nil : .snappy(duration: 0.2), value: long)
        .animation(Motion.disabled ? nil : .snappy(duration: 0.2), value: canSend)
        .animation(Motion.disabled ? nil : .snappy(duration: 0.2), value: files.count)
    }

    /// Send, in the system's accent, once there are words or files, as in
    /// Messages; with none, nothing: there is no dictation here.
    private var sendButton: some View {
        let sheet = app.chatSheet
        return Button { send() } label: {
            ZStack {
                Circle().fill(Color.accentColor)
                Glyph(.arrowUp, size: 16, color: .white)
            }
            .frame(width: Metrics.Chats.fieldButton, height: Metrics.Chats.fieldButton)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!app.isFixture && (sheet.chatID.map {
            sheet.answeringHere.contains($0) || sheet.sendingToMac.contains($0) || app.sync.isStartingChat($0)
        } ?? false))
        .transition(.scale(scale: 0.6).combined(with: .opacity))
        .accessibilityIdentifier("chat.send")
        .accessibilityLabel("Send")
    }

    private var placeholder: String {
        if fresh { return "Ask anything" }
        if !chat.choices.isEmpty { return "Or answer in your own words\u{2026}" }
        if let id = chat.task, let run = app.tasks.run(id), run.isLive { return "Tell it more while it works\u{2026}" }
        return "Ask a follow-up\u{2026}"
    }

    private func send() {
        let sheet = app.chatSheet
        app.send(sheet.draft, from: sheet.fieldFrame)
    }
}

/// What the agent on the Mac asks you to pick from, over the field, as the
/// Mac's column has it (ChatAsk): each by its number, its question the last
/// message over it. A tap answers with it, as words typed below do; it goes
/// as your message, and the card goes once the Mac has it.
private struct ChatChoices: View {
    let choices: [String]
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(choices.prefix(4).enumerated()), id: \.offset) { index, choice in
                Button { pick(choice) } label: {
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ChatInk.gray(0.6))
                            .frame(width: 22, height: 22)
                            .background(ChatInk.fill(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text(choice)
                            .font(.system(size: 16))
                            .foregroundStyle(Ink.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: Metrics.touch)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(IdeaStyle())
                .accessibilityIdentifier("chat.choice")
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            shape.fill(Ink.card.opacity(0.92))
                .overlay(shape.stroke(Ink.outline.opacity(0.08), lineWidth: 0.5))
                .shadow(color: Ink.shadow.opacity(0.14), radius: 8, y: 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.choices")
    }
}

/// Over a new chat's field, like ⌘J on the Mac: three ideas for the page in
/// front, each with the site's mark, rising in one after another. With
/// nothing smart to offer (no page, a private tab, ideas not written yet)
/// nothing stands there, as on the Mac: the field's placeholder says it.
private struct NewChatIdeas: View {
    @Environment(AppModel.self) private var app
    let gutter: CGFloat
    /// The field's words' start: each site mark stands on it.
    let lead: CGFloat

    var body: some View {
        let sheet = app.chatSheet
        let tab = app.browser.tab
        let ideas = tab.flatMap { AppModel.hasIdeas($0) ? sheet.ideas[$0.id] : nil }
        VStack(alignment: .leading, spacing: 2) {
            if let tab, AppModel.hasIdeas(tab) {
                ForEach(Array((ideas ?? []).prefix(3).enumerated()), id: \.offset) { index, idea in
                    Button { app.send(idea) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Favicon(icon: tab.icon, host: tab.addressHost, size: 16, url: tab.navigationURL, isPrivate: tab.isPrivate, mark: tab.customMark).padding(.top, 2)
                            Text(idea)
                                .font(.system(size: 16))
                                .foregroundStyle(Ink.primary)
                                .multilineTextAlignment(.leading)
                                .cssLineHeight(1.3, size: 16)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 9)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 44)
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(IdeaStyle())
                    .padding(.horizontal, -8)
                    // Each rises in its own 260 ms, 40 ms after the one before.
                    .modifier(RiseIn(motion: Motion.ideaRise(at: index)))
                    .accessibilityIdentifier("chat.idea")
                }
            }
        }
        .padding(.bottom, 6)
        .padding(.leading, lead)
        .padding(.trailing, gutter)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

/// Coming in under its own motion: it fades in and rises 6 points as it
/// appears (at once in named states).
struct RiseIn: ViewModifier {
    let motion: Motion
    @State private var shown = false

    func body(content: Content) -> some View {
        let hidden = !shown && !Motion.disabled
        content
            .opacity(hidden ? 0 : 1)
            .offset(y: hidden ? 6 : 0)
            .onAppear {
                guard !shown, !Motion.disabled else { return }
                motion.run { shown = true }
            }
    }
}

private struct IdeaStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(ChatInk.fill(configuration.isPressed ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The words a chat speaks about itself: its line under the name, its row's
/// second line on the Chats page.
enum ChatWords {
    /// Real names come from accepted metadata, not the current preference.
    @MainActor
    static func providerName(_ chat: Chat, app: AppModel, by: Chat.Answerer? = nil) -> String {
        if (by ?? chat.by) == .iphone { return "Apple Intelligence" }
        return app.isFixture ? "Claude" : chat.macAgentName ?? "Your Mac"
    }

    @MainActor
    static func line(_ chat: Chat, app: AppModel, fresh: Bool = false) -> String {
        if let id = chat.task {
            switch app.tasks.run(id)?.status ?? .done {
            case .running, .sending: return "Working \u{00B7} on your Mac"
            case .code, .yes: return "Waiting for you"
            default:
                if app.isFixture { return "On your Mac \u{00B7} Claude" }
                return chat.macAgentName.map { "On your Mac \u{00B7} \($0)" } ?? "On your Mac"
            }
        }
        if chat.messages.contains(where: { $0.role == .typing && $0.by != .iphone }) { return "Thinking" }
        if let wait = chat.messages.last(where: { $0.role == .wait }) { return MacWords.waitsFor(wait.mac?.name ?? "your Mac") }
        if !app.isFixture {
            if chat.by == .iphone { return "Apple Intelligence \u{00B7} on this \(DeviceWord.name)" }
            return chat.macAgentName.map { "\($0) \u{00B7} on your Mac" } ?? "On your Mac"
        }
        if fresh { return "Claude Opus \u{00B7} on your Mac" }
        let claude = chat.messages.contains { $0.by == .claude || $0.role == .pick }
        return claude ? "Claude Opus \u{00B7} on your Mac" : "Apple Intelligence \u{00B7} on this \(DeviceWord.name)"
    }

    /// The row's second line, and whether it needs you.
    @MainActor
    static func status(_ chat: Chat, app: AppModel) -> (text: String, warn: Bool) {
        if let id = chat.task, let def = app.tasks.definition(id) {
            guard let run = app.tasks.run(id), run.status != .done else { return (def.result, false) }
            let item = NowItem.task(run, def)
            return (item.subtitle, item.kind == .warn)
        }
        if let typing = chat.messages.first(where: { $0.role == .typing }) {
            return ("\(providerName(chat, app: app, by: typing.by ?? .claude)) is answering", false)
        }
        if let wait = chat.messages.last(where: { $0.role == .wait }) { return (MacWords.waitsFor(wait.mac?.name ?? "your Mac"), false) }
        if let last = chat.messages.last, last.role == .failed { return (last.mac?.expired == true ? "Expired" : "Not Sent", true) }
        if !app.isFixture, let last = chat.messages.last, last.role == .note { return (last.plain, true) }
        if let last = chat.lastAnswer {
            if let pick = last.pick { return ("\(pick.head) \u{00B7} \(pick.rows.first?[safe: 1] ?? "")", false) }
            return (line(last), false)
        }
        return ("New chat", false)
    }

    /// The text a held chat lifts with: its last answer, or its status.
    @MainActor
    static func preview(_ chat: Chat, app: AppModel) -> String {
        if chat.task != nil { return status(chat, app: app).text }
        if let last = chat.lastAnswer { return last.pick?.why ?? line(last) }
        return "New chat"
    }

    /// An answer on one row: its markdown (and the old <b> marks) read as
    /// the words they show, the blocks run together on one line.
    static func line(_ message: Message) -> String {
        ChatMarkdown.plain(message.text)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
