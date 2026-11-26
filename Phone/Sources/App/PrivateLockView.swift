import SwiftUI
import UIKit

/// An opaque screen contains no thumbnail, URL, favicon or private words.
struct PrivateLockView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 20) {
            Glyph(.incognito, size: 42, color: .white)
                .accessibilityHidden(true)
            Text("Private is Locked")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
            Button("Unlock Private") { app.privateLock.unlock() }
                .font(.headline)
                .frame(minWidth: 160, minHeight: Metrics.touch)
                .foregroundStyle(.black)
                .buttonStyle(.borderedProminent)
                .disabled(app.privateLock.phase == .authenticating || !app.privateLock.isActive)
                .accessibilityIdentifier("private.unlock")
            Button("Back to Other Tabs") { app.leaveLockedPrivate() }
                .font(.body)
                .frame(minWidth: 160, minHeight: Metrics.touch)
                .accessibilityIdentifier("private.back")
        }
        .padding(24)
        .foregroundStyle(.white)
        .tint(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("private.lock")
        .transaction { $0.animation = nil }
        .onAppear {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    private var message: String {
        switch app.privateLock.phase {
        case .authenticating: "Unlocking with your \(DeviceWord.name)."
        case let .failed(message): message
        default: "Unlock with Face ID, Touch ID or your device passcode. Your private tabs stay on this \(DeviceWord.name)."
        }
    }
}
