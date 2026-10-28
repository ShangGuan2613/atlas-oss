import Foundation

/// Package-style on-disk layout:
///
/// ```
/// ~/Library/Application Support/AtlasOSS/default.atlaslibrary/
/// ├── library.sqlite      # items, collections, metadata (+ -wal / -shm)
/// ├── originals/          # only ever populated by `.copy` imports
/// └── thumbnails/         # reserved for P1 thumbnail pipeline
/// ```
public struct LibraryPaths: Sendable, Hashable {
    public static let packageExtension = "atlaslibrary"
    public static let databaseName = "library.sqlite"
    public static let originalsDirectoryName = "originals"
    public static let thumbnailsDirectoryName = "thumbnails"

    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public init(path: String) {
        self.init(root: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    // MARK: - Standard locations

    /// `~/Library/Application Support/AtlasOSS`
    public static var applicationSupportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("AtlasOSS", isDirectory: true)
    }

    /// `~/Library/Application Support/AtlasOSS/default.atlaslibrary`
    public static var defaultRoot: URL {
        applicationSupportRoot.appendingPathComponent("default.\(packageExtension)", isDirectory: true)
    }

    // MARK: - Children

    public var databaseURL: URL {
        root.appendingPathComponent(Self.databaseName, isDirectory: false)
    }

    public var originalsURL: URL {
        root.appendingPathComponent(Self.originalsDirectoryName, isDirectory: true)
    }

    public var thumbnailsURL: URL {
        root.appendingPathComponent(Self.thumbnailsDirectoryName, isDirectory: true)
    }

    /// Absolute location of a `.copy` item's stored file.
    public func url(forStoredName storedName: String) -> URL {
        originalsURL.appendingPathComponent(storedName, isDirectory: false)
    }

    public var hasDatabase: Bool {
        FileManager.default.fileExists(atPath: databaseURL.path)
    }

    // MARK: - Creation

    public func createDirectories(fileManager: FileManager = .default) throws {
        for directory in [root, originalsURL, thumbnailsURL] {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw AtlasError.libraryCreationFailed("\(directory.path): \(error.localizedDescription)")
            }
        }
    }
}

/// Path helpers.
public enum PathUtilities {
    /// Canonical absolute path with all symlinks resolved.
    ///
    /// Connected mode stores this form so the same file reached through different
    /// spellings (`/var/...` vs `/private/var/...`, relative vs absolute) maps to a
    /// single library item instead of duplicates.
    public static func canonicalPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard let resolved = realpath(expanded, nil) else {
            return (expanded as NSString).standardizingPath
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static func canonicalURL(_ url: URL) -> URL {
        URL(fileURLWithPath: canonicalPath(url.path))
    }
}

/// Small filesystem helpers used by the CLI and `LibraryInfo`.
public enum DirectoryStats {
    /// Recursively counts regular files. Returns 0 when the directory is absent.
    public static func fileCount(in directory: URL, fileManager: FileManager = .default) -> Int {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return 0
        }
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return 0
        }
        var count = 0
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                count += 1
            }
        }
        return count
    }

    public static func fileSize(at url: URL, fileManager: FileManager = .default) -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }
}
