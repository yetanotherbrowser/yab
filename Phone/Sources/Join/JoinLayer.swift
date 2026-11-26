import SwiftUI
import UIKit

/// Joining sync on this iPhone without an account: the key comes from
/// iCloud Keychain with no step at all; when it isn't there, a code to type
/// on a Mac (Settings › Sync › Add a Device), or the Recovery Key in one
/// field, and the words when the account turned this iPhone away. Settings'
/// join sheet holds these (Settings/SettingsLayer, JoinSheet): it grows out
/// of the welcome's Join Your Mac or the Sync row, rises by itself when a
/// launch has no key, comes back with Yab until this iPhone is in, and
/// pulls down by its head. The Mac's words (Settings › Sync).
struct JoinContent: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let sync = app.sync
        VStack(alignment: .leading, spacing: Metrics.Sync.sectionGap) {
            switch sync.phase {
            case let .joining(.code(code)): CodeSections(code: code)
            case let .joining(.recovery(wrong)): RecoverySections(wrong: wrong)
            case .joining(.scan): ScanSections()
            case let .joining(.invite(_, check)): InviteSections(check: check)
            case let .refused(why): RefusedSections(why: why)
            case .on: InSyncSections()
            case .off: WaitingWords()
            }
            if let why = sync.joinError {
                Text(why)
                    .font(.footnote)
                    .foregroundStyle(Ink.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("join.error")
                Button("Try Again") { sync.retryJoin() }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .glassCapsule()
                    .accessibilityIdentifier("join.retry")
            }
            if sync.phase == .on, sync.keySharingUnavailable {
                Text("Connected on this \(DeviceWord.name). iCloud Keychain could not share the key. You can still join another device with a code.")
                    .font(.footnote)
                    .foregroundStyle(SettingsInk.footer)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("join.sharingUnavailable")
            }
        }
        .id(sync.phase)
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity))
    }
}

// MARK: - the code

/// The code a Mac types to let this iPhone in, and the other way in.
private struct CodeSections: View {
    @Environment(AppModel.self) private var app
    let code: String

    var body: some View {
        JoinSection("Join with a Code", foot: "On your Mac, open Settings › Sync and choose Add a Device, then type this code there.") {
            VStack(spacing: Metrics.Sync.codeWordsGap) {
                Text(code)
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold).monospacedDigit())
                    .tracking(Metrics.Sync.codeTracking)
                    .foregroundStyle(Ink.primary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("join.code")
                Text("Waiting for your Mac")
                    .font(.footnote)
                    .foregroundColor(SettingsInk.footer)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("join.waiting")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Metrics.Sync.codeTop)
            .padding(.bottom, Metrics.Sync.codeBottom)
        }
        // The other way round: the code the Mac shows, scanned or typed here.
        JoinSection(nil, foot: "Or on your Mac choose Add a Device, and scan the code it shows.") {
            JoinRow(.camera1, "Scan QR", id: "join.scan") { app.sync.showScanner(true) }
        }
        JoinSection(nil, foot: "A Mac on the same Apple ID shares the key through iCloud Keychain, and this \(DeviceWord.name) joins by itself.") {
            JoinRow(.key1, "Use the Recovery Key", id: "join.recovery") { app.sync.showRecovery(true) }
        }
    }
}

// MARK: - the Mac's code

/// Scan QR: the camera on the code a Mac shows (Settings › Sync › Add a
/// Device), or the same code typed; and the way back to this iPhone's code.
private struct ScanSections: View {
    @Environment(AppModel.self) private var app
    @State private var typed = ""
    @FocusState private var focused: Bool

