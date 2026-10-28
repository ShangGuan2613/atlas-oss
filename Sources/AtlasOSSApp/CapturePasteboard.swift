import AppKit
import Foundation

/// What ⌘V found that this app can import.
enum PasteboardPayload: Equatable {
    /// Files or folders dragged/copied from Finder, a browser download shelf, Preview, …
    case files([URL])
    /// Encoded bitmap (normalised to PNG) — screenshots, "Copy Image" from a browser.
    case image(Data)
    /// Text, colours, promises we do not handle: ⌘V must fall through untouched.
    case none
}

/// Finder-like paste semantics, minus the parts that do not apply to a library.
///
/// No `NSPasteboard` subclassing and no custom `UTType`: files come back through the
/// standard `NSURL` reading path, everything else is probed for bitmap data. That keeps the
/// app free of Info.plist / entitlement requirements — reading `NSPasteboard.general` on
/// macOS needs no privacy declaration.
enum CapturePasteboard {

    /// Normalised file extension for pasted bitmaps. They are stored with `.copy`, so this
    /// is the extension that ends up under `originals/`.
    static let pastedImageExtension = "png"

    // MARK: - Reading

    static func read(from pasteboard: NSPasteboard = .general) -> PasteboardPayload {
        // 1. Files first: a Finder copy carries both a file URL *and* (usually) a bitmap
        //    preview of the first file. Preferring the URLs is what keeps a 5-file copy from
        //    turning into one flattened screenshot.
        let fileURLs = readFileURLs(from: pasteboard)
        if !fileURLs.isEmpty { return .files(fileURLs) }

        // 2. Raw bitmap (screenshot ⇧⌃⌘4, "Copy Image", Preview selection).
        if let png = pngData(from: pasteboard) { return .image(png) }

        return .none
    }

    static func readFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options)
        guard let urls = objects as? [URL] else { return [] }
        // `urlReadingFileURLsOnly` should already guarantee this; belt and braces so a stray
        // http URL can never reach the importer.
        return urls.filter(\.isFileURL)
    }

    /// PNG bytes for the pasteboard's bitmap, normalising TIFF through ImageIO.
    static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png), !png.isEmpty { return png }
        guard let tiff = pasteboard.data(forType: .tiff), !tiff.isEmpty,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Writing

    /// Writes pasted bytes to a scratch file so the import pipeline can see a real URL.
    ///
    /// The caller deletes it after the import: the item is stored with `.copy`, so the
    /// library owns the bytes and nothing points back at the scratch file.
    @discardableResult
    static func writeTemporaryPNG(
        _ data: Data,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let root = directory ?? fileManager.temporaryDirectory
            .appendingPathComponent("atlasoss-paste", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("paste-\(UUID().uuidString).\(pastedImageExtension)")
        try data.write(to: file, options: .atomic)
        return file
    }
}
