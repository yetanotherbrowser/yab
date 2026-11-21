import SwiftUI
import UIKit

/// These are the browser's existing spaces, not a second settings copy.
struct SettingsSpacesView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        VStack(spacing: Metrics.Settings.sectionGap) {
            VStack(spacing: 0) {
                ForEach(app.browser.spaces) { space in
                    let locked = space.isPrivate && !app.privateLock.mayReveal
                    Button {
                        if space.isPrivate { SettingsUI.shared.openPage(.privateTabs) }
                        else { SettingsUI.shared.open(.space(space.id)) }
                    } label: {
                        // Each opens its own page: a chevron, as every row that
                        // opens one; the space on screen says so under its name.
                        HStack(spacing: Metrics.Settings.rowGap) {
                            SpaceLookTile(emoji: locked ? "" : space.emoji, look: space.isPrivate ? nil : space.look,
                                          tint: space.tint, isPrivate: space.isPrivate, size: Metrics.Settings.spaceTile)
                            VStack(alignment: .leading, spacing: Metrics.Settings.stackGap) {
                                Text(space.isPrivate ? "Private" : space.name).font(.body).foregroundStyle(SettingsInk.text)
                                Text(locked ? "Locked" : "\(space.allTabs.count) tabs" + (space.id == app.browser.spaceID ? " · on screen" : ""))
                                    .font(.footnote).foregroundStyle(SettingsInk.footer)
                            }.fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Glyph(.chevronRight, size: Metrics.Settings.chevron, color: SettingsInk.chevron)
                        }.padding(.horizontal, Metrics.Settings.rowPadding).padding(.vertical, Metrics.Settings.stackPadding)
                            .frame(minHeight: Metrics.Settings.row).contentShape(Rectangle())
                    }.buttonStyle(SettingsRowStyle()).accessibilityIdentifier("settings.space.\(space.id)")
                }
            }.background(SettingsInk.group, in: RoundedRectangle(cornerRadius: Metrics.Settings.groupRadius))
            // Settings is where spaces are made on the iPhone now: the new one
            // is made here and its page opens on its name, in Settings.
            Button {
                let ui = SettingsUI.shared
                Haptics.play(.light, reason: Haptics.Reason.spaceMade)
                let id = app.browser.createSpace(name: "", emoji: "🌐", look: SpaceLook(color: RGB(168, 195, 160)))
                ui.namingNew = id
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                TaskMotion.run(.settingsPush) {
                    ui.navigation.append(.space(id))
                    ui.navigation.append(.spaceName(id))
                }
            } label: {
                Label("Add Space", systemImage: "plus").font(.body)
                    .frame(maxWidth: .infinity, minHeight: Metrics.touch).contentShape(Rectangle())
            }.buttonStyle(SettingsRowStyle()).accessibilityIdentifier("settings.spaces.add")
        }
    }
}

struct SettingsSpacePage: View {
    @Environment(AppModel.self) private var app
    @State private var asksDelete = false
    let spaceID: Space.ID
    var body: some View {
        ScrollView {
            if let space = app.browser.space(spaceID), !space.isPrivate {
                VStack(spacing: Metrics.Settings.sectionGap) {
                    VStack(spacing: Metrics.Settings.heroGap) {
                        SpaceLookTile(emoji: space.emoji, look: space.look, tint: space.tint, isPrivate: false, size: Metrics.Settings.heroTile)
                        Text(space.name).font(.title2.bold()).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader).accessibilityIdentifier("settings.page.title")
                        Text("\(space.allTabs.count) tabs" + (space.id == app.browser.spaceID ? " · on screen" : ""))
                            .font(.footnote).foregroundStyle(SettingsInk.footer)
                    }.frame(maxWidth: .infinity).padding(.top, Metrics.Settings.heroTop).padding(.bottom, Metrics.Settings.heroBottom)
                        .contentShape(Rectangle()).modifier(SettingsHeaderDismiss())
                    VStack(spacing: 0) {
                        edit("Name", value: space.name, id: "name", route: .spaceName(spaceID))
                        edit("Emoji", value: space.emoji, id: "emoji", route: .spaceEmoji(spaceID))
                        Button { SettingsUI.shared.open(.spaceColor(spaceID)) } label: {
                            HStack(spacing: Metrics.Settings.rowGap) {
                                VStack(alignment: .leading) {
                                    Text("Color").font(.body)
                                    Text("Color and grain, each with a deeper shade for dark.").font(.caption).foregroundStyle(SettingsInk.footer)
                                }.fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                SpaceLookTile(emoji: "", look: space.look, tint: space.tint, isPrivate: false, size: Metrics.touch)
                            }.padding(Metrics.Settings.rowPadding).frame(minHeight: Metrics.Settings.row).contentShape(Rectangle())
                        }.buttonStyle(SettingsRowStyle()).accessibilityIdentifier("settings.space.color")
                    }.background(SettingsInk.group, in: RoundedRectangle(cornerRadius: Metrics.Settings.groupRadius))
                    VStack(alignment: .leading, spacing: Metrics.Settings.headGap) {
                        Text("Sign-ins").font(.footnote).foregroundStyle(SettingsInk.footer)
                            .accessibilityAddTraits(.isHeader)
                        SpaceSignInsControls(spaceID: spaceID, route: .settings)
                    }
                    // As on the Mac: never the last space, nor the Mac's first.
                    if app.sync.mayDeleteSpace(spaceID) {
                        SettingsSection(section: SettingsSectionModel(id: "space.delete", title: nil, rows: [
                            SettingsRowModel(id: "space.delete", icon: nil, title: "Delete Space", value: nil,
                                             kind: .action({ asksDelete = true }), danger: true),
                        ])) { settingsTap($0, app: app) }
                    }
                }.padding(.horizontal, Metrics.Settings.bodySide).padding(.bottom, Metrics.Settings.bodyBottom)
                    .foregroundStyle(SettingsInk.text)
            } else {
                Text("This space is no longer available.").font(.body).foregroundStyle(SettingsInk.footer)
                    .padding(Metrics.Settings.bodySide).accessibilityIdentifier("settings.space.unavailable")
            }
        }.background(SettingsInk.pageGround).scrollIndicators(.hidden)
            .confirmationDialog("Delete \(app.browser.space(spaceID)?.name ?? "Space")?", isPresented: $asksDelete, titleVisibility: .visible) {
                Button("Delete Space", role: .destructive) {
                    Haptics.play(.rigid, reason: Haptics.Reason.spaceDeleted)
                    SettingsUI.shared.closePage()
                    app.sync.deleteSpace(spaceID)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its tabs close on this \(DeviceWord.name) and on your other devices.")
            }
            .accessibilityIdentifier("settings.space.page")
    }

