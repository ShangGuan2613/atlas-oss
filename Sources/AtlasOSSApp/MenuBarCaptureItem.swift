import AppKit
import AtlasCore
import Foundation

/// The menu-bar capture pin (P1-E).
///
/// Exemplar: Atlas's menu-bar pin and the classic `BCStatusItem` droplet pattern — a
/// template `NSStatusItem` that accepts a file drag and reports it. Not copied: the Share
/// Extension store flow, a stack preview of pending items, and anything that needs an app
/// bundle with a bundle identifier.
///
/// `NSStatusItem.button` cannot be re-classed, so the drop surface is a transparent subview
/// pinned to the button. Transparent matters twice: it receives the drag (hit-testing) and
/// it draws nothing, so the button's own symbol and flash title stay visible underneath.
@MainActor
final class MenuBarCaptureItem: NSObject {

    /// SF Symbol used as the template image — an AppKit system symbol, not an Atlas asset.
    static let symbolName = "tray.and.arrow.down"
    /// How long the status title flashes after a drop. The requirement is "visible <500ms";
    /// the *change* is immediate, this is only how long it stays.
    static let flashSeconds: Double = 1.8

    var onDropFiles: (([URL]) -> Void)?
    var onOpen: (() -> Void)?
    var onQuit: (() -> Void)?

    private(set) var isInstalled = false

    private var item: NSStatusItem?
    private var dropView: StatusDropView?
    private var flashTask: Task<Void, Never>?
    private var terminateObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    /// Adds the item to the system status bar. Idempotent.
    func install() {
        guard !isInstalled else { return }

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: Self.symbolName, accessibilityDescription: "AtlasOSS capture")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.toolTip = "Drop files here to add them to the Inbox"

            let view = StatusDropView(frame: button.bounds)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.onFiles = { [weak self] urls in self?.onDropFiles?(urls) }
            view.onTargetedChange = { [weak view] targeted in view?.isHighlighted = targeted }
            view.onClick = { [weak self] in self?.onOpen?() }
            view.onRightClick = { [weak self] in self?.showMenu() }
            button.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                view.topAnchor.constraint(equalTo: button.topAnchor),
                view.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            dropView = view
        }

        // Removing the item on quit is required behaviour; the notification is a belt-and-
        // braces guarantee for the (common) case where the process tears down without our
        // `uninstall()` being called.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.uninstall() }
        }

        item = statusItem
        isInstalled = true
    }

    func uninstall() {
        flashTask?.cancel()
        flashTask = nil
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
        terminateObserver = nil
        if let item {
            NSStatusBar.system.removeStatusItem(item)
        }
        item = nil
        dropView = nil
        isInstalled = false
    }

    // MARK: - Feedback

    /// Transient status: the item's title flashes the outcome, then clears.
    ///
    /// A notification would need `UNUserNotificationCenter` plus a real bundle identifier,
    /// which an SPM executable does not have; a title flash is the primitive that works
    /// everywhere and is measurable ("did the menu bar change within 500ms").
    func flash(_ text: String) {
        guard let button = item?.button else { return }
        flashTask?.cancel()
        button.title = " " + text
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.flashSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.item?.button?.title = ""
        }
    }

    /// Compact status token for a batch.
    static func flashText(for report: CaptureReport) -> String {
        if report.imported > 0 { return "+\(report.imported)" }
        if report.alreadyPresent > 0 { return "\(report.alreadyPresent) dup" }
        if !report.errors.isEmpty || report.skipped > 0 { return "!" }
        return "0"
    }

    // MARK: - Menu

    /// Right-click menu. The only way out of a windowless state, and the discoverable
    /// "Quit", so the pin never becomes an unkillable background process.
    private func showMenu() {
        guard let item else { return }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open AtlasOSS", action: #selector(menuOpen), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit AtlasOSS", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Attach, click, detach: `NSStatusItem.menu` replaces the click action, so leaving it
        // installed would make left-click open the menu instead of the window.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func menuOpen() { onOpen?() }
    @objc private func menuQuit() { onQuit?() }
}

// MARK: - Drop surface

/// Drag destination laid over the status item button, plus the click targets.
///
/// Transparent matters twice: it receives the drag (registration lives in `FileDropNSView`)
/// and it draws nothing when idle, so the button's own symbol and flash title stay visible
/// underneath.
final class StatusDropView: FileDropNSView {
    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    /// Set from `onTargetedChange`, so the drag highlight is the view's own business.
    var isHighlighted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4).fill()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}

// MARK: - Window plumbing

/// Bringing the main window forward from AppKit land (the status item is outside the
/// SwiftUI scene tree, so it has no `openWindow` environment).
@MainActor
enum AppWindow {
    static func focusMain() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let candidates = NSApp.windows.filter { $0.canBecomeMain && !($0 is NSPanel) }
        let window = candidates.first { $0.title == "AtlasOSS" }
            ?? candidates.first { $0.isVisible }
            ?? candidates.first
        window?.makeKeyAndOrderFront(nil)
    }
}
