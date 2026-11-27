import SwiftUI
import SyncKit
import UIKit

// Add to Chat: a tray. One
// surface floating 8 in from the screen's edges, its corners concentric with
// the iPhone's, as tall as what it holds; it grows out of the + that opened
// it and goes back into it. Its pages (the attachments and the model card,
// Model, Reasoning) replace one another in it: the height changes, the old
// and new words cross over each other with a few points of rise, × turns
// into ‹, and the dim behind stays the tray's, not a page's. Ticks and the
// capsule's count change at once; only geometry moves.

enum AttachPage: Equatable, Sendable { case main, model, reasoning, mac }

/// The model and effort picked for a chat's next words; nil fields are the
/// Mac's own choice ("Default", "Auto").
struct ModelChoice: Equatable, Sendable {
    var cli: String?
    var model: String?
    var effort: String?
}

/// What named states put in place of the Mac and the camera.
@MainActor
enum AttachStandIns {
    /// The fixture Mac takes photos and files, and offers models.
    static var attachments = true
    static var models = true
    /// The stand-in camera's picture.
    static var photos: [UIImage] = []
    static var camera: AttachCamera.Status? = .notDetermined

    static let macModels: [SyncMacModel] = {
        let claude = ["low", "medium", "high", "xhigh", "max"]
        return [
            SyncMacModel(cli: "claude", model: "fable", name: "Claude Fable", about: "The newest and most capable.", efforts: claude),
            SyncMacModel(cli: "claude", model: "opus", name: "Claude Opus", about: "For long, hard tasks.", efforts: claude),
            SyncMacModel(cli: "claude", model: "sonnet", name: "Claude Sonnet", about: "Fast and capable, for most work.", efforts: claude),
            SyncMacModel(cli: "claude", model: "haiku", name: "Claude Haiku", about: "The fastest, for short text.", efforts: claude),
            SyncMacModel(cli: "codex", model: "gpt-6.1-sol", name: "GPT-6.1-Sol", about: "The most capable, for long, hard work.",
                         efforts: ["low", "medium", "high", "xhigh", "ultra"]),
            SyncMacModel(cli: "codex", model: "gpt-6-astra", name: "GPT-6-Astra", about: "Fast and capable, for most work.",
                         efforts: ["low", "medium", "high", "xhigh"]),
            SyncMacModel(cli: "codex", model: "gpt-6-luna", name: "GPT-6-Luna", about: "The fastest, for short tasks.",
                         efforts: ["low", "medium", "high"]),
        ]
    }()
}

// MARK: - the flow

extension AppModel {
    func openAttachTray() {
        let sheet = chatSheet
        guard let id = sheet.chatID, canAttach(id) else { return }
        Haptics.play(.light, reason: Haptics.Reason.menu)
        sheet.focused = false
        var still = Transaction(animation: nil)
        still.disablesAnimations = true
        withTransaction(still) {
            sheet.attachPage = .main
            sheet.attachGeneration = UUID()
        }
        if Motion.disabled { sheet.attachMenu = true } else { withAnimation(AttachTrayMotion.open) { sheet.attachMenu = true } }
    }

    func closeAttachTray() {
        let sheet = chatSheet
        if Motion.disabled { sheet.attachMenu = false } else { withAnimation(AttachTrayMotion.close) { sheet.attachMenu = false } }
    }

    func attachTrayPage(_ page: AttachPage) {
        let sheet = chatSheet
        if Motion.disabled { sheet.attachPage = page } else { withAnimation(AttachTrayMotion.page) { sheet.attachPage = page } }
    }

