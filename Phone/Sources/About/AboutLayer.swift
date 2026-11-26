import SwiftUI
import UIKit

/// About Yab, as the Mac's: the app icon, the name, the version and build,
/// one line, the ways out (the site, the manual, feedback, the community),
/// the copyright. No credits. Opened by Yab's mark by the spaces' capsule;
/// it comes in from the side as a pushed page does, ‹ takes it back.
@MainActor
@Observable
final class AboutModel {
    static let shared = AboutModel()

    var shown = false

    static let website = URL(string: "https://yetanotherbrowser.com")!
    static let manual = URL(string: "https://yetanotherbrowser.com/manual")!
    /// Yab's community: the group chat on X the site's changelog links to (the Mac's Links.community).
    static let community = URL(string: "https://x.com/i/chat/group_join/g2108389056413618447/Tmr5OvF8Rx")!
    static let copyright = "© 2026 Serafim Korablev"
    static let line = "Yes, another one. A small, quiet browser for your \(DeviceWord.name)."
    static var version: String { "Version \(SettingsStore.version()) (\(SettingsStore.build()))" }

    /// Shown at once, for named states and tests.
    func hold() { shown = true }

    func open() {
        guard !shown else { return }
        Haptics.play(.soft, reason: Haptics.Reason.aboutPress)
        withAnimation(Motion.about.current) { shown = true }
    }

    func close() {
        guard shown else { return }
        withAnimation(Motion.about.current) { shown = false }
        Haptics.play(.soft, reason: Haptics.Reason.aboutBack)
    }

    /// Website, Manual and the community: a tab in Yab, the spaces put away, About gone at once.
    func open(_ url: URL, in app: AppModel) {
        shown = false
        app.adoptNewTabSpace()
        app.field.forget()
        app.closeFieldAfterChoice()
        app.show(PageFixtures.tab(for: url, in: app.world, fixturesEnabled: app.fixturesEnabled), newTab: true)
    }

    /// Send Feedback: Settings' own page for it, over the spaces.
    func feedback(in app: AppModel) {
        shown = false
        app.openSettingsFromSpaces(at: .feedback)
    }
}

extension Motion {
    /// About in and out: a pushed page's slide, no give.
    static let about = spring("about", response: 0.35)
}

// MARK: - the layer

struct AboutLayer: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = AboutModel.shared
        if model.shown {
            AboutPage(model: model, app: app)
                .transition(.move(edge: .trailing))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("about")
        }
    }
}

private struct AboutPage: View {
    let model: AboutModel
    let app: AppModel
    @Environment(\.colorScheme) private var scheme

    private static let icon: CGFloat = 96

    var body: some View {
        // The layers stand under the status bar and the Island: the window's own insets.
        let insets = ApprovalScreen.insets
        ScrollView {
            VStack(spacing: 0) {
                icon
                    .padding(.top, insets.top + Metrics.touch + 12)
                Text("Yab")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(SettingsInk.text)
                    .padding(.top, 18)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("about.name")
                Text(AboutModel.version)
                    .font(.subheadline)
                    .foregroundStyle(SettingsInk.footer)
                    .monospacedDigit()
                    .padding(.top, 4)
                    .accessibilityIdentifier("about.version")
                Text(AboutModel.line)
                    .font(.footnote)
                    .foregroundStyle(SettingsInk.footer)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                    .padding(.horizontal, Metrics.Settings.heroSide)
                links
                    .padding(.top, 32)
                    .padding(.horizontal, Metrics.Settings.sectionInset)
                Text(AboutModel.copyright)
                    .font(.footnote)
                    .foregroundStyle(SettingsInk.section)
                    .padding(.top, 24)
                    .padding(.bottom, insets.bottom + 40)
                    .accessibilityIdentifier("about.copyright")
            }
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(SettingsInk.pageGround.ignoresSafeArea())
        .overlay(alignment: .topLeading) {
            // The app's one round sheet button, as Settings' and the chats' ‹.
            SheetHeadButton(glyph: .chevronLeft, label: "Back", id: "about.back") { model.close() }
                .padding(.leading, 16)
            .padding(.top, insets.top + 4)
        }
        .ignoresSafeArea(.container)
    }

    /// The icon on the Home Screen now, as the Mac shows its own.
    @ViewBuilder private var icon: some View {
        let side = Self.icon
        let current = PhoneAppIcon.current(UIApplication.shared.alternateIconName) ?? .flat
        Group {
            if let picture = current.picture(dark: scheme == .dark, installedName: UIApplication.shared.alternateIconName) {
                Image(uiImage: picture).resizable().interpolation(.high)
            } else {
                YabMark(size: side)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.225, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .accessibilityHidden(true)
    }

    private var links: some View {
        VStack(spacing: 0) {
            AboutLink(id: "website", title: "Website", first: true) { model.open(AboutModel.website, in: app) }
            AboutLink(id: "manual", title: "Manual") { model.open(AboutModel.manual, in: app) }
            AboutLink(id: "feedback", title: "Send Feedback", leaves: false) { model.feedback(in: app) }
            AboutLink(id: "community", title: "Join the Community on X") { model.open(AboutModel.community, in: app) }
        }
        .background(SettingsInk.group, in: RoundedRectangle(cornerRadius: Metrics.Settings.groupRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.Settings.groupRadius, style: .continuous))
    }
}

/// A row that is an errand, as Settings' rows: the whole row is the button;
/// the arrow says it opens a page, the chevron that it stays in Yab's own.
private struct AboutLink: View {
    let id: String
    let title: String
    var first = false
    var leaves = true
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var minHeight = Metrics.Settings.row

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.body).foregroundStyle(SettingsInk.text)
                Spacer(minLength: 8)
                Image(systemName: leaves ? "arrow.up.right" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsInk.chevron)
            }
            .padding(.horizontal, Metrics.Settings.rowPadding)
            .frame(minHeight: minHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowStyle())
        .overlay(alignment: .top) {
            if !first {
                Rectangle().fill(SettingsInk.hairline).frame(height: Metrics.Settings.hairline)
                    .padding(.leading, Metrics.Settings.rowPadding)
            }
        }
        .accessibilityIdentifier("about.\(id)")
    }
}

/// Yab's mark by the capsule, pressed: it dips a little, as a key does.
struct AboutMarkPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(Motion.disabled ? nil : .easeOut(duration: configuration.isPressed ? 0.08 : 0.16), value: configuration.isPressed)
    }
}
