import Foundation
import Testing
@testable import AtlasCore

/// P1-C dimension E, layer 1: the extractor itself.
@Suite("P1-C · colour probe")
struct ColorProbeTests {

    // MARK: - Palette shape

    @Test("a multi-colour image yields at least three ordered swatches")
    func multiColorImageYieldsThreeSwatches() throws {
        let workspace = try TemporaryWorkspace(label: "probe-multi")
        let url = try ColorFixtures.write(
            [
                .init("#D12A2A", 0.5),
                .init("#2A8C3A", 0.2),
                .init("#2A4CD1", 0.2),
                .init("#F2F2F2", 0.1),
            ],
            to: workspace.url.appendingPathComponent("bands.png")
        )

        let swatches = ColorProbe.swatches(for: url)

        #expect(swatches.count >= ColorProbe.minimumDistinctSwatches)
        #expect(Set(swatches.map(\.hex)).count == swatches.count, "swatches are distinct")
        #expect(swatches.count <= ColorProbe.defaultMaxColors)

        // Prominence order: weights never increase down the palette.
        for (lhs, rhs) in zip(swatches, swatches.dropFirst()) {
            #expect(lhs.weight >= rhs.weight)
        }

        // Canonical `#RRGGBB`.
        for swatch in swatches {
            #expect(swatch.hex.count == 7)
            #expect(swatch.hex.hasPrefix("#"))
            #expect(swatch.hex == swatch.hex.uppercased())
            let digitsAreHex = swatch.hex.dropFirst().allSatisfy { $0.isHexDigit }
            #expect(digitsAreHex)
            #expect(swatch.weight > 0 && swatch.weight <= 1)
            #expect(swatch.rgb != nil)
        }

        // Weights are pixel shares, so they explain most of the image between them.
        let total = swatches.reduce(0) { $0 + $1.weight }
        #expect(total <= 1.0001)
        #expect(total > 0.9)
    }

