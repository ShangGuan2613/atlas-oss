import AppKit
import SwiftUI

/// SwiftUI's `ScrollView` exposes no scroll offset on macOS 14, so a zero-size probe
/// mounted inside the scroll content reaches the enclosing `NSScrollView` and the
/// controller drives `bounds.origin.y` directly.
///
/// Needed twice in P1-A: pointer-anchored zoom (scroll by the layout delta) and
/// restoring the grid's position after the lightbox closes.
///
/// `offset` is intentionally *not* `@Published` — it changes on every scroll tick and
/// the grid must not re-render for it; callers read it imperatively.
@MainActor
final class GridScrollController: ObservableObject {
    private(set) var offset: CGFloat = 0
    private(set) var isAttached = false

    /// The grid's `NSScrollView`, for the optional frame probe (P1f). Read-only.
    var attachedScrollView: NSScrollView? { scrollView }

    private weak var scrollView: NSScrollView?
    private var observer: NSObjectProtocol?

    func attach(_ view: NSScrollView?) {
        guard view !== scrollView else { return }
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }

        scrollView = view
        isAttached = view != nil
        guard let view else {
            offset = 0
            return
        }

        let clipView = view.contentView
        clipView.postsBoundsChangedNotifications = true
        offset = clipView.bounds.origin.y
        observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self, weak clipView] _ in
            MainActor.assumeIsolated {
                guard let clipView else { return }
                self?.offset = clipView.bounds.origin.y
            }
        }
    }

    /// Scrolls to a vertical offset, clamped to the document's scrollable range.
    func setOffset(_ y: CGFloat, animated: Bool = false) {
        guard let scrollView else { return }
        let clipView = scrollView.contentView
        let documentHeight = max(
            scrollView.documentView?.frame.height ?? 0,
            scrollView.documentView?.bounds.height ?? 0
        )
        let maxY = max(0, documentHeight - clipView.bounds.height)
        let clamped = min(max(0, y), maxY)
        guard abs(clamped - clipView.bounds.origin.y) > 0.5 else { return }

        let point = NSPoint(x: clipView.bounds.origin.x, y: clamped)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                clipView.animator().setBoundsOrigin(point)
            }
            scrollView.reflectScrolledClipView(clipView)
        } else {
            clipView.scroll(to: point)
            scrollView.reflectScrolledClipView(clipView)
        }
        offset = clamped
    }
}

/// Invisible bridge that hands the grid's `NSScrollView` to `GridScrollController`.
struct ScrollOffsetBridge: NSViewRepresentable {
    let controller: GridScrollController

    func makeNSView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.onResolve = { [weak controller] scrollView in
            controller?.attach(scrollView)
        }
        return view
    }

    func updateNSView(_ nsView: BridgeView, context: Context) {
        nsView.onResolve = { [weak controller] scrollView in
            controller?.attach(scrollView)
        }
        nsView.resolve()
    }

    final class BridgeView: NSView {
        var onResolve: ((NSScrollView?) -> Void)?

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolve()
        }

        func resolve() {
            onResolve?(enclosingScrollView)
        }

        /// Transparent to the mouse: clicks belong to the cells underneath.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
