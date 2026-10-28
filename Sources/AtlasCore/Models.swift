import Foundation

// MARK: - Import mode

/// How files enter the library.
public enum ImportMode: String, Sendable, CaseIterable, Codable {
    /// Copy bytes into `<library>/originals/` and own them. Content-hash deduped.
    case copy
    /// Index files where they live. **Never writes into `originals/`.**
    case connected
}

// MARK: - Kind

public enum MediaKind: String, Sendable, CaseIterable, Codable {
    case image
    case video
    case other

    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "tif", "bmp", "avif", "raw", "dng",
    ]

    public static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "webm", "avi", "mkv",
    ]

    public static func detect(fromExtension ext: String) -> MediaKind {
        let lowered = ext.lowercased()
        if imageExtensions.contains(lowered) { return .image }
        if videoExtensions.contains(lowered) { return .video }
        return .other
    }
}

// MARK: - Item

public struct LibraryItem: Sendable, Identifiable, Hashable, Codable {
    public let id: UUID
    public let kind: MediaKind
    public let mode: ImportMode
    public let fileName: String
    /// Absolute path — populated for `.connected` items only.
    public let sourcePath: String?
    /// File name relative to `<library>/originals/` — populated for `.copy` items only.
    public let storedName: String?
    public let width: Int?
    public let height: Int?
    public let byteSize: Int64
    public let contentHash: String
    public let importedAt: Date
    public let fileCreatedAt: Date?
    public let fileModifiedAt: Date?

    public init(
        id: UUID,
        kind: MediaKind,
        mode: ImportMode,
        fileName: String,
        sourcePath: String?,
        storedName: String?,
        width: Int?,
        height: Int?,
        byteSize: Int64,
        contentHash: String,
        importedAt: Date,
        fileCreatedAt: Date?,
        fileModifiedAt: Date?
    ) {
        self.id = id
        self.kind = kind
        self.mode = mode
        self.fileName = fileName
        self.sourcePath = sourcePath
        self.storedName = storedName
        self.width = width
        self.height = height
        self.byteSize = byteSize
        self.contentHash = contentHash
        self.importedAt = importedAt
        self.fileCreatedAt = fileCreatedAt
        self.fileModifiedAt = fileModifiedAt
    }

    /// `path` for connected items, `stored name` for copied items.
    public var location: String {
        sourcePath ?? storedName ?? fileName
    }

    public var isConnected: Bool { mode == .connected }

    public var dimensionsDescription: String {
        guard let width, let height else { return "—" }
        return "\(width)×\(height)"
    }
}

// MARK: - Collection

/// A collection node. Collections form a tree of arbitrary depth via `parentID`; a `nil`
/// parent means the node lives at the root of the sidebar.
///
/// The **Inbox** is a system collection (`isInbox == true`). It is always a root node, it
/// cannot be renamed, nested under, or deleted, and it is excluded from `collections()` by
/// default so the user-facing collection list stays clean.
public struct LibraryCollection: Sendable, Identifiable, Hashable, Codable {
    public let id: UUID
    public let name: String
    public let createdAt: Date
    public let updatedAt: Date
    /// Items linked *directly* to this collection.
    public let itemCount: Int
    /// Parent collection, or `nil` for a root node.
    public let parentID: UUID?
    /// Manual ordering among siblings. Lower sorts first.
    public let sortOrder: Double
    /// True for the single system Inbox collection.
    public let isInbox: Bool
    /// Items in this collection plus every descendant collection.
    public let totalItemCount: Int
    /// Populated by `collectionTree()`; always empty for flat `collections()` results.
    public var children: [LibraryCollection]

    public init(
        id: UUID,
        name: String,
        createdAt: Date,
        updatedAt: Date,
        itemCount: Int,
        parentID: UUID? = nil,
        sortOrder: Double = 0,
        isInbox: Bool = false,
        totalItemCount: Int? = nil,
        children: [LibraryCollection] = []
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.itemCount = itemCount
        self.parentID = parentID
        self.sortOrder = sortOrder
        self.isInbox = isInbox
        self.totalItemCount = totalItemCount ?? itemCount
        self.children = children
    }

    public var isRoot: Bool { parentID == nil }

    /// True when the collection may be renamed, moved, nested under, or deleted.
    public var isUserEditable: Bool { !isInbox }

    /// Depth-first walk including `self`.
    public func flattened() -> [LibraryCollection] {
        [self] + children.flatMap { $0.flattened() }
    }
}

// MARK: - Tag

/// A user-created tag. Tags are a flat many-to-many label space — deliberately *not*
/// smart folders.
public struct LibraryTag: Sendable, Identifiable, Hashable, Codable {
    public let id: UUID
    public let name: String
    public let createdAt: Date
    /// Free-form hex colour (`#RRGGBB`), or `nil` for the default accent.
    public let color: String?
    public let itemCount: Int

    public init(id: UUID, name: String, createdAt: Date, color: String?, itemCount: Int = 0) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.color = color
        self.itemCount = itemCount
    }
}

/// How `setTags(itemIDs:tagIDs:mode:)` reconciles the given pairs.
public enum TagAssignmentMode: String, Sendable, Codable, CaseIterable {
    /// Union: add the pairs, leave every other tag alone.
    case add
    /// Subtract: remove the pairs, leave every other tag alone.
    case remove
    /// Set: each listed item ends up with exactly `tagIDs`.
    case replace
}

// MARK: - Import report

/// Result of one `importFolder` call.
///
/// `copiedOriginals` is the load-bearing number for the P0 gate:
/// it **must be 0** for `.connected` imports.
public struct ImportReport: Sendable, Codable, Equatable {
    public var folder: String
    public var mode: ImportMode
    public var collectionName: String
    public var scanned: Int = 0
    /// New rows inserted.
    public var imported: Int = 0
    /// Existing rows refreshed (same location re-imported).
    public var updated: Int = 0
    /// Identical content already present in copy mode.
    public var duplicates: Int = 0
    /// Unsupported file types or per-file failures.
    public var skipped: Int = 0
    /// Files physically written into `<library>/originals/`.
    public var copiedOriginals: Int = 0
    public var bytesHashed: Int64 = 0
    public var durationSeconds: Double = 0
    public var errors: [String] = []

    public init(folder: String, mode: ImportMode, collectionName: String) {
        self.folder = folder
        self.mode = mode
        self.collectionName = collectionName
    }

    /// Number of items this import touched in the library.
    public var totalIndexed: Int { imported + updated + duplicates }
}

// MARK: - Library info

public struct LibraryInfo: Sendable, Codable {
    public var rootPath: String
    public var databasePath: String
    public var libraryID: String
    public var schemaVersion: Int
    public var itemCount: Int
    public var collectionCount: Int
    public var connectedCount: Int
    public var copiedCount: Int
    public var totalBytes: Int64
    public var originalsFileCount: Int
    public var thumbnailsFileCount: Int
    public var databaseByteSize: Int64
    public var kindBreakdown: [String: Int]
    /// Number of tags defined in the library.
    public var tagCount: Int = 0
    /// Items currently sitting in the Inbox (the sidebar badge value).
    public var inboxItemCount: Int = 0
}
