import AppKit
import Combine
import SwiftUI
import SyncKit

/// The icon shown in the Dock. The app bundle keeps its signed, built-in icon.
enum AppIconStyle: String, CaseIterable, Identifiable {
    case original
    case standard = "yab-standard"
    // Halloween 2026 (Halloween.swift): here until November 2, then only
    // the ones worn by then.
    case pumpkin = "16-halloween-pumpkin"
    case ghost = "17-halloween-ghost"
    case mummy = "18-halloween-mummy"
    case witch = "19-halloween-witch"
    case flat = "07-flat"
    case watercolorGlass = "08-watercolor-glass"
    // Keep the stored identifiers so existing icon selections survive the refresh.
    case opal = "01-prismatic-frost"
    // From a post on X (PostReward): one a post, a surprise until it opens.
    case chrome = "02-liquid-mercury"
    case amber = "04-prism-spectral"
    case redEnamel = "06-ember"
    /// Stands for those three in App Icon while any is still to win; never worn.
    case surprise
    // From friends (Invites): locked until enough of them open Yab with
    // your link, and the best friend charm, drawn as it is right now.
    case waxSeal = "11-wax-seal"
    case bracelet = "12-friendship-bracelet"
    case ticket = "13-golden-ticket"
    case yearbook = "14-yearbook"
    case charm
    // For finishing Yab Wrapped (Wrapped.swift).
    case arcade = "15-arcade"
    // A personal thank-you for early feedback, hidden until received.
    case firstEdition = "20-first-edition"

    static let key = "appearance.appIcon"

    /// Shown once yours: a post's icons, and the surprise while any is left.
    @MainActor static var choices: [Self] {
        allCases.filter { style in
            if style == .standard { return Store.development }
            if style == .firstEdition { return style.unlocked }
            if style.halloween { return style.unlocked }
            // Arcade is Yab Wrapped's prize: not shown at all until it is won.
            if style == .arcade { return style.unlocked }
            if PostReward.icons.contains(style) { return style.unlocked }
            if style == .surprise { return !PostReward.icons.allSatisfy(\.unlocked) }
            return true
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return Store.development ? "Dev" : "Default"
        case .standard: return "Default"
        case .surprise: return "Surprise Icon"
        default: return AppIconCatalog(rawValue: rawValue)?.title ?? rawValue
        }
    }

    /// One of Halloween's, which come and go with it.
    var halloween: Bool { [.pumpkin, .ghost, .mummy, .witch].contains(self) }

    /// Where the compiled icons and the charm's halves are: the app's
    /// Resources, or a development build's for a SwiftPM run.
    static var resources: URL? {
        if Bundle.main.bundleIdentifier != nil { return Bundle.main.resourceURL }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("build/yab Dev.app/Contents/Resources")
    }

    /// Whether this one can be worn: friends' icons only once unlocked.
    @MainActor var unlocked: Bool {
        if let icon = AppIconCatalog(rawValue: rawValue), Store.settings.bool(forKey: icon.grantKey) {
            return true
        }
        if self == .firstEdition { return FirstEdition.owned }
        if self == .arcade { return Wrapped.finished }
        if self == .surprise { return false }
        if halloween { return Halloween.on || Halloween.worn.contains(rawValue) }
        if PostReward.icons.contains(self) { return PostReward.shared.owns(self) }
        return Invites.shared.unlocks(self)
    }

    /// The one worn, as saved.
    static var saved: Self { Store.settings.string(forKey: key).flatMap(Self.init) ?? .original }

    /// An open picker also shows awards that were already visible but locked.
    @MainActor static func sharedSettingsChanged(_ keys: Set<String>) {
        let palette = !keys.isDisjoint(with: SyncShapes.charmPaletteKeys)
        guard palette || keys.contains(where: { AppIconGrants.icon(for: $0) != nil }) else { return }
        Invites.shared.objectWillChange.send()
        if palette, saved == .charm {
            Self.charm.apply()
            announce()
        }
    }

