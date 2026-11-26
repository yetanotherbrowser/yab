import Foundation
import LocalAuthentication
import Observation

enum PrivateAuthenticationResult: Equatable, Sendable {
    case unlocked
    case cancelled
    case unavailable
    case failed
}

@MainActor
protocol PrivateAuthenticating: AnyObject {
    func authenticate(_ completion: @escaping @MainActor (PrivateAuthenticationResult) -> Void)
    func invalidate()
}

/// A separate context per attempt, unrelated to task signing or saved keys.
@MainActor
final class DevicePrivateAuthentication: PrivateAuthenticating {
    private var context: LAContext?

    func authenticate(_ completion: @escaping @MainActor (PrivateAuthenticationResult) -> Void) {
        invalidate()
        let context = LAContext()
        self.context = context
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            invalidate()
            completion(.unavailable)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your private tabs") { success, error in
            let result: PrivateAuthenticationResult
            if success { result = .unlocked }
            else if let error = error as? LAError,
                    [.userCancel, .appCancel, .systemCancel].contains(error.code) { result = .cancelled }
            else { result = .failed }
            Task { @MainActor in completion(result) }
        }
    }

    func invalidate() {
        context?.invalidate()
        context = nil
    }
}

/// The permission lasts only while Private is being used in this foreground.
/// Neither the grant, a pending operation nor private tab data is serialized.
@MainActor
@Observable
final class PrivateLock {
    enum Phase: Equatable {
        case locked, authenticating, unlocked
        case failed(String)
    }

    private(set) var phase: Phase = .locked
    private(set) var isActive = true
    private(set) var promptPresented = false
    private var observedEnabled: Bool
    @ObservationIgnored private let enabled: @MainActor () -> Bool
    @ObservationIgnored private let authentication: any PrivateAuthenticating
    @ObservationIgnored private var attempt: UUID?
    private var successfulAttempt: UUID?
    @ObservationIgnored private var pending: (@MainActor () -> Void)?

    init(enabled: @escaping @MainActor () -> Bool,
         authentication: any PrivateAuthenticating) {
        self.enabled = enabled
        self.authentication = authentication
        observedEnabled = enabled()
        observePreference()
    }

    var requiresAuthentication: Bool { enabled() }

    var mayReveal: Bool {
        guard isActive else { return false }
        guard requiresAuthentication else { return true }
        // Enabling the setting hides content before its observation callback.
        return observedEnabled && phase == .unlocked
    }

    var presentsPrompt: Bool { requiresAuthentication && promptPresented }

    /// The device said yes. Under its own sheet the scene is inactive until
    /// the sheet is gone, and until then mayReveal stays false: nothing
    /// private is drawn. A lock opening shows no tab, so it may start now.
    var isVerified: Bool { successfulAttempt != nil || phase == .unlocked }

    func request(_ action: @escaping @MainActor () -> Void) {
        preferenceChanged()
        if mayReveal { action(); return }
        retireAttempt()
        pending = action
        promptPresented = true
        phase = .locked
        if isActive { unlock() }
    }

    func unlock() {
        preferenceChanged()
        guard isActive, requiresAuthentication, phase != .authenticating else { return }
        retireAttempt()
        let id = UUID()
        attempt = id
        promptPresented = true
        phase = .authenticating
        authentication.authenticate { [weak self] result in self?.received(result, for: id) }
    }

    /// Unlocks from Private's own page on New Tab: the same device
    /// authentication, without the full-screen cover (no prompt is presented
    /// by the app; the page shows the lock and its words).
    func unlockInPlace(_ action: @escaping @MainActor () -> Void) {
        preferenceChanged()
        if mayReveal { action(); return }
        guard isActive, requiresAuthentication, phase != .authenticating else { return }
        retireAttempt()
        pending = action
        let id = UUID()
        attempt = id
        phase = .authenticating
        authentication.authenticate { [weak self] result in self?.received(result, for: id) }
    }