    var body: some View {
        JoinSection("Scan Your Mac’s Code", foot: "On your Mac, open Settings › Sync and choose Add a Device. Only its code is read; nothing else on the screen is.") {
            JoinScanArea { scanned in app.sync.joinWithInvite(scanned) }
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.Join.scanner)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.Sync.groupRadius, style: .continuous))
                .accessibilityIdentifier("join.scanner")
        }
        JoinSection(nil, foot: "The eight letters and digits under the code, if the camera can’t read it.") {
            EmptyView()
        } field: {
            HStack(spacing: 0) {
                TextField("", text: $typed, prompt: Text("ABCD-EFGH").foregroundStyle(Ink.faint))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Ink.primary)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.join)
                    .focused($focused)
                    .onSubmit { app.sync.joinWithInvite(typed) }
                    .accessibilityIdentifier("join.macCode")
                Button { app.sync.joinWithInvite(typed) } label: {
                    Glyph(.arrowUp, size: Metrics.Sync.fieldButtonIcon, color: .white)
                        .frame(width: Metrics.Sync.fieldButton, height: Metrics.Sync.fieldButton)
                        .background(Circle().fill(typed.isEmpty ? AppearanceColors.color(0x3C3C43, 0x3A3A3C, alpha: 0.5) : AppearanceColors.color(0x1C1C1E, 0x3A3A3C)))
                }
                .buttonStyle(.plain)
                .disabled(typed.isEmpty)
                .accessibilityLabel("Join")
                .accessibilityIdentifier("join.macCodeGo")
            }
            .padding(.leading, Metrics.Sync.fieldLeading)
            .padding(.trailing, Metrics.Sync.fieldTrailing)
            .frame(minHeight: Metrics.Sync.fieldHeight)
            .glassPlate(RoundedRectangle(cornerRadius: Metrics.Sync.fieldHeight / 2, style: .continuous))
        }
        JoinSection(nil, foot: nil) {
            JoinRow(.macbook, "Show This \(DeviceWord.name)’s Code", id: "join.back") { app.sync.showScanner(false) }
        }
    }
}

/// Joining by the Mac's code: the four digits worked out from this iPhone's
/// key, which the Mac shows too and asks about before it lets this iPhone in.
private struct InviteSections: View {
    @Environment(AppModel.self) private var app
    let check: String

    var body: some View {
        JoinSection("Check Your Mac", foot: "Your Mac asks whether this \(DeviceWord.name) shows these digits. If they match, choose Let In there.") {
            VStack(spacing: Metrics.Sync.codeWordsGap) {
                Text(check.map(String.init).joined(separator: " "))
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold).monospacedDigit())
                    .tracking(Metrics.Sync.codeTracking)
                    .foregroundStyle(Ink.primary)
                    .accessibilityLabel(check.map(String.init).joined(separator: " "))
                    .accessibilityIdentifier("join.check")
                Text("Waiting for your Mac")
                    .font(.footnote)
                    .foregroundColor(SettingsInk.footer)
                    .accessibilityIdentifier("join.waiting")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Metrics.Sync.codeTop)
            .padding(.bottom, Metrics.Sync.codeBottom)
        }
        JoinSection(nil, foot: nil) {
            JoinRow(.macbook, "Show This \(DeviceWord.name)’s Code", id: "join.back") { app.sync.showScanner(false) }
        }
    }
}

// MARK: - the Recovery Key