    /// What a locked one takes, in words under its name.
    @MainActor var takes: String? {
        guard !unlocked else { return nil }
        if self == .charm { return "Comes with a best friend. Joined while you're both in Yab." }
        if self == .arcade { return "For finishing Yab Wrapped." }
        if self == .firstEdition { return "A thank-you for helping shape Yab." }
        if self == .surprise || PostReward.icons.contains(self) { return PostReward.shared.takes }
        guard let need = Invites.ladder.first(where: { $0.style == self })?.friends else { return nil }
        let have = Invites.shared.joined
        return need == 1 ? "Comes with your first friend. They get it too." : "From \(need) friends. \(have) of \(need) so far."
    }

    /// Worn now: saved, put in the Dock and told to the Dock's tile.
    @MainActor func choose() {
        guard unlocked else { return }
        Store.settings.set(rawValue, forKey: Self.key)
        if halloween { Halloween.wore(rawValue) }
        apply()
        Self.announce()
    }

    func image(dark: Bool) -> NSImage? {
        if self == .surprise { return PostReward.surprisePicture(dark: dark) }
        if self == .charm {
            guard let resources = Self.resources else { return nil }
            let charm = Self.charmNow
            return CharmDraw.image(resources: resources, left: charm.left, right: charm.right, apart: charm.apart)
        }
        let relativePath: String
        if self == .original, !dark {
            relativePath = "yab.icns"
        } else {
            let name = self == .original ? "yab-dark" : rawValue + (dark ? "-dark" : "")
            relativePath = "AppIcons/\(name).icns"
        }

        if let resources = Bundle.main.resourceURL,
           let image = NSImage(contentsOf: resources.appendingPathComponent(relativePath)) {
            return image
        }

        // SwiftPM runs have no app bundle. Reuse compiled icon previews if a
        // development build exists, but never show the unmasked source art.
        guard Bundle.main.bundleIdentifier == nil else { return nil }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resources = repo.appendingPathComponent("build/yab Dev.app/Contents/Resources")
        return NSImage(contentsOf: resources.appendingPathComponent(relativePath))
    }

    @MainActor
    func apply() {
        if self == .original {
            // Nil restores the bundle's Icon Composer icon, including the
            // light, dark, tinted and clear versions chosen by macOS.
            NSApplication.shared.applicationIconImage = Bundle.main.bundleIdentifier == nil
                ? Links.dockIcon() : nil
        } else if let image = image(dark: Self.systemDark) {
            NSApplication.shared.applicationIconImage = image
        }
    }

    /// Tells the Dock's plug-in (DockTile/) the choice changed, so the tile
    /// keeps it once Yab quits: macOS forgets applicationIconImage then.
    static func announce() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("\(id).appIconChanged"), object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Light or dark as macOS is, which the Dock is, not as Yab's own Theme
    /// sets its windows: NSApp's appearance is the Theme's, which a Light
    /// Theme would keep light on a dark Mac.
    static var systemDark: Bool {
        dark(interfaceStyle: UserDefaults.standard.string(forKey: "AppleInterfaceStyle"))
    }

    /// macOS writes "Dark" while dark, Auto included, and nothing while light.
    static func dark(interfaceStyle: String?) -> Bool {
        interfaceStyle?.caseInsensitiveCompare("Dark") == .orderedSame
    }

    /// The Mac turned light or dark, the same note Browser.relook hears.
    static let systemChanged = Notification.Name("AppleInterfaceThemeChangedNotification")

    @MainActor
    static func applySaved() {
        let saved = Store.settings.string(forKey: key)
        var choice = saved.flatMap(Self.init) ?? .original
        // An award can arrive with its choice or later in the same sync.
        // Until this device has it, keep the default in the Dock.
        if !choice.unlocked { choice = .original }
        if saved != nil, saved != choice.rawValue {
            Store.settings.set(choice.rawValue, forKey: key)
        }
        choice.apply()
    }
}

