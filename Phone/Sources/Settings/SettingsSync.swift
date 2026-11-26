import LocalAuthentication
import SwiftUI
import UIKit
import UniformTypeIdentifiers
#if canImport(SyncKit)
import SyncKit
#endif

/// A device of the account as Settings › Sync lists it, in the Mac's words
/// (its Settings › Sync): the name, a Mac or an iPhone, and how it is.
struct SettingsDevice: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var isPhone: Bool
    var isThis: Bool
    /// "This iPhone", "Syncing now" or "Last synced 5 minutes ago".
    var words: String

    static let syncingNow = "Syncing now"

    /// The list, this iPhone first (as the engine sorts it), each in words.
    /// A Mac that is down says what it is doing instead (MacWords):
    /// "Asleep since 18:52", "Yab closed since Tue", "No word since 9:12".
    static func list(_ devices: [SyncDevice], own: String?, now: Date, macs: [SyncMac] = []) -> [SettingsDevice] {
        devices.map { device in
            let here = device.id == own
            let mac = macs.first { $0.id == device.id }
            let said = mac.flatMap { $0.state.isUp ? nil : MacWords.state($0.state, now: now) }
            return SettingsDevice(id: device.id, name: device.name.isEmpty ? (device.isPhone ? (device.model.hasPrefix("iPad") ? "iPad" : "iPhone") : "Mac") : device.name,
                                  isPhone: device.isPhone, isThis: here,
                                  words: here ? "This \(DeviceWord.name)" : said ?? words(lastSeen: device.lastSeen, now: now))
        }.sorted { ($0.isThis ? 0 : 1) < ($1.isThis ? 0 : 1) }
    }

    /// Up in the last two minutes, or when it last was, as the Mac says it.
    static func words(lastSeen: Date?, now: Date) -> String {
        guard let lastSeen else { return "Not synced yet" }
        if now.timeIntervalSince(lastSeen) < 120 { return syncingNow }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last synced " + formatter.localizedString(for: lastSeen, relativeTo: now)
    }
}

/// Turn Off Sync on This iPhone, asked first from its own row: iOS's sheet
/// with the red choice, a tap away from it to cancel.
struct SyncOffConfirmation: ViewModifier {
    @Environment(AppModel.self) private var app
    let asks: Bool

    func body(content: Content) -> some View {
        if asks {
            content.confirmationDialog("Turn Off Sync on This \(DeviceWord.name)?", isPresented: Binding(
                get: { SettingsUI.shared.confirmSyncOff },
                set: { SettingsUI.shared.confirmSyncOff = $0 }), titleVisibility: .visible) {
                Button("Turn Off Sync", role: .destructive) { app.sync.turnOff() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This \(DeviceWord.name) forgets the sync key and leaves your account. Its tabs and chats stay here; joining again takes a code from your Mac or the Recovery Key.")
            }
        } else {
            content
        }
    }
}

/// The Recovery Key behind Face ID: a context of its own per ask, nothing
/// kept after Settings closes (SettingsUI.recoveryShown).
@MainActor
enum SyncRecovery {
    /// How the person proves it is them; tests and named states stand in.
    static var authenticate: (@escaping @MainActor (Bool) -> Void) -> Void = { done in
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return done(false) }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Show your sync Recovery Key") { success, _ in
            Task { @MainActor in done(success) }
        }
    }

    /// Face ID (or the passcode), then the key on its page.
    static func reveal(_ app: AppModel) {
        guard let key = app.sync.recoveryKey else { return }
        authenticate { yes in
            guard yes else { return }
            SettingsUI.shared.recoveryShown = key
        }
    }

    /// On this iPhone's pasteboard only, for two minutes: never Universal
    /// Clipboard's way to another device.
    static func copy(_ app: AppModel) {
        guard let key = SettingsUI.shared.recoveryShown else { return }
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: key]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
        Haptics.play(.soft, reason: Haptics.Reason.copied)
        app.say("Recovery Key Copied", glyph: .key1)
    }
}
