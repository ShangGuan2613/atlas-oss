import Foundation

// MARK: - Import from URLs

/// Capture entry point shared by every P1-E surface.
///
/// A drop gives the app a handful of URLs — some files, some folders — and no notion of a
/// "batch folder". `importURLs` is the same engine as `importFolder` (it calls the same
/// `importSingleFile`), with three deliberate differences:
///
/// 1. **Connected by default.** Dropping a file must never silently copy it, so the default
///    `mode` is `.connected`. Paste of raw bitmap data is the only caller that asks for
///    `.copy`, because there is no file to point at.
/// 2. **A folder is enumerated, not named.** `importFolder` creates a collection named after
///    the folder; a dropped folder would otherwise litter the sidebar with a collection per
///    drop. Capture enumerates it into the *target* instead.
/// 3. **URLs are canonicalised and de-duplicated inside the batch**, so dropping the same
///    file twice (or `/var/…` and `/private/var/…` on macOS) is one item, and re-dropping it
///    later reports `updated` instead of growing the library.
extension AtlasLibrary {

    /// Imports file and directory URLs into the library.
    ///
    /// - Parameters:
    ///   - urls: Files or folders, in the order the drop delivered them. Folders are
    ///     expanded recursively (hidden files and packages skipped, matching `importFolder`).
    ///   - mode: `.connected` (default) indexes files where they live and never writes to
    ///     `originals/`; `.copy` stores content-addressed copies.
    ///   - target: where the items land. See `CaptureTarget` for the Inbox-rule semantics.
    /// - Returns: a `CaptureReport` with counters plus a display-ready `summary`.
    @discardableResult
    public func importURLs(
        _ urls: [URL],
        mode: ImportMode = .connected,
        target: CaptureTarget = .inbox
    ) throws -> CaptureReport {
        let started = Date()
        let inboxID = try ensureInboxCollectionID()

        // `linkItem` skips the Inbox when the two ids match, which is exactly the
        // "assigned" case: linked to the collection, never linked to the Inbox.
        let collectionID: UUID
        let linkInboxID: UUID
        let label: String

        switch target {
        case .inbox:
            collectionID = inboxID
            linkInboxID = inboxID
            label = AtlasSchema.inboxCollectionName
        case .collection(let id), .assignedCollection(let id):
            guard let destination = try collection(id: id) else {
                throw AtlasError.unsupported("No collection with id \(id.uuidString)")
            }
            collectionID = destination.id
            linkInboxID = target.keepsInboxLink ? inboxID : destination.id
            label = destination.name
        }

        var report = CaptureReport(mode: mode, destinationLabel: label)
        let files = try resolveCaptureFiles(urls, report: &report)
        report.scanned = files.count

        guard !files.isEmpty else {
            report.durationSeconds = Date().timeIntervalSince(started)
            return report
        }

        // One `ImportReport` for the whole batch: `importSingleFile` owns duplicate
        // detection and originals accounting, and reusing it is what keeps capture and
        // `importFolder` honest about each other.
        var scratch = ImportReport(folder: "", mode: mode, collectionName: label)

        try database.transaction {
            for file in files {
                let kind = MediaKind.detect(fromExtension: file.pathExtension.lowercased())
                guard kind == .image || kind == .video else {
                    report.skipped += 1
                    continue
                }
                do {
                    try importSingleFile(
                        file,
                        kind: kind,
                        mode: mode,
                        collectionID: collectionID,
                        inboxID: linkInboxID,
                        report: &scratch
                    )
                } catch {
                    report.skipped += 1
                    report.errors.append("\(file.lastPathComponent): \(error)")
                }
            }
            try touchCollection(collectionID)
        }

        report.imported = scratch.imported
        report.updated = scratch.updated
        report.duplicates = scratch.duplicates
        report.skipped += scratch.skipped
        report.copiedOriginals = scratch.copiedOriginals
        report.bytesHashed = scratch.bytesHashed
        report.errors.append(contentsOf: scratch.errors)
        report.durationSeconds = Date().timeIntervalSince(started)
        return report
    }

    // MARK: - URL expansion

    /// Turns the dropped URLs into a flat, canonical, de-duplicated list of files.
    ///
    /// Missing paths and unreadable folders are recorded on `report` rather than thrown, so
    /// one bad URL in a ten-file drop cannot lose the other nine.
    func resolveCaptureFiles(_ urls: [URL], report: inout CaptureReport) throws -> [URL] {
        var files: [URL] = []
        // Two sets on purpose: `visited` de-duplicates the *URLs* in the batch (the same file
        // can arrive twice, or a folder and one of its children), `filePaths` de-duplicates
        // the files those URLs expand to. Sharing one set would swallow every plain file.
        var visited = Set<String>()
        var filePaths = Set<String>()

        func append(_ file: URL) {
            if filePaths.insert(file.path).inserted { files.append(file) }
        }

        for url in urls {
            // Canonicalise first: `/var/folders/…` and `/private/var/folders/…` are the same
            // file, and connected dedupe is keyed on the stored path.
            let canonical = PathUtilities.canonicalURL(url)
            guard visited.insert(canonical.path).inserted else { continue }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: canonical.path, isDirectory: &isDirectory) else {
                report.skipped += 1
                report.errors.append("\(url.lastPathComponent): not found")
                continue
            }

            if isDirectory.boolValue {
                do {
                    for file in try enumerateImportableFiles(in: canonical) {
                        append(file)
                    }
                } catch {
                    report.skipped += 1
                    report.errors.append("\(canonical.lastPathComponent): \(error)")
                }
            } else {
                append(canonical)
            }
        }

        return files
    }
}