    /// The tray closes, then hands over to one of the system's pickers.
    func attachTrayHandOver(_ open: @escaping (ChatSheet) -> Void) {
        closeAttachTray()
        let sheet = chatSheet
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            open(sheet)
        }
    }

    /// The models a chat's Mac offers it, and what the chat runs on now.
    func chatModels(_ id: Chat.ID) -> (models: [SyncMacModel], cli: String?, model: String?, effort: String?) {
        if isFixture { return (AttachStandIns.models ? AttachStandIns.macModels : [], nil, nil, nil) }
        return sync.models(for: id)
    }

    /// The pick for the chat's next words: chosen here, or what it runs on.
    func modelChoice(_ id: Chat.ID) -> ModelChoice {
        if let pick = chatSheet.picks[id] { return pick }
        let now = chatModels(id)
        return ModelChoice(cli: now.cli, model: now.model, effort: now.effort)
    }

    func pickModel(_ model: SyncMacModel?, for id: Chat.ID) {
        var pick = modelChoice(id)
        pick.cli = model?.cli
        pick.model = model?.model
        // A new model keeps the effort only if it takes it.
        if let effort = pick.effort, !(model?.efforts.contains(effort) ?? true) { pick.effort = nil }
        chatSheet.picks[id] = pick
        attachTrayPage(.main)
    }

    func pickEffort(_ effort: String?, for id: Chat.ID) {
        var pick = modelChoice(id)
        pick.effort = effort
        chatSheet.picks[id] = pick
        attachTrayPage(.main)
    }
}

enum AttachTrayMotion {
    /// Growing out of +: 0.34; going back faster, so the exit never lags.
    static let open = Animation.spring(response: 0.34, dampingFraction: 0.86)
    static let close = Animation.spring(response: 0.2, dampingFraction: 1)
    /// A page for another, and the height that comes with it.
    static let page = Animation.spring(response: 0.32, dampingFraction: 0.88)
    static let height = Animation.spring(response: 0.3, dampingFraction: 0.88)
}

// MARK: - the tray

/// Over everything in the chats' layer, in screen points.
struct AttachTrayLayer: View {
    @Environment(AppModel.self) private var app
    let screen: CGSize
    @State private var heights: [AttachPage: CGFloat] = [:]
    private typealias R = Metrics.Chats
    private static let header: CGFloat = 60

    var body: some View {
        let sheet = app.chatSheet
        let open = sheet.attachMenu
        let width = screen.width - 2 * R.trayInset
        // At most up to the status bar; a taller page scrolls in it.
        let cap = screen.height - 70 - Self.header
        let page = min(heights[sheet.attachPage] ?? 0, cap)
        let height = Self.header + page
        let tray = CGRect(x: R.trayInset, y: screen.height - R.trayInset - height, width: width, height: height)
        let origin = sheet.attachOrigin == .zero ? CGRect(x: tray.minX + 20, y: tray.maxY - 40, width: 32, height: 32) : sheet.attachOrigin
        let rect = open ? tray : origin
        let shape = RoundedRectangle(cornerRadius: open ? R.trayCorner : origin.height / 2, style: .continuous)
        ZStack(alignment: .topLeading) {
            // The dim is the tray's: one for every page.
            Color.black.opacity(open ? 0.28 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { app.closeAttachTray() }
                .allowsHitTesting(open)
                .accessibilityHidden(true)
            ZStack(alignment: .top) {
                AttachTrayHeader()
                    .frame(height: Self.header)
                    .zIndex(1)
                ForEach([AttachPage.main, .model, .reasoning, .mac], id: \.self) { which in
                    let shown = which == sheet.attachPage
                    AttachTrayPage(page: which, cap: cap) { heights[which] = $0 }
                        // No compositing group: the camera's live preview stays a live layer.
                        .opacity(shown ? 1 : 0)
                        // The page coming in rises a few points over the one going.
                        .offset(y: shown ? 0 : 8)
                        .allowsHitTesting(shown)
                        .accessibilityHidden(!shown)
                        .padding(.top, Self.header)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(width: width, height: max(height, 1), alignment: .top)
            .opacity(open ? 1 : 0)
            .frame(width: rect.width, height: rect.height, alignment: .top)
            .background(Ink.card, in: shape)
            .clipShape(shape)
            .shadow(color: .black.opacity(open ? 0.18 : 0), radius: 24, y: 8)
            .offset(x: rect.minX, y: rect.minY)
            .opacity(open ? 1 : 0)
            .allowsHitTesting(open)
            .animation(AttachTrayMotion.height, value: height)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.attachTray")
            .accessibilityHidden(!open)
        }
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
    }
}

/// × (or ‹ on a page of a choice) and the page's name.
private struct AttachTrayHeader: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let page = app.chatSheet.attachPage
        ZStack {
            // Each page's name crossfades in place, moving with the tray.
            ForEach([(AttachPage.main, "Add to Chat"), (.model, "Model"), (.reasoning, "Reasoning"), (.mac, "Mac")], id: \.1) { which, title in
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .opacity(which == page ? 1 : 0)
                    .accessibilityHidden(which != page)
            }
            .frame(maxWidth: .infinity)
            HStack {
                Button {
                    Haptics.play(.light, reason: Haptics.Reason.menu)
                    if page == .main { app.closeAttachTray() } else { app.attachTrayPage(.main) }
                } label: {
                    Image(systemName: page == .main ? "xmark" : "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 36, height: 36)
                        .background(ChatInk.fill(0.12), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.attachTray.close")
                .accessibilityLabel(page == .main ? "Close" : "Back")
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }
}

/// A page, scrolling only when it is taller than the tray may be.
private struct AttachTrayPage: View {
    @Environment(AppModel.self) private var app
    let page: AttachPage
    let cap: CGFloat
    let measured: (CGFloat) -> Void
    @State private var natural: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, Metrics.Chats.trayPad)
                .padding(.top, 4)
                .padding(.bottom, Metrics.Chats.trayPad)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    natural = height
                    measured(height)
                }
        }
        .scrollDisabled(natural <= cap)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(natural, cap))
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .main: AttachMainPage()
        case .model: ModelPage()
        case .reasoning: ReasoningPage()
        case .mac: MacPage()
        }
    }
}

