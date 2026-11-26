import AppKit
import Testing
@testable import Fast

/// ColumnView.leaks leaves the pages laid over the column alone: their
/// layer is the one a PagerStage is the delegate of.
@MainActor
struct PagerLayerTests {
    private func picture() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    @Test func aPagerStagesLayerIsFoundAndOthersAreNot() throws {
        _ = NSApplication.shared
        let stage = PagerStage(band: CGRect(x: 0, y: 0, width: 40, height: 40), picture: try picture(), scale: 1)
        let plain = NSView(frame: .zero)
        plain.wantsLayer = true
        #expect(ColumnView.isPagerLayer(try #require(stage.layer)))
        #expect(!ColumnView.isPagerLayer(try #require(plain.layer)))
        #expect(!ColumnView.isPagerLayer(CALayer()))
    }
}
