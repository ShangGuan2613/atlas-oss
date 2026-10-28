import AppKit
import SwiftUI

/// Transparent AppKit destination for file drags, shared by the sidebar rows and the
/// menu-bar pin.
///
/// Why not SwiftUI's typed `.dropDestination(for: URL.self)` everywhere? Because two
/// `dropDestination` modifiers on the *same* view do not coexist — only the last one applied
/// keeps working, and the other type silently stops accepting drops. The sidebar rows
/// already own `dropDestination(for: String.self)` for P1-B item drags, so file drops must
/// live on a **different view**: this one, placed behind the row.
///
/// Critical: `hitTest` returns `nil` for ordinary mouse events so SwiftUI keeps receiving
/// clicks. During an active *file* drag we claim hits so AppKit can deliver
/// `draggingEntered` / `performDragOperation`. Without that split, stacking one
/// `FileDropNSView` per sidebar row made lower rows steal clicks from upper ones
/// (symptom: after clicking a lower folder, upper folders stopped responding).
class FileDropNSView: NSView {
    /// Called with the dropped file URLs.
    var onFiles: (([URL]) -> Void)?
    /// Called when a file drag enters/leaves, for highlight chrome.
    var onTargetedChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        registerForDraggedTypes([.fileURL])
        // Never draw; never expand past the SwiftUI-proposed size.
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    /// File URLs out of a dragging pasteboard. `urlReadingFileURLsOnly` already filters, the
    /// second pass is belt-and-braces so a stray `http` URL can never reach the importer.
    static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options)
        guard let urls = objects as? [URL] else { return [] }
        return urls.filter(\.isFileURL)
    }

    /// True while the session drag pasteboard carries at least one file URL.
    private static var isFileDragInFlight: Bool {
        let pb = NSPasteboard(name: .drag)
        return !fileURLs(in: pb).isEmpty
    }

    /// Pass clicks through to SwiftUI; only participate in hit-testing during a file drag.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard Self.isFileDragInFlight else { return nil }
        return super.hitTest(point)
    }

    // MARK: - Drag destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !Self.fileURLs(in: sender.draggingPasteboard).isEmpty else { return [] }
        onTargetedChange?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(in: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetedChange?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargetedChange?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !Self.fileURLs(in: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargetedChange?(false)
        let urls = Self.fileURLs(in: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onFiles?(urls)
        return true
    }
}

/// SwiftUI wrapper around `FileDropNSView`.
struct FileDropArea: NSViewRepresentable {
    var onFiles: ([URL]) -> Void
    var onTargeted: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> FileDropNSView {
        let view = FileDropNSView(frame: .zero)
        view.onFiles = onFiles
        view.onTargetedChange = onTargeted
        return view
    }

    func updateNSView(_ view: FileDropNSView, context: Context) {
        view.onFiles = onFiles
        view.onTargetedChange = onTargeted
    }
}