/// One field for the Recovery Key, and the way back to the code.
private struct RecoverySections: View {
    @Environment(AppModel.self) private var app
    let wrong: Bool
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var sync = app.sync
        JoinSection("Use the Recovery Key",
                    foot: wrong ? "That isn't a Recovery Key. Check each group of four." : "The key Yab showed when sync was first turned on.",
                    footColor: wrong ? Ink.warn : nil) {
            EmptyView()
        } field: {
            // The whole key in sight while it is typed: the field grows to
            // three lines (55 characters in groups of four), the way the
            // app's field grows with words.
            HStack(alignment: .bottom, spacing: 0) {
                TextField("", text: $sync.typed, prompt: Text("XXXX-XXXX-…").foregroundStyle(Ink.faint), axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    // Room for a fourth line: a field held to exactly the
                    // lines it shows scrolls its first one out of sight.
                    .lineLimit(1...4)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(Ink.primary)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.join)
                    .focused($focused)
                    .padding(.vertical, Metrics.Sync.fieldTextInset)
                    .onChange(of: sync.typed) { _, now in
                        // Return in a field of several lines types a new line: here it joins.
                        guard now.contains("\n") else { return }
                        sync.typed = now.replacingOccurrences(of: "\n", with: "")
                        app.sync.useRecovery(sync.typed)
                    }
                    .onSubmit { app.sync.useRecovery(sync.typed) }
                    .accessibilityIdentifier("join.field")
                Button { app.sync.useRecovery(sync.typed) } label: {
                    Glyph(.arrowUp, size: Metrics.Sync.fieldButtonIcon, color: .white)
                        .frame(width: Metrics.Sync.fieldButton, height: Metrics.Sync.fieldButton)
                        .background(Circle().fill(sync.typed.isEmpty ? AppearanceColors.color(0x3C3C43, 0x3A3A3C, alpha: 0.5) : AppearanceColors.color(0x1C1C1E, 0x3A3A3C)))
                }
                .buttonStyle(.plain)
                .disabled(sync.typed.isEmpty)
                .padding(.bottom, (Metrics.Sync.fieldHeight - Metrics.Sync.fieldButton) / 2)
                .accessibilityLabel("Join")
                .accessibilityIdentifier("join.go")
            }
            .padding(.leading, Metrics.Sync.fieldLeading)
            .padding(.trailing, Metrics.Sync.fieldTrailing)
            .frame(minHeight: Metrics.Sync.fieldHeight)
            .glassPlate(RoundedRectangle(cornerRadius: Metrics.Sync.fieldHeight / 2, style: .continuous))
            // The field takes the keyboard the moment it is there (a beat
            // after, or SwiftUI may drop a focus asked for before the field
            // is in the window).
            .task {
                try? await Task.sleep(for: .milliseconds(60))
                focused = true
            }
        }
        JoinSection(nil, foot: nil) {
            JoinRow(.macbook, "Join with a Code", id: "join.back") { app.sync.showRecovery(false) }
        }
    }
}

// MARK: - turned away

/// The account doesn't take this iPhone any more: why, and joining again.
private struct RefusedSections: View {
    @Environment(AppModel.self) private var app
    let why: String

    var body: some View {
        JoinSection(nil, foot: "Joining again takes a code from your Mac or the Recovery Key. What is on this \(DeviceWord.name) stays as it is.") {
            HStack(spacing: Metrics.Sync.rowGap) {
                JoinIcon(.macbook)
                Text(why)
                    .font(.callout)
                    .foregroundStyle(Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("join.words")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.Sync.rowPadding)
            .padding(.vertical, 10)
            .frame(minHeight: Metrics.Sync.rowHeight)
        }
        Button { app.sync.joinAgain() } label: {
            Text("Join Again")
                .font(.headline)
                .foregroundStyle(Ink.primary)
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.Sync.button)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassCapsule()
        .accessibilityIdentifier("join.again")
    }
}

// MARK: - in sync, or nothing yet

/// In already (the Sync row of a joined iPhone): with which Mac, and how
/// this iPhone leaves.
private struct InSyncSections: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        JoinSection(nil, foot: "Tabs, chats and tasks sync end to end encrypted: Yab can’t read them. To take this \(DeviceWord.name) out, remove it in Settings › Sync on your Mac.") {
            HStack(spacing: Metrics.Sync.rowGap) {
                JoinIcon(.macbook)
                Text("In sync with \(app.macName)")
                    .font(.callout)
                    .foregroundStyle(Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("join.words")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.Sync.rowPadding)
            .padding(.vertical, 10)
            .frame(minHeight: Metrics.Sync.rowHeight)
        }
    }
}

/// No code yet: where a Mac adds this iPhone.
private struct WaitingWords: View {
    var body: some View {
        VStack(spacing: 16) {
            Glyph(.macbook, size: Metrics.Join.glyph, color: SettingsInk.text)
                .frame(width: Metrics.Join.plate, height: Metrics.Join.plate)
                .background(SettingsInk.group, in: Circle())
            Text("In Yab on your Mac, open Settings › Sync and choose Add a Device.")
                .font(.callout)
                .foregroundStyle(SettingsInk.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("join.words")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Metrics.Join.top - Metrics.Sync.bodyTop)
        .padding(.horizontal, Metrics.Join.side - Metrics.Sync.bodyInset)
    }
}

// MARK: - Settings' parts

/// A section: its title in small capitals, a white group, words under it.
private struct JoinSection<Content: View, Field: View>: View {
    let title: String?
    let foot: String?
    var footColor: Color?
    @ViewBuilder let content: Content
    @ViewBuilder let field: Field

