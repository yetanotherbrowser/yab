import AVFoundation
import SwiftUI
import UIKit
import VisionKit
#if canImport(SyncKit)
import SyncKit
#endif

/// Scan QR's camera: VisionKit's data scanner (iOS's own camera view, its
/// guidance and highlight), QR codes only, taking the first that is a Mac's
/// code (JoinInvite) and nothing else. The camera is asked for only here,
/// as the person chose Scan QR; refused or missing (the simulator), the
/// words say so and the code can be typed under it.
struct JoinScanArea: View {
    let found: (String) -> Void
    @State private var access = JoinScanArea.access()

    enum Access: Equatable {
        case ready, asking, refused, unsupported
    }

    var body: some View {
        ZStack {
            Color.black
            switch access {
            case .ready:
                JoinScanner(found: found)
            case .asking:
                ProgressView().tint(.white)
            case .refused:
                words("Yab can’t use the camera. Allow it in iOS Settings › Apps › Yab, or type the code below.")
            case .unsupported:
                words("This \(DeviceWord.name)’s camera can’t scan here. Type the code your Mac shows below.")
            }
        }
        .task {
            guard access == .asking else { return }
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            access = granted && DataScannerViewController.isAvailable ? .ready : .refused
        }
    }

    private func words(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.white.opacity(0.8))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Metrics.Join.side)
            .accessibilityIdentifier("join.scanWords")
    }

    /// What the camera allows now, asked of iOS without a prompt.
    static func access() -> Access {
        guard DataScannerViewController.isSupported else { return .unsupported }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return DataScannerViewController.isAvailable ? .ready : .refused
        case .notDetermined: return .asking
        default: return .refused
        }
    }
}

/// The scanner itself, started once it is on screen and stopped as it goes.
struct JoinScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                                isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.found = found
        guard !scanner.isScanning, !context.coordinator.done else { return }
        // On screen by now; a scanner started off screen says so and stays dark.
        DispatchQueue.main.async { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var found: (String) -> Void
        /// A Mac's code was read: nothing more is.
        var done = false

        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            take(addedItems, from: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            take(updatedItems, from: dataScanner)
        }

        private func take(_ items: [RecognizedItem], from scanner: DataScannerViewController) {
            guard !done else { return }
            for item in items {
                guard case let .barcode(code) = item, let text = code.payloadStringValue, JoinInvite.code(scanned: text) != nil else { continue }
                done = true
                scanner.stopScanning()
                Haptics.play(.success, reason: Haptics.Reason.scanned)
                found(text)
                return
            }
        }
    }
}