// MARK: - the main page

private struct AttachMainPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let id = app.chatSheet.chatID ?? ""
        let models = app.chatModels(id)
        VStack(spacing: 12) {
            // Camera (live once allowed), Photos and Files: three cards of one
            // size. Photos is the system's picker; Yab never reads the library.
            HStack(spacing: Metrics.Chats.attachTileGap) {
                AttachCameraTile { camera() }
                AddTile(label: "Photos", symbol: "photo.on.rectangle", id: "chat.attachTray.photos") { photos() }
                AddTile(label: "Files", symbol: "doc", id: "chat.attachTray.files") { files() }
            }
            let macs = app.newChatMacs(id)
            if !models.models.isEmpty || !macs.isEmpty {
                let pick = app.modelChoice(id)
                let model = models.models.first { $0.model == pick.model && (pick.cli == nil || $0.cli == pick.cli) }
                VStack(spacing: 0) {
                    if !models.models.isEmpty {
                        ChoiceRow(title: "Model", value: model?.choiceLabel ?? "Default", id: "chat.attachTray.model") { app.attachTrayPage(.model) }
                        Divider().padding(.leading, 16)
                        ChoiceRow(title: "Reasoning", value: pick.effort.map(SyncMacModel.effortTitle) ?? "Auto",
                                  id: "chat.attachTray.reasoning") { app.attachTrayPage(.reasoning) }
                    }
                    // A new chat with two Macs or more: which one it starts on,
                    // under the effort; a chat already started stays on its Mac.
                    if !macs.isEmpty, let mac = app.sync.newWorkMac() {
                        if !models.models.isEmpty { Divider().padding(.leading, 16) }
                        ChoiceRow(title: "Mac", value: mac.state.isUp ? mac.name : "\(mac.name) · \(MacWords.state(mac.state, now: Date()).lowercased().components(separatedBy: " since").first ?? "")",
                                  id: "chat.attachTray.mac") { app.attachTrayPage(.mac) }
                    }
                }
                .background(ChatInk.fill(0.08), in: RoundedRectangle(cornerRadius: Metrics.Chats.trayCard, style: .continuous))
            }
        }
    }

    private func camera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            app.closeAttachTray()
            app.say("No camera on this iPhone", glyph: .camera1)
            return
        }
        app.attachTrayHandOver { $0.attachCamera = true }
    }

    private func photos() {
        Haptics.play(.light, reason: Haptics.Reason.menu)
        app.attachTrayHandOver { $0.attachLibrary = true }
    }

    private func files() {
        Haptics.play(.light, reason: Haptics.Reason.menu)
        app.attachTrayHandOver { $0.attachFiles = true }
    }
}