/// The Dock's icon in Appearance: the chosen one small beside its name,
/// the whole row opening App Icon, where they are shown large.
struct AppIconRow: View {
    @ObservedObject var model: SettingsModel
    @AppStorage(AppIconStyle.key, store: Store.settings) private var selection: AppIconStyle = .original
    @State private var dark = AppIconStyle.systemDark

    var body: some View {
        Button { model.go(.appIcon) } label: {
            SettingsRow("App icon") {
                HStack(spacing: 6) {
                    Image(nsImage: AppIconStyle.picture(selection, dark: dark))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 24, height: 24)
                    Text(selection.title)
                        .foregroundStyle(.secondary)
                    SettingsChevron()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens App Icon")
        .onReceive(AppIconStyle.systemChangedLate) { _ in dark = AppIconStyle.systemDark }
    }
}

extension EnvironmentValues {
    /// How tall a Settings page shows under the window's toolbar.
    @Entry var settingsPageHeight: CGFloat = 0
}

/// The icons large, one at a time in the middle as the Dock shows it, its
/// shadow and all, the rest turned away to either side, as Cover Flow
/// showed albums. The arrows, a swipe or a click on a neighbor bring the
/// next one round only to be looked at; Choose (or Return) puts it in the
/// Dock, so leafing through never changes what the Dock wears.
struct AppIconPage: View {
    var model: SettingsModel?
    @AppStorage(AppIconStyle.key, store: Store.settings) private var selection: AppIconStyle = .original
    @ObservedObject private var invites = Invites.shared
    /// The one in the middle, when it isn't the one worn: shown, not worn.
    @State private var looking: AppIconStyle?
    @State private var dark = AppIconStyle.systemDark
    @FocusState private var focused: Bool
    @Environment(\.settingsPageHeight) private var pageHeight
    /// Where a drag with the mouse began, by index, while it lasts.
    @State private var dragFrom: Int?
    /// How far past the middle one the drag has the row, in icons, under
    /// half either way: the rest of the way is a new middle one.
    @State private var shift: CGFloat = 0

    /// Halloween's that leave, shown a moment the first time after the end
    /// before the row closes up without them.
    @State private var choices = AppIconStyle.allCases.filter { AppIconStyle.choices.contains($0) || AppIconPage.leaving.contains($0) }
    /// The middle one's side, the icon's whole picture, shadow room included.
    private let side: CGFloat = 232
    /// How far the mouse goes to bring the next one round.
    private var stride: CGFloat { side * 0.4 }
    private static let turn = Animation.spring(response: 0.42, dampingFraction: 0.86)
    /// Halloween's orange, on its plate and dots while it lasts.
    static let pumpkin = Color(red: 0.85, green: 0.38, blue: 0.10)
    /// What the grouped form keeps above and below its one card.
    private static let margins: CGFloat = 40

    var body: some View {
        Section {
            VStack(spacing: 0) {
                flow
                FadingText(middle.title)
                    .font(.system(size: 17, weight: .semibold))
                    .padding(.top, 2)
                // One line kept for the note, so the dots don't jump.
                FadingText(note, wraps: true)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                dots
                    .padding(.top, 16)
                // Under the dots, so they stay put whatever is in the middle.
                if middle.unlocked {
                    Button { wear() } label: { FadingText(middle == selection ? "In the Dock" : "Choose") }
                        .buttonStyle(.yab(middle == selection ? .secondary : .primary, .regular))
                        .disabled(middle == selection)
                        .padding(.top, 16)
                } else if !middle.halloween {
                    if middle == .arcade {
                        // Played only when a moment is due, as ⌘T offers it.
                        if Wrapped.shared.due != nil {
                            Button("Play Yab Wrapped…") { Wrapped.shared.show(in: Links.browser) }
                                .buttonStyle(.yab(.secondary, .regular))
                                .padding(.top, 16)
                        }
                    } else {
                        Button {
                            model?.go(middle == .charm ? .bestFriend : .inviteFriends)
                        } label: {
                            FadingText(middle == .charm ? "Invite a Best Friend…" : middle == .surprise ? "Post on X…" : "Invite a Friend…")
                        }
                        .buttonStyle(.yab(.secondary, .regular))
                        .padding(.top, 16)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            // The card as tall as the page shows under the toolbar, the
            // icons in its middle: the page is only this, and never scrolls.
            .frame(minHeight: max(pageHeight - Self.margins, 0))
            .contentShape(Rectangle())
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { step(-1); return .handled }
            .onKeyPress(.rightArrow) { step(1); return .handled }
            .onKeyPress(.return) { wear(); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("App icon")
            .accessibilityValue(middle.title)
            .accessibilityAdjustableAction { direction in
                step(direction == .increment ? 1 : -1)
            }
        }
        .onAppear {
            focused = true
            arrive()
        }
        .onReceive(AppIconStyle.systemChangedLate) { _ in dark = AppIconStyle.systemDark }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let available = AppIconStyle.choices
            if available.contains(where: { !choices.contains($0) }) { choices = available }
        }
    }

    /// Halloween's icons not worn by its end, while App Icon hasn't yet
    /// shown them going.
    @MainActor static var leaving: [AppIconStyle] {
        guard !Halloween.on, !Store.settings.bool(forKey: Halloween.goodbyeKey) else { return [] }
        let worn = Halloween.worn
        return AppIconStyle.allCases.filter { $0.halloween && !worn.contains($0.rawValue) }
    }

    /// The first time after the update, on Pumpkin; the first time after
    /// the end, the ones that weren't worn turn away and the row closes up.
    private func arrive() {
        if Halloween.on, !Store.settings.bool(forKey: Halloween.introducedKey) {
            Store.settings.set(true, forKey: Halloween.introducedKey)
            if !selection.halloween { looking = .pumpkin }
        }
        guard choices.count != AppIconStyle.choices.count else { return }
        let gone = Set(choices).subtracting(AppIconStyle.choices)
        // The middle on one of them to watch it go, the one worn after.
        looking = gone.contains(.pumpkin) ? .pumpkin : gone.first
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            Store.settings.set(true, forKey: Halloween.goodbyeKey)
            withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
                looking = nil
                choices = AppIconStyle.choices
            }
        }
    }

    /// The one in the middle: one being looked at, or the one worn.
    private var middle: AppIconStyle { looking ?? selection }

    private var index: Int { choices.firstIndex(of: middle) ?? 0 }

    private var note: String {
        if middle.halloween { return middle.unlocked ? Halloween.note() : "Halloween is over. It leaves with it." }
        if let takes = middle.takes { return takes }
        if middle == .original { return "The only one macOS makes clear or tinted" }
        if middle == .charm, let best = invites.best { return invites.bestHere ? "With \(best.name). You're both in Yab." : "With \(best.name). It changes by itself." }
        if middle == .arcade { return "From Yab Wrapped." }
        if middle == .firstEdition { return "For helping shape Yab. Yours to keep." }
        if PostReward.icons.contains(middle) { return "From your post on X." }
        if Invites.ladder.contains(where: { $0.style == middle }) || middle == .charm { return "From your friends." }
        return " "
    }

    private var flow: some View {
        ZStack {
            ForEach(Array(choices.enumerated()), id: \.element) { i, style in
                // Each one's place a smooth step from the middle, so a drag
                // carries the row between the places a step would.
                let away = CGFloat(i - index) - shift
                let far = abs(away)
                let near = min(far, 1)
                let toward: CGFloat = away < 0 ? -1 : 1
                Image(nsImage: AppIconStyle.picture(style, dark: dark))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: side, height: side)
                    // Locked: the icon in gray, and what it takes on a plate over it.
                    .grayscale(style.unlocked ? 0 : 1)
                    .opacity(style.unlocked ? 1 : 0.7)
                    .overlay(alignment: .bottom) {
                        if style.halloween, i == index {
                            Text(style.unlocked ? Halloween.plate() : "Gone")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Halloween.on ? Self.pumpkin : Color.black.opacity(0.8))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.94), in: Capsule())
                                .padding(.bottom, 32)
                        } else if !style.unlocked, i == index {
                            Label(style == .charm ? "Best friend" : style == .arcade ? "Yab Wrapped" : style == .surprise ? "Surprise" : "Locked", systemImage: "lock.fill")
                                .font(.system(size: 12.5, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.regularMaterial, in: Capsule())
                                .padding(.bottom, 32)
                        }
                    }
                    .rotation3DEffect(.degrees(-toward * 50 * near), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
                    .scaleEffect(1 - 0.34 * near)
                    .offset(x: toward * (side * 0.62 * near + max(0, far - 1) * side * 0.24))
                    .opacity(far > 3 ? 0 : 1)
                    .zIndex(-Double(far))
                    .onTapGesture { look(style) }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
        .frame(height: side)
        .frame(maxWidth: .infinity)
        // The turned ones fade out toward the card's sides, not cut off at them.
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.16),
                                     .init(color: .black, location: 0.84), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        // Each icon a swipe brings round is felt as a tick on the trackpad,
        // none past the first or the last.
        .background(SwipeCatcher { by in
            if step(by) { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        })
        .contentShape(Rectangle())
        // A row to take hold of: the open hand over it, closed while held.
        .pointerStyle(dragFrom == nil ? .grabIdle : .grabActive)
        .gesture(drag)
    }

    /// The row held with the mouse and pulled aside: it follows the pointer,
    /// a new one taking the middle each stride, and let go it settles on the
    /// nearest, or further on for a flick.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let from = dragFrom ?? index
                dragFrom = from
                let moved = -value.translation.width / stride
                let to = min(max(from + Int(moved.rounded()), 0), choices.count - 1)
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    if to != index {
                        look(choices[to], animated: false)
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                    // Past the first or the last the row gives only a little.
                    let rest = moved - CGFloat(to - from)
                    let edge: CGFloat = rest < 0 ? -0.5 : 0.5
                    shift = abs(rest) > 0.5 ? edge + (rest - edge) * 0.2 : rest
                }
            }
            .onEnded { value in
                let from = dragFrom ?? index
                let flung = -value.predictedEndTranslation.width / stride
                let to = min(max(from + Int(flung.rounded()), 0), choices.count - 1)
                dragFrom = nil
                withAnimation(Self.turn) {
                    look(choices[to], animated: false)
                    shift = 0
                }
            }
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(choices) { style in
                let pumpkin = style.halloween && Halloween.on
                // Each dot's two looks cross-fade: a changing fill is resolved again every frame.
                ZStack {
                    Circle()
                        .fill(pumpkin ? AnyShapeStyle(Self.pumpkin.opacity(0.45)) : style.unlocked ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                        .overlay(Circle().strokeBorder(style.unlocked ? Color.clear : Color.secondary.opacity(0.5), lineWidth: 1))
                        .opacity(style == middle ? 0 : 1)
                    Circle()
                        .fill(pumpkin ? AnyShapeStyle(Self.pumpkin) : AnyShapeStyle(.primary))
                        .opacity(style == middle ? 1 : 0)
                }
                .frame(width: 6, height: 6)
                .onTapGesture { look(style) }
            }
        }
    }

    /// Whether there was a next one to bring round.
    @discardableResult
    private func step(_ by: Int) -> Bool {
        let next = index + by
        guard choices.indices.contains(next) else { return false }
        look(choices[next])
        return true
    }

    /// Brought to the middle to be looked at; the Dock keeps what it wears.
    private func look(_ style: AppIconStyle, animated: Bool = true) {
        guard style != middle else { return }
        let next = style == selection ? nil : style
        if animated { withAnimation(Self.turn) { looking = next } } else { looking = next }
    }

    /// The one in the middle into the Dock, if it can be worn.
    private func wear() {
        guard middle.unlocked, middle != selection else { return }
        middle.choose()
        looking = nil
    }
}

/// Changing words cross-faded between two fixed slots: Text's own content transition is redrawn
/// on the CPU every frame, and a view per string would pile up while a key is held.
private struct FadingText: View {
    let words: String
    let wraps: Bool
    @State private var slots: [String]
    @State private var front = 0
    @State private var change = Change()