    init(_ title: String?, foot: String?, footColor: Color? = nil, @ViewBuilder content: () -> Content,
         @ViewBuilder field: () -> Field = { EmptyView() }) {
        self.title = title
        self.foot = foot
        self.footColor = footColor
        self.content = content()
        self.field = field()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                JoinSectionTitle(words: title.uppercased(),
                                 identifier: title == "Join with a Code" ? "join.codeLabel" : "join.section")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metrics.Sync.footInset)
                    .padding(.bottom, 6)
            }
            if Content.self != EmptyView.self {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Metrics.Sync.groupRadius, style: .continuous).fill(SettingsInk.group))
            }
            field
            if let foot {
                Text(foot)
                    .font(.footnote)
                    .lineSpacing(Metrics.Sync.footLineSpacing)
                    .foregroundColor(footColor ?? SettingsInk.footer)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metrics.Sync.footInset)
                    .padding(.top, Metrics.Sync.footTop)
                    .accessibilityIdentifier("join.foot")
            }
        }
    }
}

/// A real native heading whose measured line box, drawn text and spoken
/// header are one element. Round its complete line box, not an outer frame.
private struct JoinSectionTitle: UIViewRepresentable {
    let words: String
    let identifier: String

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.adjustsFontForContentSizeCategory = true
        label.isAccessibilityElement = true
        label.accessibilityTraits = [.staticText, .header]
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        let traits = UITraitCollection(preferredContentSizeCategory: category(context.environment.dynamicTypeSize))
        let base = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits)
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold.rawValue],
        ])
        let font = UIFont(descriptor: descriptor, size: base.pointSize)
        let color = UIColor(SettingsInk.section)
        label.font = font
        label.textColor = color
        label.backgroundColor = UIColor(SettingsInk.pageGround)
        label.attributedText = NSAttributedString(string: words, attributes: [
            .font: font, .foregroundColor: color, .kern: 0.36,
        ])
        label.accessibilityLabel = words
        label.accessibilityIdentifier = identifier
        label.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? .greatestFiniteMagnitude)
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: min(width, ceil(size.width)), height: ceil(max(size.height, uiView.font.lineHeight)))
    }

    private func category(_ size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}

/// A Settings row: icon box, words, chevron.
private struct JoinRow: View {
    let glyph: GlyphName
    let title: String
    let id: String
    let action: () -> Void

    @ScaledMetric(relativeTo: .callout) private var rowHeight = Metrics.Sync.rowHeight

    init(_ glyph: GlyphName, _ title: String, id: String, action: @escaping () -> Void) {
        self.glyph = glyph
        self.title = title
        self.id = id
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.Sync.rowGap) {
                JoinIcon(glyph)
                Text(title)
                    .font(.callout)
                    .foregroundColor(SettingsInk.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Glyph(.chevronRight, size: Metrics.Sync.chevron, color: Ink.chevron)
            }
            .padding(.horizontal, Metrics.Sync.rowPadding)
            .frame(minHeight: rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(SettingsInk.text)
        .accessibilityIdentifier(id)
    }
}

private struct JoinIcon: View {
    let glyph: GlyphName
    init(_ glyph: GlyphName) { self.glyph = glyph }

    var body: some View {
        Glyph(glyph, size: Metrics.Sync.icon, color: Ink.primary)
            .frame(width: Metrics.Sync.iconBox, height: Metrics.Sync.iconBox)
            .background(RoundedRectangle(cornerRadius: Metrics.Sync.iconBoxRadius, style: .continuous).fill(Ink.iconBox))
    }
}
