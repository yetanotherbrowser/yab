import SwiftUI

/// The sheets that come for the person: the code a site sent to this
/// iPhone, and the yes with its facts and Face ID. Each grows out of what
/// summoned it (the Now line, a Lock Screen button, the Island) in 0.34 s,
/// its words a little later, and goes back there in 0.26 s; with no origin
/// it rises from the bottom. A tap on the dimmed page closes it.
struct PersonSheetLayer: View {
    @Environment(AppModel.self) private var app
    let sheet: TaskDesk.PersonSheet

    var body: some View {
        let desk = app.taskDesk
        let grown = desk.sheetGrowth
        ZStack(alignment: .bottom) {
            Color.black
                .opacity(Metrics.CodeSheet.scrim * Double(grown))
                .contentShape(Rectangle())
                .onTapGesture { desk.closeSheet() }
                .accessibilityHidden(true)
            Group {
                switch sheet {
                case let .code(id):
                    CodeSheet(id: id, growth: grown, origin: desk.sheetOrigin, leaving: desk.sheetLeaving)
                case let .yes(id):
                    ConsentSheet(id: id, growth: grown, origin: desk.sheetOrigin, leaving: desk.sheetLeaving)
                }
            }
            // VoiceOver stays in the sheet, and the two-finger scrub closes it
            // as a tap on the dimmed page does.
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) { desk.closeSheet() }
        }
        .ignoresSafeArea()
    }
}

/// Grows a sheet out of a rect: its shape clipped from the origin's rect
/// (in screen points) to its own, its corner from the origin's to its own;
/// with no origin, it rises from 105% below, and goes down 60% with a fade.
struct GrowFromOrigin: ViewModifier, Animatable {
    var growth: CGFloat
    let origin: TaskDesk.Origin?
    let radius: CGFloat
    /// Where the sheet stands when grown, in screen points.
    let frame: CGRect
    /// Going away with nothing to go back into.
    var leaving = false

    var animatableData: CGFloat {
        get { growth }
        set { growth = newValue }
    }

    func body(content: Content) -> some View {
        let g = min(max(growth, 0), 1)
        // Not laid out yet: nothing to show before the sheet knows where it stands.
        let unplaced = frame == .zero && g < 1
        // Reduce Motion: in place, a short cross-fade instead of the growing.
        if Motion.reduced {
            content.opacity(unplaced ? 0 : Double(g))
        } else {
            Group {
                grown(content, g)
            }
            .opacity(unplaced ? 0 : 1)
        }
    }

    @ViewBuilder
    private func grown(_ content: Content, _ g: CGFloat) -> some View {
        if let origin {
            let local = origin.rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
            let bounds = CGRect(origin: .zero, size: frame.size)
            let rect = CGRect(x: local.minX + (bounds.minX - local.minX) * g, y: local.minY + (bounds.minY - local.minY) * g,
                              width: local.width + (bounds.width - local.width) * g, height: local.height + (bounds.height - local.height) * g)
            let r = origin.radius + (radius - origin.radius) * g
            content
                .mask {
                    RoundedRectangle(cornerRadius: r, style: .continuous)
                        .frame(width: max(rect.width, 0), height: max(rect.height, 0))
                        .position(x: rect.midX, y: rect.midY)
                }
        } else if leaving {
            content
                .offset(y: (1 - g) * frame.height * Metrics.CodeSheet.dropDistance)
                .opacity(Double(g))
        } else {
            content.offset(y: (1 - g) * frame.height * Metrics.CodeSheet.riseDistance)
        }
    }
}

/// Its words come after the shape: up 8 points and in, as the sheet grows.
private struct SheetWords: ViewModifier, Animatable {
    var growth: CGFloat

    var animatableData: CGFloat {
        get { growth }
        set { growth = newValue }
    }