    init(_ words: String, wraps: Bool = false) {
        self.words = words
        self.wraps = wraps
        _slots = State(initialValue: [words, ""])
    }

    /// The transaction the words last changed in: onChange runs outside it.
    private final class Change { var transaction = Transaction() }

    var body: some View {
        // The hidden copy sizes it, so a button still widens with its words.
        // Wrapping words lay out at the full width, so the outgoing copy keeps its lines.
        Text(words)
            .hidden()
            .frame(maxWidth: wraps ? .infinity : nil)
            .transaction { [change] in change.transaction = $0 }
            .overlay {
                ZStack {
                    ForEach(slots.indices, id: \.self) { slot in
                        Text(slots[slot])
                            .fixedSize(horizontal: !wraps, vertical: true)
                            .contentTransition(.identity)
                            // New words take their place at once: only the opacity animates.
                            .animation(nil, value: slots[slot])
                            .opacity(slot == front ? 1 : 0)
                    }
                }
            }
            .onChange(of: words) { _, new in
                // The capture doesn't run for a change made without one, so an old one isn't replayed.
                let transaction = change.transaction
                change.transaction = Transaction()
                withTransaction(transaction) {
                    front = 1 - front
                    slots[front] = new
                }
            }
    }
}

/// A sideways swipe over the icons, one step for each stretch of it, read
/// from the window's scroll events: the page's own scrolling only goes up
/// and down, and a view of ours on top would take the clicks.
private struct SwipeCatcher: NSViewRepresentable {
    let step: (Int) -> Void