    private func edit(_ title: String, value: String, id: String, route: SettingsRoute) -> some View {
        Button { SettingsUI.shared.open(route) } label: {
            RowWords(gap: Metrics.Settings.rowGap, lineGap: Metrics.Settings.stackGap, padding: Metrics.Settings.stackPadding) {
                Text(title).font(.body)
                Text(value).font(.body).foregroundStyle(SettingsInk.value)
            }.padding(.horizontal, Metrics.Settings.rowPadding).frame(minHeight: Metrics.Settings.row).contentShape(Rectangle())
        }.buttonStyle(SettingsRowStyle()).accessibilityIdentifier("settings.space.\(id)")
    }
}

struct SettingsSpaceEditor: View {
    @Environment(AppModel.self) private var app
    @State private var draft = SpaceTrayModel()
    @State private var started = false
    @FocusState private var focused: Bool
    let spaceID: Space.ID
    let step: SpaceTrayModel.Step
    private var title: String { step == .name ? "Name" : step == .emoji ? "Emoji" : "Color" }

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.Settings.sectionGap) {
                Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader).accessibilityIdentifier("settings.page.title")
                    .contentShape(Rectangle()).modifier(SettingsHeaderDismiss())
                if let space = app.browser.space(spaceID), !space.isPrivate, started {
                    switch step {
                    case .name:
                        TextField("Space name", text: Binding(get: { draft.name }, set: { draft.rename($0) }))
                            .font(.body).frame(minHeight: Metrics.touch).padding(Metrics.Settings.rowPadding)
                            .background(SettingsInk.group, in: RoundedRectangle(cornerRadius: Metrics.Settings.groupRadius))
                            .focused($focused).submitLabel(.done).onSubmit { done() }
                            .accessibilityIdentifier("settings.space.name.input")
                    case .emoji:
                        SpaceEmojiPicker(search: Binding(get: { draft.emojiSearch }, set: { draft.emojiSearch = $0 }),
                                         selected: draft.emoji, pick: { draft.pickEmoji($0) })
                    case .color:
                        SpaceLookEditor(look: draft.look, change: { draft.changeLook($0); draft.commitSoon(in: app.browser) },
                                        ended: { draft.commit(in: app.browser) })
                    default: EmptyView()
                    }
                } else if started {
                    Text("This space is no longer available.").font(.body).foregroundStyle(SettingsInk.footer)
                }
            }.frame(maxWidth: .infinity).padding(.horizontal, Metrics.Settings.bodySide)
                .padding(.top, Metrics.Settings.heroTop).padding(.bottom, Metrics.Settings.bodyBottom)
        }
        // Color: the page wears the look as it is changed, as the Mac's
        // window does under its card.
        .background { if step == .color, started { SpaceLookWash(look: draft.look).ignoresSafeArea() } else { SettingsInk.pageGround.ignoresSafeArea() } }
        .scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
            // Name the scroll viewport before adding Done as a sibling inset.
            // An outer identifier otherwise replaces the real button's ID.
            .accessibilityIdentifier("settings.space.editor")
            .safeAreaInset(edge: .bottom) {
                // The settings' confirm, as Use This Icon: ink on a capsule.
                let empty = step == .name && draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button(action: done) {
                    Text("Done").font(.body.weight(.semibold))
                        .foregroundStyle(SettingsInk.onInk)
                        .frame(maxWidth: .infinity, minHeight: Metrics.Settings.AppIcon.button)
                        .background(SettingsInk.ink.opacity(empty ? 0.3 : 1), in: Capsule())
                        .contentShape(Capsule())
                }.buttonStyle(SpaceDonePress())
                    .disabled(empty)
                    .accessibilityIdentifier("settings.space.done")
                    .padding(.horizontal, Metrics.Settings.bodySide).padding(.vertical, Metrics.Settings.headGap)
            }
            .onAppear {
                guard !started, let space = app.browser.space(spaceID), !space.isPrivate else { started = true; return }
                draft.start(step, space: space)
                // A space just made here: its name starts empty, not "Untitled".
                if step == .name, SettingsUI.shared.namingNew == spaceID { draft.name = ""; SettingsUI.shared.namingNew = nil }
                started = true
                focused = step == .name
            }
            .onDisappear { if started { draft.commit(in: app.browser) } }
    }
    private func done() {
        focused = false
        draft.commit(in: app.browser)
        SettingsUI.shared.closePage()
    }
}

