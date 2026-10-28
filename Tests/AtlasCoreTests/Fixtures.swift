import Foundation
@testable import AtlasCore

/// Deterministic PNG fixtures, embedded as base64 (see `PNGFixtureData.swift`) so the
/// repo carries no binary blobs and tests never depend on the network or a generator step.
enum Fixtures {
    struct Fixture: Equatable {
        let name: String
        let width: Int
        let height: Int
        let data: Data
    }

    static let all: [Fixture] = PNGFixtureData.entries.map { entry in
        // The generated source wraps base64 across lines for readability.
        let compact = String(entry.base64.filter { !$0.isWhitespace })
        guard let data = Data(base64Encoded: compact) else {
            preconditionFailure("invalid base64 fixture \(entry.name)")
        }
        return Fixture(name: entry.name, width: entry.width, height: entry.height, data: data)
    }

    /// Writes every fixture PNG into `directory`.
    @discardableResult
    static func writeAll(into directory: URL, fileManager: FileManager = .default) throws -> [Fixture] {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for fixture in all {
            try fixture.data.write(to: directory.appendingPathComponent(fixture.name))
        }
        return all
    }

    /// Writes the first `count` fixtures — handy for smaller scenarios.
    @discardableResult
    static func write(prefix count: Int, into directory: URL, fileManager: FileManager = .default) throws -> [Fixture] {
        let subset = Array(all.prefix(max(0, min(count, all.count))))
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for fixture in subset {
            try fixture.data.write(to: directory.appendingPathComponent(fixture.name))
        }
        return subset
    }
}

/// Isolated throwaway workspace, one per test.
final class TemporaryWorkspace {
    let url: URL
    private let fileManager = FileManager.default

    init(label: String = "test") throws {
        url = fileManager.temporaryDirectory
            .appendingPathComponent("atlasoss-\(label)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        // Safety: only ever remove our own uniquely-named sandbox under the system temp dir.
        guard url.lastPathComponent.hasPrefix("atlasoss-"),
              url.path.hasPrefix(fileManager.temporaryDirectory.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    var libraryPaths: LibraryPaths {
        LibraryPaths(root: url.appendingPathComponent("main.atlaslibrary", isDirectory: true))
    }

    func makeLibrary() throws -> AtlasLibrary {
        try AtlasLibrary(paths: libraryPaths)
    }

    @discardableResult
    func makeFixtures(count: Int = 4, named name: String = "fixtures") throws -> URL {
        let directory = url.appendingPathComponent(name, isDirectory: true)
        try Fixtures.write(prefix: count, into: directory)
        return directory
    }
}