    func makeNSView(context: Context) -> Catcher { Catcher(step: step) }
    func updateNSView(_ view: Catcher, context: Context) { view.step = step }

    final class Catcher: NSView {
        var step: (Int) -> Void
        private var monitor: Any?
        private var run: CGFloat = 0

        init(step: @escaping (Int) -> Void) {
            self.step = step
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                      abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                else { return event }
                if event.phase == .began { self.run = 0 }
                self.run -= event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : 10)
                if abs(self.run) > 70 {
                    self.step(self.run > 0 ? 1 : -1)
                    self.run = 0
                }
                return nil
            }
        }
    }
}

extension AppIconStyle {
    /// The Mac turning light or dark, heard once macOS has written it down.
    static var systemChangedLate: AnyPublisher<Notification, Never> {
        DistributedNotificationCenter.default().publisher(for: systemChanged)
            .delay(for: .seconds(0.3), scheduler: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    /// What the charm is drawn from, as the Dock's tile reads it: each
    /// half's color and whether they are apart (Invites.charmChanged).
    static var charmNow: (left: String, right: String?, apart: Bool) {
        let settings = Store.settings
        return (settings.string(forKey: "invite.charm.left") ?? "mint", settings.string(forKey: "invite.charm.right"),
                settings.bool(forKey: "invite.charm.apart"))
    }

    /// The whole picture the Dock draws, room for its shadow included, read
    /// once a look and drawn at whatever size it is asked for.
    @MainActor private static var kept: [String: NSImage] = [:]
    /// The charm as last drawn, and what it was drawn from.
    @MainActor private static var keptCharm: (from: String, image: NSImage)?

    @MainActor static func picture(_ style: AppIconStyle, dark: Bool) -> NSImage {
        let key = style.rawValue + (dark ? "-dark" : "")
        // The charm is drawn as it is right now: its colors and whether
        // the halves are apart change while Yab runs. Kept until they do:
        // a new image each time it was asked for was drawn again, at its
        // full size on the main thread, in every pass of App Icon's row.
        if style == .charm {
            let charm = charmNow
            let from = "\(charm.left)|\(charm.right ?? "")|\(charm.apart)"
            if let keptCharm, keptCharm.from == from { return keptCharm.image }
            let image = style.image(dark: dark) ?? NSImage()
            keptCharm = (from, image)
            return image
        }
        if let image = kept[key] { return image }
        let image = style.image(dark: dark) ?? NSImage()
        kept[key] = image
        return image
    }
}