/// Feedback goes to Yab's site, as the Mac's does (/api/feedback), into the
/// same table /admin's Inbox reads. The draft stays until the site took it.
struct SettingsFeedbackView: View {
    enum Sending: Equatable { case idle, sending, sent, failed(String) }
    @State private var sending = Sending.idle
    @AppStorage("feedback.email") private var email = ""
    var body: some View {
        @Bindable var ui = SettingsUI.shared
        let empty = ui.feedbackDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: Metrics.Settings.sectionGap) {
            TextField("What happened?", text: $ui.feedbackDraft, axis: .vertical)
                .font(.body).lineLimit(5...12).padding(Metrics.Settings.rowPadding)
                .frame(minHeight: Metrics.touch)
                .background(SettingsInk.group, in: RoundedRectangle(cornerRadius: Metrics.Settings.groupRadius))
                .accessibilityIdentifier("settings.feedback.draft")
            TextField("Email for a reply (optional)", text: $email)
                .font(.body).keyboardType(.emailAddress).textContentType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(Metrics.Settings.rowPadding).frame(minHeight: Metrics.touch)
                .background(SettingsInk.group, in: RoundedRectangle(cornerRadius: Metrics.Settings.groupRadius))
                .accessibilityIdentifier("settings.feedback.email")
            Button {
                Task { await send(ui.feedbackDraft) }
            } label: {
                Label(sending == .sending ? "Sending…" : "Send Feedback", systemImage: "paperplane").font(.body)
                    .frame(maxWidth: .infinity, minHeight: Metrics.touch).contentShape(Rectangle())
            }.buttonStyle(SettingsRowStyle()).disabled(empty || sending == .sending)
                .accessibilityIdentifier("settings.feedback.send")
            switch sending {
            case .sent:
                Text("Sent. Thank you.").font(.footnote).foregroundStyle(SettingsInk.footer)
                    .accessibilityIdentifier("settings.feedback.sent")
            case .failed(let why):
                Text(why).font(.footnote).foregroundStyle(SettingsInk.footer)
                    .accessibilityIdentifier("settings.feedback.unavailable")
            default:
                EmptyView()
            }
        }
    }

    private func send(_ message: String) async {
        guard let site = Reports.site else { sending = .failed("This build has nowhere to send it."); return }
        sending = .sending
        sending = await Self.submit(Self.request(message: message, email: email, site: site))
    }

    static func request(message: String, email: String, site: URL) -> URLRequest {
        var request = URLRequest(url: site.appendingPathComponent("api/feedback"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: Self.fields(message: message, email: email))
        return request
    }

    /// Keep the draft until the server accepts it, including on a failed connection.
    static func submit(_ request: URLRequest, session: URLSession = .shared, ui: SettingsUI = .shared) async -> Sending {
        let status = (try? await session.data(for: request)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
        if status == 200 {
            ui.feedbackDraft = ""
            return .sent
        } else {
            return .failed(status == nil ? "Couldn't reach Yab's site. Your draft is still here."
                                         : "The site didn't take it. Your draft is still here.")
        }
    }

    /// What /api/feedback reads: the Mac's fields, with the iPhone in os.
    static func fields(message: String, email: String) -> [String: String] {
        var model = utsname()
        uname(&model)
        let device = withUnsafeBytes(of: &model.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return ["kind": "other",
                "message": message,
                "email": email.trimmingCharacters(in: .whitespaces),
                "version": SettingsStore.version(),
                "build": SettingsStore.build(),
                "os": "iOS \(UIDevice.current.systemVersion) \(device)"]
    }
}

/// Done's press: it dims a little, as the icon picker's button does.
private struct SpaceDonePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}
