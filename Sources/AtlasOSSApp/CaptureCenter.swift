import AppKit
import AtlasCore
import Foundation

/// The one funnel every capture surface goes through (P1-E).
///
/// Window drop, sidebar row drop, ⌘V and the menu-bar pin all call `capture(...)`: the
/// import itself is `AtlasLibrary.importURLs`, the destination is a `CaptureTarget`, and the
/// feedback (banner + optional status-item flash) is produced here so it looks the same
/// whichever surface you used.
///
/// The centre is not a view: it is created once by the `App` (alongside `LibraryModel`),
/// because the status item must outlive any single window and the model is what owns the
/// open library.
@MainActor
final class CaptureCenter: ObservableObject {

    /// Current banner, or `nil`. One per batch — a second drop replaces the first instead of
    /// stacking, which is what "non-blocking" has to mean for a surface people drop onto
    /// repeatedly.
    @Published private(set) var banner: CaptureBanner?

    /// Last batch, for tests and for a future "reveal in Inbox" action.
    private(set) var lastReport: CaptureReport?
    private(set) var lastSource: CaptureSource?

    private weak var model: LibraryModel?
    private let menuBar = MenuBarCaptureItem()
    private var bannerTask: Task<Void, Never>?
    private let fileManager: FileManager
    /// Scratch directory for pasted bitmaps. Injectable so tests never touch the real temp
    /// directory and the caller can assert the file was cleaned up.
    private let scratchDirectory: URL?

    init(fileManager: FileManager = .default, scratchDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.scratchDirectory = scratchDirectory
    }

    var isMenuBarInstalled: Bool { menuBar.isInstalled }

    // MARK: - Wiring

    /// Binds the centre to the open library and installs the menu-bar pin.
    ///
    /// - Parameter installMenuBar: `false` in tests, which run without a status bar.
    func attach(_ model: LibraryModel, installMenuBar: Bool = true) {
        self.model = model
        guard installMenuBar, !menuBar.isInstalled else { return }

        menuBar.onDropFiles = { [weak self] urls in
            // The pin is a capture-only surface: it always means Inbox, never "whatever row
            // happens to be selected in the window".
            _ = self?.capture(urls: urls, target: .inbox, source: .menuBarDrop)
        }
        menuBar.onOpen = { AppWindow.focusMain() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.install()
    }

    func detach() {
        menuBar.uninstall()
        model = nil
    }

    // MARK: - Capture

    /// Imports already-known file URLs. Connected unless told otherwise.
    @discardableResult
    func capture(
        urls: [URL],
        target: CaptureTarget,
        source: CaptureSource
    ) -> CaptureReport? {
        capture(urls: urls, mode: .connected, target: target, source: source)
    }

    @discardableResult
    func capture(
        urls: [URL],
        mode: ImportMode,
        target: CaptureTarget,
        source: CaptureSource
    ) -> CaptureReport? {
        guard !urls.isEmpty else { return nil }
        guard let library = model?.library else {
            present(CaptureBanner(text: "Library is not open yet", style: .failure))
            return nil
        }

        do {
            let report = try library.importURLs(urls, mode: mode, target: target)
            finish(report, source: source)
            return report
        } catch {
            present(CaptureBanner(text: "Import failed: \(error)", style: .failure))
            return nil
        }
    }

    /// ⌘V. Returns `nil` when the pasteboard held nothing importable, so the key event can
    /// fall through to whatever else wanted it.
    @discardableResult
    func capturePasteboard(target: CaptureTarget, pasteboard: NSPasteboard = .general) -> CaptureReport? {
        switch CapturePasteboard.read(from: pasteboard) {
        case .none:
            return nil
        case .files(let urls):
            return capture(urls: urls, target: target, source: .paste)
        case .image(let png):
            return captureImageData(png, target: target)
        }
    }

    /// Pasted bitmaps have no file to point at, so they are written to a scratch file and
    /// imported with `.copy`.
    ///
    /// The P1-E brief allowed "connected-or-copy"; this is the copy branch on purpose. A
    /// connected item would be keyed to a path under `$TMPDIR`, which the OS purges — the
    /// thumbnail would break within days. `.copy` makes the library own the bytes, and the
    /// scratch file is deleted immediately afterwards.
    @discardableResult
    func captureImageData(_ png: Data, target: CaptureTarget) -> CaptureReport? {
        let scratch: URL
        do {
            scratch = try CapturePasteboard.writeTemporaryPNG(
                png,
                directory: scratchDirectory,
                fileManager: fileManager
            )
        } catch {
            present(CaptureBanner(text: "Could not store pasted image: \(error)", style: .failure))
            return nil
        }
        defer { try? fileManager.removeItem(at: scratch) }
        return capture(urls: [scratch], mode: .copy, target: target, source: .paste)
    }

    // MARK: - Feedback

    func dismissBanner() {
        bannerTask?.cancel()
        bannerTask = nil
        banner = nil
    }

    /// Shared tail of every capture: refresh the model, then say what happened **once**.
    private func finish(_ report: CaptureReport, source: CaptureSource) {
        lastReport = report
        lastSource = source

        // Counts and the current query both move, so the sidebar badge and the grid refresh
        // from a single reload.
        model?.reloadAll()

        if source == .menuBarDrop {
            menuBar.flash(MenuBarCaptureItem.flashText(for: report))
        }

        // An empty batch (dropped a folder with no media in it) has nothing to report and
        // must not flash a useless banner.
        guard !report.isEmpty else { return }

        let style: CaptureBanner.Style
        if !report.errors.isEmpty {
            style = .failure
        } else if report.hasDuplicates {
            style = .notice
        } else {
            style = .success
        }
        present(CaptureBanner(text: report.summary, style: style))
    }

    private func present(_ banner: CaptureBanner) {
        bannerTask?.cancel()
        self.banner = banner
        let id = banner.id
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(CaptureBanner.visibleSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.banner?.id == id else { return }
            self.banner = nil
        }
    }
}