    func leavePrivate() { lock() }

    func cancel() { lock() }

    func willResignActive() {
        isActive = false
        // LocalAuthentication itself makes the scene inactive. Keep that
        // attempt, but never reveal its result until the scene is active.
        if phase != .authenticating { lock() }
    }

    func didEnterBackground() {
        isActive = false
        lock()
    }

    func didBecomeActive() {
        isActive = true
        preferenceChanged()
        // An external link may arrive before the scene is active. With
        // authentication off, no authentication callback will run its action.
        if !requiresAuthentication, let action = pending {
            pending = nil
            promptPresented = false
            action()
        }
        if let id = successfulAttempt { received(.unlocked, for: id) }
    }

    func preferenceChanged() {
        let current = requiresAuthentication
        guard current != observedEnabled else { return }
        observedEnabled = current
        lock()
    }

    private func lock() {
        retireAttempt()
        pending = nil
        promptPresented = false
        phase = .locked
    }

    private func retireAttempt() {
        // Retire the generation before invalidate can call back.
        attempt = nil
        successfulAttempt = nil
        authentication.invalidate()
    }

    private func received(_ result: PrivateAuthenticationResult, for id: UUID) {
        guard attempt == id, observedEnabled, requiresAuthentication else { return }
        switch result {
        case .unlocked:
            guard isActive else { successfulAttempt = id; return }
            let action = pending
            pending = nil
            retireAttempt()
            phase = .unlocked
            promptPresented = false
            action?()
        case .cancelled:
            retireAttempt()
            phase = .failed("Private is still locked.")
        case .unavailable:
            retireAttempt()
            phase = .failed("Set a device passcode in \(DeviceWord.name) Settings to unlock Private.")
        case .failed:
            retireAttempt()
            Haptics.play(.error, reason: Haptics.Reason.unlockFailed)
            phase = .failed("Could not unlock Private. Try again, or return to your other space.")
        }
    }

    private func observePreference() {
        withObservationTracking { _ = enabled() } onChange: { [weak self] in
            Task { @MainActor in
                self?.preferenceChanged()
                self?.observePreference()
            }
        }
    }

    /// An explicit isolated DEBUG launch only. A normal launch, even under
    /// XCTest, still uses the device's real LocalAuthentication policy.
    static func testingConfiguration(profileDirectory: String?,
                                     arguments: [String] = ProcessInfo.processInfo.arguments)
        -> (authentication: (any PrivateAuthenticating)?, enabled: Bool?) {
        #if DEBUG
        guard let profileDirectory,
              let index = arguments.firstIndex(of: "-YabPrivateLockTestAuthentication"),
              index + 1 < arguments.count else { return (nil, nil) }
        let path = URL(fileURLWithPath: profileDirectory).standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/")
            || path.hasPrefix(FileManager.default.temporaryDirectory.path) else { return (nil, nil) }
        let values = arguments[index + 1].split(separator: ",").map(String.init)
        if values == ["off"] { return (nil, false) }
        let results = values.compactMap { value -> PrivateAuthenticationResult? in
            switch value {
            case "allow": .unlocked
            case "cancel": .cancelled
            case "unavailable": .unavailable
            case "fail": .failed
            default: nil
            }
        }
        guard !results.isEmpty, results.count == values.count else { return (nil, nil) }
        return (TestPrivateAuthentication(results: results), true)
        #else
        return (nil, nil)
        #endif
    }
}

#if DEBUG
@MainActor
private final class TestPrivateAuthentication: PrivateAuthenticating {
    private var results: [PrivateAuthenticationResult]
    init(results: [PrivateAuthenticationResult]) { self.results = results }
    func authenticate(_ completion: @escaping @MainActor (PrivateAuthenticationResult) -> Void) {
        let result = results.count > 1 ? results.removeFirst() : results[0]
        completion(result)
    }
    func invalidate() {}
}
#endif