    func body(content: Content) -> some View {
        // The words wait for a quarter of the growth, the prototype's 90 ms of 340.
        let t = min(max((growth - 0.26) / 0.65, 0), 1)
        content.opacity(t).offset(y: (1 - t) * 8)
    }
}

// MARK: - the code

/// TAP sent a code to this iPhone (yes.1, yes.2): six boxes over the number
/// pad; the system's QuickType offers the code from Messages (a field with
/// the one-time-code content type), one touch fills the boxes, and 0.45 s
/// later the code goes to the Mac and the sheet back into the line.
struct CodeSheet: View {
    @Environment(AppModel.self) private var app
    let id: TaskRun.ID
    let growth: CGFloat
    let origin: TaskDesk.Origin?
    var leaving = false
    @State private var code = ""
    @FocusState private var focused: Bool
    @State private var keyboard = KeyboardWatch.shared
    @State private var sent = false

    private typealias C = Metrics.Code
    private typealias K = Metrics.CodeSheet

    var body: some View {
        GeometryReader { geo in
            let desk = app.taskDesk
            let request = desk.codes[id] ?? desk.virtualMac?.script.script(id).code
            let picture = desk.pictureCode
            // On the system's number pad; in pictures, on the prototype's drawing of it.
            let pad = picture != nil ? C.pad : keyboard.height
            let width = geo.size.width - K.side * 2
            ZStack(alignment: .bottom) {
                sheet(request: request, picture: picture)
                    .frame(width: width)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sheetFrame = $0 }
                    .modifier(GrowFromOrigin(growth: growth, origin: origin, radius: C.radius, frame: sheetFrame, leaving: leaving))
                    .padding(.bottom, pad + K.side)
                if picture != nil {
                    CodePadPicture(code: request.map { _ in desk.virtualMac?.script.script(id).expectedCode ?? "" } ?? "")
                        .offset(y: (1 - growth) * C.pad)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .ignoresSafeArea()
        .onAppear {
            if let picture = app.taskDesk.pictureCode { code = picture }
        }
        .task {
            // The keyboard comes up with the sheet (focus takes once the field is on screen).
            guard app.taskDesk.pictureCode == nil else { return }
            try? await Task.sleep(for: .milliseconds(80))
            focused = true
        }
    }

    @State private var sheetFrame: CGRect = .zero

    private func sheet(request: CodeRequest?, picture: String?) -> some View {
        let def = app.tasks.definition(id)
        return VStack(alignment: .leading, spacing: K.gap) {
            Capsule()
                .fill(TaskInk.grabber)
                .frame(width: Metrics.Column.grabWidth, height: Metrics.Column.grabHeight)
                .frame(maxWidth: .infinity)
                .padding(.top, K.grabTop)
                .padding(.bottom, K.grabBottom)
            Group {
                SheetHead(icon: request?.icon ?? def?.icon ?? "tap", title: request?.title ?? "A code for your Mac",
                          line: request?.line(task: def?.name) ?? "Your Mac is signing in",
                          warning: app.taskDesk.refused.contains(id) ? "That code didn’t work. Enter the newest one." : nil)
                boxes(length: request?.length ?? 6, picture: picture != nil)
                NoteRow(glyph: .lock, text: "The code goes to your Mac, encrypted, and nowhere else.")
            }
            .modifier(SheetWords(growth: growth))
        }
        .padding(.horizontal, K.padding)
        .padding(.bottom, K.bottomPadding)
        .background(Ink.surface.opacity(K.white), in: RoundedRectangle(cornerRadius: C.radius, style: .continuous))
        .shadow(color: Ink.shadow.opacity(K.shadow), radius: K.shadowRadius, y: K.shadowY)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task.code")
    }

    private func boxes(length: Int, picture: Bool) -> some View {
        let digits = Array(code.filter(\.isNumber).prefix(length))
        return HStack(spacing: C.boxGap) {
            ForEach(0..<length, id: \.self) { i in
                Text(i < digits.count ? String(digits[i]) : "")
                    .font(.system(size: C.digit, weight: .semibold))
                    .tracking(-0.01 * C.digit)
                    .foregroundStyle(Ink.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: C.box)
                    .background(TaskInk.box, in: RoundedRectangle(cornerRadius: C.boxRadius, style: .continuous))
            }
        }
        .overlay {
            // The field the keyboard types into, and QuickType fills: the boxes show it.
            if !picture {
                TextField("", text: $code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .focused($focused)
                    .foregroundStyle(.clear)
                    .tint(.clear)
                    .accessibilityIdentifier("task.code.field")
                    .accessibilityLabel("Code")
                    .onChange(of: code) { _, typed in
                        let digits = typed.filter(\.isNumber)
                        if digits.count > length { code = String(digits.prefix(length)) }
                        guard digits.count >= length, !sent else { return }
                        sent = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(Metrics.CodeSheet.settles))
                            focused = false
                            app.taskDesk.giveCode(id, code: String(digits.prefix(length)))
                            app.taskDesk.closeSheet()
                        }
                    }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task.code.boxes")
    }
}

/// The head of a sheet for the person: the site's icon 30, a title 18, its line.
struct SheetHead: View {
    let icon: String
    let title: String
    let line: String
    /// Said in orange in place of the line: the code the site didn't take.
    var warning: String? = nil

    var body: some View {
        HStack(spacing: Metrics.CodeSheet.headGap) {
            Favicon(icon: icon, size: Metrics.Code.headIcon)
            VStack(alignment: .leading, spacing: Metrics.CodeSheet.titleGap) {
                Text(title)
                    .font(.system(size: Metrics.Code.headTitle, weight: .semibold))
                    .tracking(-0.02 * Metrics.Code.headTitle)
                    .foregroundStyle(Ink.primary)
                    .lineHeight(1.2, size: Metrics.Code.headTitle)
                    .fixedSize(horizontal: false, vertical: true)
                Text(warning ?? line)
                    .font(.system(size: Metrics.Code.headLine, weight: warning == nil ? .regular : .semibold))
                    .tracking(-0.01 * Metrics.Code.headLine)
                    .foregroundStyle(warning == nil ? Ink.tertiary : TaskInk.needs)
                    .lineHeight(1.3, size: Metrics.Code.headLine)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("task.sheet.head")
    }
}

/// A quiet note: a glyph 15 and words 13, gray.
struct NoteRow: View {
    let glyph: GlyphName
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.CodeSheet.noteGap) {
            Glyph(glyph, size: Metrics.CodeSheet.noteIcon, color: TaskInk.quiet)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: Metrics.CodeSheet.noteFont))
                .tracking(-0.01 * Metrics.CodeSheet.noteFont)
                .foregroundStyle(Ink.secondary)
                .lineHeight(1.4, size: Metrics.CodeSheet.noteFont)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("task.sheet.note")
    }
}

/// The system's number pad as the prototype draws it, QuickType offering
/// the code from Messages: pictures only (named states yes.1, yes.2). A
/// simulator can't receive the SMS, so its own QuickType has nothing to
/// offer; the live sheet stands on the real keyboard.
struct CodePadPicture: View {
    let code: String

    private typealias C = Metrics.Code
    private typealias K = Metrics.CodeSheet

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                Text("From Messages")
                    .font(.system(size: K.quickTypeLabel))
                    .tracking(-0.01 * K.quickTypeLabel)
                    .foregroundStyle(Ink.secondary)
                Text(spaced)
                    .font(.system(size: K.quickTypeCode, weight: .semibold))
                    .tracking(0.04 * K.quickTypeCode)
                    .foregroundStyle(Ink.black)
            }
            .frame(maxWidth: .infinity)
            .frame(height: C.quickType)
            .overlay(alignment: .bottom) { Rectangle().fill(Ink.outline.opacity(0.08)).frame(height: K.hairline) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: C.keyGap), count: 3), spacing: C.keyGap) {
                ForEach(Self.keys, id: \.self) { key in
                    keyView(key)
                }
            }
            .padding(.horizontal, K.padSide)
            .padding(.top, K.padTop)
            Spacer(minLength: 0)
        }
        .frame(height: C.pad)
        .background(TaskInk.pad)
        .accessibilityHidden(true)
    }

    private var spaced: String {
        guard code.count == 6 else { return code }
        return String(code.prefix(3)) + " " + String(code.suffix(3))
    }

    static let keys = ["1", "2 ABC", "3 DEF", "4 GHI", "5 JKL", "6 MNO", "7 PQRS", "8 TUV", "9 WXYZ", "", "0", "⌫"]

    @ViewBuilder
    private func keyView(_ key: String) -> some View {
        let parts = key.split(separator: " ").map(String.init)
        if key.isEmpty {
            Color.clear.frame(height: C.key)
        } else {
            VStack(spacing: 1) {
                Text(parts[0])
                    .font(.system(size: C.keyDigit))
                    .tracking(-0.01 * C.keyDigit)
                    .foregroundStyle(Ink.black)
                if parts.count > 1 {
                    Text(parts[1])
                        .font(.system(size: K.keyLetters, weight: .semibold))
                        .tracking(0.12 * K.keyLetters)
                        .foregroundStyle(Ink.black)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: C.key)
            .background(Ink.card, in: RoundedRectangle(cornerRadius: C.keyRadius, style: .continuous))
            .shadow(color: Ink.shadow.opacity(0.3), radius: 0, y: 1)
        }
    }
}

