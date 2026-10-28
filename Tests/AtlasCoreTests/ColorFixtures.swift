import CoreGraphics
import Foundation
import ImageIO

/// Colour-rich PNG fixtures, generated on demand.
///
/// The P0 fixtures in `PNGFixtureData.swift` are solid fills with a 4×4 marker — useless
/// for palette tests, which need several *large* colour regions. Generating them here
/// keeps binaries out of the repo and lets every test state the colour composition it
/// depends on.
///
/// Written straight into an sRGB bitmap context: `NSBitmapImageRep(deviceRGB)` would run
/// the values through the display profile and quietly shift every colour test.
enum ColorFixtures {
    enum FixtureError: Error {
        case emptyPalette
        case cannotAllocateContext
        case badHex(String)
        case cannotCreateDestination
        case encodingFailed
    }

    /// One horizontal band: a colour plus its share of the image height.
    struct Band {
        let hex: String
        let share: Double

        init(_ hex: String, _ share: Double) {
            self.hex = hex
            self.share = share
        }
    }

    /// Writes a PNG of horizontal bands at `url` (creating parent directories).
    @discardableResult
    static func write(
        _ bands: [Band],
        to url: URL,
        width: Int = 96,
        height: Int = 96
    ) throws -> URL {
        guard !bands.isEmpty else { throw FixtureError.emptyPalette }

        let colors = try bands.map { try components(for: $0.hex) }

        // Cumulative share -> row boundaries, so a band's pixel count matches its share.
        let totalShare = bands.reduce(0) { $0 + $1.share }
        var boundaries: [Double] = []
        var running = 0.0
        for band in bands {
            running += band.share / totalShare
            boundaries.append(running)
        }

        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0 ..< height {
            let position = (Double(y) + 0.5) / Double(height)
            let index = boundaries.firstIndex { position <= $0 } ?? (bands.count - 1)
            let color = colors[index]
            for x in 0 ..< width {
                let offset = y * bytesPerRow + x * 4
                buffer[offset] = color.red
                buffer[offset + 1] = color.green
                buffer[offset + 2] = color.blue
                buffer[offset + 3] = 255
            }
        }

        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let image: CGImage? = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: bitmapInfo
            ) else { return nil }
            return context.makeImage()
        }
        guard let image else { throw FixtureError.cannotAllocateContext }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw FixtureError.cannotCreateDestination
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.encodingFailed }
        return url
    }

    /// Minimal `#RRGGBB` parser — kept local so fixtures never depend on the code under test.
    static func components(for hex: String) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
        var digits = hex
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = Int(digits, radix: 16) else {
            throw FixtureError.badHex(hex)
        }
        return (
            red: UInt8((value >> 16) & 0xFF),
            green: UInt8((value >> 8) & 0xFF),
            blue: UInt8(value & 0xFF)
        )
    }
}