private struct ChoiceRow: View {
    let title: String
    let value: String
    let id: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.play(.light, reason: Haptics.Reason.menu)
            action()
        } label: {
            HStack(spacing: 8) {
                Text(title).foregroundStyle(Ink.primary)
                Spacer(minLength: 8)
                Text(value)
                    .foregroundStyle(ChatInk.gray(0.6))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ChatInk.gray(0.4))
            }
            .font(.system(size: 17))
            .padding(.horizontal, 16)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// Photos, Files: a mark over its name, as big as the camera's card.
private struct AddTile: View {
    let label: String
    let symbol: String
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Metrics.Chats.attachMediaGap) {
                Image(systemName: symbol).font(.system(size: Metrics.Chats.attachCameraSymbol))
                Text(label).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Ink.primary)
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.Chats.attachMediaHeight)
            .background(ChatInk.fill(0.08), in: RoundedRectangle(cornerRadius: Metrics.Chats.trayCard, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Metrics.Chats.trayCard, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
    }
}

// MARK: - Model and Reasoning

private struct ModelPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let id = app.chatSheet.chatID ?? ""
        let models = app.chatModels(id).models
        let pick = app.modelChoice(id)
        let plans = ChatAgent.allCases.map(\.rawValue).filter { cli in models.contains { $0.cli == cli } }
        VStack(alignment: .leading, spacing: 14) {
            OptionCard {
                OptionRow(title: "Default", about: "What your Mac uses for its chats", checked: pick.model == nil) {
                    app.pickModel(nil, for: id)
                }
            }
            ForEach(plans, id: \.self) { cli in
                VStack(alignment: .leading, spacing: 6) {
                    Text(SyncMacModel.plan(cli))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ChatInk.gray(0.55))
                        .padding(.leading, 16)
                    OptionCard {
                        let group = models.filter { $0.cli == cli }
                        ForEach(Array(group.enumerated()), id: \.element.id) { n, model in
                            if n > 0 { Divider().padding(.leading, 16) }
                            OptionRow(title: model.name, about: model.detail,
                                      checked: pick.model == model.model && (pick.cli == nil || pick.cli == model.cli)) {
                                app.pickModel(model, for: id)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("chat.attachTray.models")
    }
}

private struct ReasoningPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let id = app.chatSheet.chatID ?? ""
        let models = app.chatModels(id).models
        let pick = app.modelChoice(id)
        // The picked model's efforts; with the Mac's default, its first one's.
        let model = models.first { $0.model == pick.model && (pick.cli == nil || $0.cli == pick.cli) }
            ?? models.first { $0.cli == (pick.cli ?? "claude") } ?? models.first
        OptionCard {
            OptionRow(title: "Auto", about: nil, checked: pick.effort == nil) { app.pickEffort(nil, for: id) }
            ForEach(model?.efforts ?? [], id: \.self) { effort in
                Divider().padding(.leading, 16)
                OptionRow(title: SyncMacModel.effortTitle(effort), about: nil, checked: pick.effort == effort) {
                    app.pickEffort(effort, for: id)
                }
            }
        }
        .accessibilityIdentifier("chat.attachTray.efforts")
    }
}

/// The Macs a new chat can start on, each with what it is doing in words.
private struct MacPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let id = app.chatSheet.chatID ?? ""
        let picked = app.sync.newWorkMac()?.id
        OptionCard {
            ForEach(Array(app.newChatMacs(id).enumerated()), id: \.element.id) { n, mac in
                if n > 0 { Divider().padding(.leading, 16) }
                OptionRow(title: mac.name, about: MacWords.state(mac.state, now: Date()), checked: mac.id == picked) {
                    app.pickMac(mac)
                }
            }
        }
        .accessibilityIdentifier("chat.attachTray.macs")
    }
}

private struct OptionCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(ChatInk.fill(0.08), in: RoundedRectangle(cornerRadius: Metrics.Chats.trayCard, style: .continuous))
    }
}

private struct OptionRow: View {
    let title: String
    let about: String?
    let checked: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.play(.selection, reason: Haptics.Reason.chatAction)
            action()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17))
                        .foregroundStyle(Ink.primary)
                    if let about, !about.isEmpty {
                        Text(about)
                            .font(.system(size: 13))
                            .foregroundStyle(ChatInk.gray(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(checked ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: about?.isEmpty == false ? 60 : 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.attachTray.option")
        .accessibilityLabel(title)
        .accessibilityValue(about ?? "")
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}