    @Test("the biggest colour region leads the palette")
    func dominantRegionLeads() throws {
        let workspace = try TemporaryWorkspace(label: "probe-dominant")
        let url = try ColorFixtures.write(
            [
                .init("#C81E1E", 0.7),
                .init("#1E3CC8", 0.2),
                .init("#F0F0F0", 0.1),
            ],
            to: workspace.url.appendingPathComponent("dominant.png")
        )

        let swatches = ColorProbe.swatches(for: url)
        let first = try #require(swatches.first)
        let distance = try #require(ColorProbe.distance(betweenHex: first.hex, andHex: "#C81E1E"))

        #expect(distance < 40, "got \(first.hex)")
        #expect(first.weight > 0.55)
        #expect(swatches.contains { swatch in
            (ColorProbe.distance(betweenHex: swatch.hex, andHex: "#1E3CC8") ?? .infinity) < 60
        })
    }

    @Test("a flat image still reports a palette")
    func flatImageIsHandled() throws {
        let workspace = try TemporaryWorkspace(label: "probe-flat")
        let url = try ColorFixtures.write(
            [.init("#3366CC", 1.0)],
            to: workspace.url.appendingPathComponent("flat.png")
        )

        let swatches = ColorProbe.swatches(for: url)
        let first = try #require(swatches.first)
        let distance = try #require(ColorProbe.distance(betweenHex: first.hex, andHex: "#3366CC"))

        #expect(distance < 12, "got \(first.hex)")
        #expect(first.weight > 0.9)
    }

    @Test("maxColors caps the palette")
    func maxColorsCaps() throws {
        let workspace = try TemporaryWorkspace(label: "probe-cap")
        let url = try ColorFixtures.write(
            [
                .init("#E01B1B", 0.25),
                .init("#1BE01B", 0.25),
                .init("#1B1BE0", 0.25),
                .init("#E0E01B", 0.25),
            ],
            to: workspace.url.appendingPathComponent("four.png")
        )

        #expect(ColorProbe.swatches(for: url, maxColors: 2).count == 2)
        #expect(ColorProbe.swatches(for: url, maxColors: 0).isEmpty)
    }

    // MARK: - Pixel histogram

    @Test("weights are pixel shares of the sampled buffer")
    func bufferHistogramWeights() {
        var bytes: [UInt8] = []
        for _ in 0 ..< 12 { bytes += [255, 0, 0, 255] }
        for _ in 0 ..< 4 { bytes += [0, 0, 255, 255] }

        let swatches = ColorProbe.swatches(fromSRGBAPixels: bytes, maxColors: 5)

        #expect(swatches.first?.hex == "#FF0000")
        #expect(abs((swatches.first?.weight ?? 0) - 0.75) < 0.01)
        #expect(swatches.contains { $0.hex == "#0000FF" })
    }

    @Test("transparent pixels are ignored")
    func transparentPixelsIgnored() {
        var bytes: [UInt8] = []
        for _ in 0 ..< 10 { bytes += [0, 0, 0, 0] }
        for _ in 0 ..< 2 { bytes += [10, 200, 40, 255] }

        let swatches = ColorProbe.swatches(fromSRGBAPixels: bytes, maxColors: 3)

        #expect(swatches.count == 1)
        #expect(swatches.first?.hex == "#0AC828")
        #expect(abs((swatches.first?.weight ?? 0) - 1.0) < 0.0001)
    }

    @Test("empty and malformed buffers are safe")
    func emptyBuffers() {
        #expect(ColorProbe.swatches(fromSRGBAPixels: [], maxColors: 3).isEmpty)
        #expect(ColorProbe.swatches(fromSRGBAPixels: [255, 0, 0], maxColors: 3).isEmpty)
        #expect(ColorProbe.swatches(fromSRGBAPixels: [255, 0, 0, 255], maxColors: 0).isEmpty)
    }

    // MARK: - Degenerate inputs

    @Test("missing and non-image files produce no palette")
    func nonImageInputsAreEmpty() throws {
        let workspace = try TemporaryWorkspace(label: "probe-none")
        let missing = workspace.url.appendingPathComponent("nope.png")
        #expect(ColorProbe.swatches(for: missing).isEmpty)

        let text = workspace.url.appendingPathComponent("notes.png")
        try "definitely not a png".write(to: text, atomically: true, encoding: .utf8)
        #expect(ColorProbe.swatches(for: text).isEmpty)

        let video = workspace.url.appendingPathComponent("clip.mp4")
        try Data(repeating: 0, count: 64).write(to: video)
        #expect(ColorProbe.swatches(for: video).isEmpty)
    }

    // MARK: - Hex helpers

    @Test("hex parsing is canonical and lenient")
    func hexParsing() {
        #expect(ColorProbe.normalizedHex("#aabbcc") == "#AABBCC")
        #expect(ColorProbe.normalizedHex("aabbcc") == "#AABBCC")
        #expect(ColorProbe.normalizedHex("#ABC") == "#AABBCC")
        #expect(ColorProbe.normalizedHex("  #AABBCC  ") == "#AABBCC")
        #expect(ColorProbe.normalizedHex("#12345") == nil)
        #expect(ColorProbe.normalizedHex("") == nil)
        #expect(ColorProbe.normalizedHex("#GGGGGG") == nil)

        #expect(ColorProbe.hex(red: 0, green: 10, blue: 255) == "#000AFF")
        #expect(ColorProbe.hex(red: -20, green: 300, blue: 128) == "#00FF80")

        let rgb = ColorProbe.rgbComponents(fromHex: "#12AB34")
        #expect(rgb?.red == 0x12)
        #expect(rgb?.green == 0xAB)
        #expect(rgb?.blue == 0x34)
        #expect(ColorProbe.rgbComponents(fromHex: "nope") == nil)
    }

    @Test("distance is symmetric, zero for equality, and bounded by tolerance")
    func distanceMath() throws {
        let red = try #require(ColorProbe.rgbComponents(fromHex: "#FF0000"))
        let blue = try #require(ColorProbe.rgbComponents(fromHex: "#0000FF"))

        #expect(ColorProbe.distance(red, red) == 0)
        #expect(abs(ColorProbe.distance(red, blue) - 360.62) < 0.5)
        #expect(ColorProbe.distance(red, blue) == ColorProbe.distance(blue, red))
        #expect(ColorProbe.distance(betweenHex: "#FF0000", andHex: "#FF0002")! < 3)
        #expect(ColorProbe.distance(betweenHex: "not-a-colour", andHex: "#FF0002") == nil)

        // Documented tolerance: 40 keeps near shades together and separates families.
        #expect(ColorProbe.distance(betweenHex: "#808080", andHex: "#8A8A8A")! < Double(ColorProbe.defaultTolerance))
        #expect(ColorProbe.distance(betweenHex: "#808080", andHex: "#C08080")! > Double(ColorProbe.defaultTolerance))
    }
}