// MARK: - the yes

/// Pay €238.00 to TAP Air Portugal? (yes.3): the facts Yab read from the
/// page on the Mac, why it is asked here, Pay with Face ID and Not Now.
struct ConsentSheet: View {
    @Environment(AppModel.self) private var app
    let id: TaskRun.ID
    let growth: CGFloat
    let origin: TaskDesk.Origin?
    var leaving = false
    @State private var sheetFrame: CGRect = .zero

    private typealias Y = Metrics.ConsentSheet

    var body: some View {
        GeometryReader { geo in
            let desk = app.taskDesk
            let request = desk.yeses[id] ?? desk.virtualMac?.script.script(id).yes
            let idle = desk.virtualMac?.script.idleMinutes ?? 12
            content(request: request, idle: idle)
                .frame(width: geo.size.width - Y.side * 2)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sheetFrame = $0 }
                .modifier(GrowFromOrigin(growth: growth, origin: origin, radius: Y.radius, frame: sheetFrame, leaving: leaving))
                .padding(.bottom, Y.bottom)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .ignoresSafeArea()
    }

    private func content(request: YesRequest?, idle: Int) -> some View {
        VStack(alignment: .leading, spacing: Y.gap) {
            Capsule()
                .fill(TaskInk.grabber)
                .frame(width: Metrics.Column.grabWidth, height: Metrics.Column.grabHeight)
                .frame(maxWidth: .infinity)
                .padding(.top, Y.grabTop)
                .padding(.bottom, Y.grabBottom)
            Group {
                SheetHead(icon: request?.icon ?? "tap", title: request?.title ?? "Go on?", line: request?.subtitle ?? "")
                facts(request?.facts ?? [])
                NoteRow(glyph: .shieldCheck, text: "Asked on this \(DeviceWord.name): your Mac has been idle for \(idle) min. Face ID signs this exact \(request?.noun ?? "payment"); your Mac checks the signature, then presses the site’s own button. Claude can’t press it.")
                Button {
                    Task { await app.taskDesk.approve(id) }
                } label: {
                    HStack(spacing: Y.payGap) {
                        Glyph(.faceId, size: Y.payIcon, color: .white)
                        Text(request?.button ?? "Approve with Face ID")
                            .font(.system(size: Y.payFont, weight: .semibold))
                            .tracking(-0.01 * Y.payFont)
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.Consent.pay)
                    .background(TaskInk.ink, in: RoundedRectangle(cornerRadius: Metrics.Consent.payRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                // One yes at a time: while Face ID looks, Pay waits.
                .disabled(app.taskDesk.signing)
                .accessibilityIdentifier("task.yes.pay")
                Button {
                    app.taskDesk.notNow(id)
                } label: {
                    Text("Not Now")
                        .font(.system(size: Y.notNowFont, weight: .medium))
                        .tracking(-0.01 * Y.notNowFont)
                        .foregroundStyle(Ink.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: Metrics.Consent.notNow)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("task.yes.notNow")
            }
            .modifier(SheetWords(growth: growth))
        }
        .padding(.horizontal, Y.padding)
        .padding(.bottom, Y.bottomPadding)
        .background(Ink.surface.opacity(Y.white), in: RoundedRectangle(cornerRadius: Y.radius, style: .continuous))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Y.radius, style: .continuous))
        .shadow(color: Ink.shadow.opacity(Y.shadow), radius: Y.shadowRadius, y: Y.shadowY)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task.yes")
    }

    /// Label and value, a 70-point label column, hairlines between.
    private func facts(_ rows: [[String]]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                HStack(alignment: .top, spacing: Y.factGap) {
                    Text(row.first ?? "")
                        .font(.system(size: Y.factFont))
                        .tracking(-0.01 * Y.factFont)
                        .foregroundStyle(Ink.tertiary)
                        .frame(width: Metrics.Consent.factsLabel, alignment: .leading)
                    Text(row.dropFirst().first ?? "")
                        .font(.system(size: Y.factFont, weight: .medium))
                        .tracking(-0.01 * Y.factFont)
                        .foregroundStyle(Ink.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .lineHeight(1.35, size: Y.factFont)
                .padding(Y.factPadding)
                .overlay(alignment: .bottom) {
                    if i < rows.count - 1 {
                        Rectangle().fill(TaskInk.hairline).frame(height: Y.hairline)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .background(TaskInk.facts, in: RoundedRectangle(cornerRadius: Metrics.Consent.factsRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task.yes.facts")
    }
}

/// Face ID, as the system shows it: a dark square, the glyph and the word;
/// signed, the glyph turns green and says so. Yab draws it after the
/// system's own panel has gone (Signed), and in pictures and stand-in runs.
struct FaceIDPanel: View {
    let state: TaskDesk.FaceIDState
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shouldPulse: Bool {
        state == .looking && !Motion.disabled && !Motion.reduced && !reduceMotion
    }

    var body: some View {
        VStack(spacing: Metrics.FaceIDPanel.gap) {
            Glyph(.faceId, size: Metrics.Consent.faceIDGlyph, color: state == .signed ? TaskInk.signed : .white)
                .opacity(state == .looking && pulse ? 0.55 : 1)
            Text(state == .signed ? "Signed" : "Face ID")
                .font(.system(size: Metrics.FaceIDPanel.word, weight: .medium))
                .tracking(-0.01 * Metrics.FaceIDPanel.word)
                .foregroundStyle(.white)
        }
        .frame(width: Metrics.Consent.faceID, height: Metrics.Consent.faceID)
        .background(TaskInk.faceID, in: RoundedRectangle(cornerRadius: Metrics.Consent.faceIDRadius, style: .continuous))
        // What is under it blurs away (backdrop blur 20).
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Metrics.Consent.faceIDRadius, style: .continuous))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("task.faceid")
        .onChange(of: shouldPulse, initial: true) { _, enabled in
            var transaction = Transaction(animation: enabled
                ? Motion.faceIDPulse.animation.repeatForever(autoreverses: true) : nil)
            transaction.disablesAnimations = !enabled
            withTransaction(transaction) { pulse = enabled }
        }
    }
}
