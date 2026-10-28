import Foundation

// MARK: - Capture target

/// Where a capture lands.
///
/// Capture is the P1-E surface: a file dropped on the window, on a collection row, or on the
/// menu-bar pin, or pasted with ⌘V. All of them funnel through
/// `AtlasLibrary.importURLs(_:mode:target:)`, and `CaptureTarget` is the only thing that
/// differs between them.
///
/// The three cases exist because of the **Inbox rule** (stated in full in
/// `AtlasLibrary+Collections.swift`): the Inbox holds "captured but not filed yet", and
/// filing means linking a user collection *and* unlinking the Inbox.
public enum CaptureTarget: Sendable, Hashable, Codable {
    /// Capture to the Inbox only. Window drops while Inbox / All Items is selected, every
    /// paste, and every menu-bar drop land here.
    case inbox

    /// Import *into* a collection while also leaving the item in the Inbox. This is
    /// `importFolder(_:mode:collectionName:)` behaviour, kept for parity: a bulk import is
    /// not the same thing as filing each item by hand.
    case collection(UUID)

    /// Capture then **file**: linked to the collection and never linked to the Inbox. What
    /// dropping onto a selected user collection does — the same end state as dragging an
    /// existing item onto that row (`assignItems(_:toCollection:)`).
    case assignedCollection(UUID)

    /// Collection the items are linked into (`nil` means "the Inbox is the destination").
    public var collectionID: UUID? {
        switch self {
        case .inbox: return nil
        case .collection(let id), .assignedCollection(let id): return id
        }
    }

    /// Whether the captured items should stay visible in the Inbox afterwards.
    public var keepsInboxLink: Bool {
        switch self {
        case .inbox, .collection: return true
        case .assignedCollection: return false
        }
    }
}

// MARK: - Capture report

/// Result of one capture batch (one drop, one paste).
///
/// Shaped like `ImportReport` on purpose — same counters, minus the folder framing — plus
/// `destinationLabel` and a ready-to-display `summary`, so the App layer never has to
/// compose user-facing copy itself.
public struct CaptureReport: Sendable, Codable, Equatable {
    /// `.connected` for file drops (nothing is copied), `.copy` for pasted bitmaps.
    public var mode: ImportMode
    /// Where the items went: `"Inbox"`, or the destination collection's name.
    public var destinationLabel: String
    /// Files found across the dropped URLs, after expanding directories.
    public var scanned: Int = 0
    /// New rows inserted.
    public var imported: Int = 0
    /// Existing rows refreshed — `.connected` re-drops of the same path land here.
    public var updated: Int = 0
    /// Identical content already stored — `.copy` re-adds of the same bytes land here.
    public var duplicates: Int = 0
    /// Unsupported file types, missing paths and per-file failures.
    public var skipped: Int = 0
    /// Files physically written into `originals/`. Always `0` for `.connected`.
    public var copiedOriginals: Int = 0
    public var bytesHashed: Int64 = 0
    public var durationSeconds: Double = 0
    public var errors: [String] = []

    public init(mode: ImportMode, destinationLabel: String) {
        self.mode = mode
        self.destinationLabel = destinationLabel
    }

    // MARK: Derived

    /// Anything the library already had before this batch: `.copy` hits are content-hash
    /// duplicates, `.connected` hits are same-path re-imports (reported as `updated`).
    /// Both mean "you have this already", which is what the user-facing message says.
    public var alreadyPresent: Int { duplicates + updated }

    /// Rows this batch actually (re)touched.
    public var changed: Int { imported + alreadyPresent }

    /// True when the batch produced nothing to say — an empty drop, not a failure.
    public var isEmpty: Bool { changed == 0 && skipped == 0 && errors.isEmpty }

    /// True when some of the batch was already in the library — drives the duplicate banner.
    public var hasDuplicates: Bool { alreadyPresent > 0 }

    /// One line, ready for a banner or an alert. Deterministic and free of UI types so it
    /// can be asserted in tests.
    ///
    /// - `"Nothing to import"` when the batch was empty.
    /// - `"Inbox: Imported 3 items"` for a clean capture.
    /// - `"Inbox: Imported 2 items · 3 already in library"` for a mixed one.
    public var summary: String {
        var parts: [String] = []
        if imported > 0 {
            parts.append("Imported \(CaptureReport.count(imported, "item"))")
        }
        if alreadyPresent > 0 {
            parts.append("\(alreadyPresent) already in library")
        }
        if skipped > 0 {
            parts.append("\(skipped) skipped")
        }
        if !errors.isEmpty {
            parts.append("\(CaptureReport.count(errors.count, "error"))")
        }
        guard !parts.isEmpty else { return "Nothing to import" }
        return "\(destinationLabel): " + parts.joined(separator: " · ")
    }

    /// `1 item` / `3 items`, without a pluralisation dependency.
    static func count(_ value: Int, _ singular: String) -> String {
        "\(value) \(singular)\(value == 1 ? "" : "s")"
    }
}

// MARK: - Capture sources

/// Where a capture was started. Only used for labels/telemetry, never for behaviour — the
/// destination is decided by `CaptureTarget`.
public enum CaptureSource: String, Sendable, CaseIterable {
    /// Files dropped on the main window / grid.
    case windowDrop
    /// Files dropped on a sidebar collection row.
    case sidebarDrop
    /// Files dropped on the menu-bar status item.
    case menuBarDrop
    /// ⌘V in the window.
    case paste
}
