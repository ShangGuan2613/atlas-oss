#!/usr/bin/env swift
//
//  fixtures.swift — deterministic PNG fixture generator for AtlasOSS P0 verification.
//
//  Usage:
//    swift scripts/fixtures.swift write <output-directory>
//    swift scripts/fixtures.swift emit-swift <path/to/PNGFixtureData.swift>
//
//  `write`   writes the four fixture PNGs into a directory (used by scripts/verify-p0.sh).
//  `emit-swift` regenerates the embedded base64 fixture source used by the test target.
//
//  Images are solid fills with a 4×4 white marker at (2,2), so every file has distinct
//  bytes *and* distinct pixel dimensions. Nothing here touches the network or user data.
//
import Foundation
import CoreGraphics
import ImageIO

struct Spec {
    let name: String
    let width: Int
    let height: Int
    let rgb: (Double, Double, Double)
}

let specs: [Spec] = [
    Spec(name: "sunset.png", width: 64, height: 48, rgb: (0.92, 0.35, 0.20)),
    Spec(name: "ocean.png", width: 80, height: 60, rgb: (0.10, 0.45, 0.75)),
    Spec(name: "forest.png", width: 100, height: 75, rgb: (0.20, 0.60, 0.30)),
    Spec(name: "dusk.png", width: 120, height: 90, rgb: (0.35, 0.25, 0.55)),
]

func renderPNG(spec: Spec) -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: spec.width,
        height: spec.height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("cannot create CGContext for \(spec.name)")
    }

    context.setFillColor(red: spec.rgb.0, green: spec.rgb.1, blue: spec.rgb.2, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: spec.width, height: spec.height))
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 2, y: 2, width: 4, height: 4))

    guard let image = context.makeImage() else {
        fatalError("cannot snapshot CGContext for \(spec.name)")
    }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data as CFMutableData,
        "public.png" as CFString,
        1,
        nil
    ) else {
        fatalError("cannot create image destination for \(spec.name)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("cannot finalize PNG for \(spec.name)")
    }
    return data as Data
}

func write(directory: String) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
    for spec in specs {
        let data = renderPNG(spec: spec)
        let url = URL(fileURLWithPath: directory).appendingPathComponent(spec.name)
        try data.write(to: url)
        print("  wrote \(spec.name) (\(spec.width)×\(spec.height), \(data.count) B)")
    }
}

func wrap(_ string: String, width: Int) -> [String] {
    var lines: [String] = []
    var current = ""
    for character in string {
        current.append(character)
        if current.count == width {
            lines.append(current)
            current = ""
        }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
}

func emitSwift(to path: String) throws {
    var out = """
    // Generated file — do not edit by hand.
    //
    // Deterministic PNG fixtures produced with CoreGraphics: solid fill plus a 4×4 white
    // marker at (2,2), so every file has distinct bytes *and* distinct pixel dimensions.
    // Regenerate with:
    //   swift scripts/fixtures.swift emit-swift Tests/AtlasCoreTests/PNGFixtureData.swift
    //
    // swiftformat: disable all

    enum PNGFixtureData {
        struct Entry {
            let name: String
            let width: Int
            let height: Int
            let base64: String
        }

        static let entries: [Entry] = [

    """

    for spec in specs {
        let base64 = renderPNG(spec: spec).base64EncodedString()
        out += "        Entry(name: \"\(spec.name)\", width: \(spec.width), height: \(spec.height), base64: \"\"\"\n"
        for line in wrap(base64, width: 100) {
            out += "            \(line)\n"
        }
        out += "            \"\"\"),\n"
    }

    out += """
        ]
    }

    """

    try out.write(toFile: path, atomically: true, encoding: .utf8)
    print("  wrote \(path)")
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    FileHandle.standardError.write(Data("usage: fixtures.swift <write|emit-swift> <path>\n".utf8))
    exit(2)
}

do {
    switch command {
    case "write":
        guard arguments.count >= 2 else {
            FileHandle.standardError.write(Data("usage: fixtures.swift write <directory>\n".utf8))
            exit(2)
        }
        try write(directory: arguments[1])
    case "emit-swift":
        guard arguments.count >= 2 else {
            FileHandle.standardError.write(Data("usage: fixtures.swift emit-swift <swift-file>\n".utf8))
            exit(2)
        }
        try emitSwift(to: arguments[1])
    default:
        FileHandle.standardError.write(Data("unknown command '\(command)'\n".utf8))
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
