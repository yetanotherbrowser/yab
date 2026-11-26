import AppKit
import Testing
@testable import Fast

/// yab-mcp#7: screenshot's retina gives every pixel as PNG; the default
/// stays a 1024-wide JPEG, the size click's points are in.
struct AgentScreenshotRetinaTests {
    private func image(width: Int, height: Int) throws -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        return try #require(context.makeImage())
    }

    @Test func defaultStaysA1024WideJPEG() throws {
        let (data, wide, high) = try #require(Bench.encode(try image(width: 2560, height: 1600), width: 1024, png: false))
        #expect((wide, high) == (1024, 640))
        #expect(data.starts(with: [0xFF, 0xD8]))
    }

    @Test func retinaKeepsEveryPixelAsPNG() throws {
        let (data, wide, high) = try #require(Bench.encode(try image(width: 2560, height: 1600), width: nil, png: true))
        #expect((wide, high) == (2560, 1600))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    /// A 5K tab: the long side comes down to 2560, the same shape.
    @Test func retinaCapsTheLongSide() throws {
        let (data, wide, high) = try #require(Bench.encode(try image(width: 5120, height: 2880), width: nil, png: true))
        #expect((wide, high) == (2560, 1440))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let (_, tallWide, tallHigh) = try #require(Bench.encode(try image(width: 1600, height: 4000), width: nil, png: true))
        #expect((tallWide, tallHigh) == (1024, 2560))
    }

    /// Pixels that don't compress (a photo, noise) come down until the
    /// bytes fit the cap a client takes.
    @Test func retinaCapsTheBytes() throws {
        let (wide, high) = (2560, 1600)
        var pixels = [UInt8](repeating: 255, count: wide * high * 4)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in pixels.indices where i % 4 != 3 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            pixels[i] = UInt8(truncatingIfNeeded: seed >> 56)
        }
        let cg = try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: wide, height: high, bitsPerComponent: 8, bytesPerRow: wide * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            return try #require(context.makeImage())
        }
        let (data, gotWide, gotHigh) = try #require(Bench.encode(cg, width: nil, png: true))
        #expect(data.count <= Bench.retinaBytes, "\(data.count) bytes at \(gotWide)×\(gotHigh)")
        #expect(gotWide < wide && gotWide >= 1024)
        #expect(abs(Double(gotWide) / Double(gotHigh) - 1.6) < 0.01)
    }
}

/// No retina PNG past either cap, on any path: still too many bytes at the
/// least side, or a picture that couldn't be drawn smaller, is no picture.
struct AgentScreenshotRetinaBoundsTests {
    private func noise(width: Int, height: Int) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in pixels.indices where i % 4 != 3 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            pixels[i] = UInt8(truncatingIfNeeded: seed >> 56)
        }
        return try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                                 bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            return try #require(context.makeImage())
        }
    }

    /// At the least side the bytes still don't fit: no picture, not one
    /// past the cap.
    @Test func overTheBytesAtTheLeastSideIsNoPicture() throws {
        #expect(Bench.retina(try noise(width: 2000, height: 1250), bytes: 100_000) == nil)
        // A picture already at or under the least side gets no exemption.
        #expect(Bench.retina(try noise(width: 800, height: 500), bytes: 100_000) == nil)
    }

    /// Drawing smaller failed: the full-size picture used to go out instead.
    @Test func undrawableIsNoPicture() throws {
        let big = try noise(width: 3000, height: 1500)
        #expect(Bench.retina(big, draw: { _, _, _ in nil }) == nil)
        // A drawer that hands back more pixels than asked for is refused too.
        #expect(Bench.retina(big, draw: { cg, _, _ in NSBitmapImageRep(cgImage: cg) }) == nil)
    }

    /// Whatever comes back is within both caps.
    @Test(arguments: [(5120, 2880), (1600, 4000), (2560, 1600), (900, 600)])
    func everyPictureIsWithinBothCaps(size: (Int, Int)) throws {
        let (data, wide, high) = try #require(Bench.retina(try noise(width: size.0, height: size.1)))
        #expect(max(wide, high) <= Bench.retinaSide)
        #expect(data.count <= Bench.retinaBytes)
    }
}
