import AppKit
import SwiftUI

/// Local event monitor for the grid.
///
/// Two things SwiftUI on macOS 14 cannot do natively: intercept ⌘-scroll (no scroll
/// wheel API) and receive arrow/Space keys without a focused control swallowing them.
/// Handlers return `true` to consume the event, `false` to let it through untouched.
@MainActor
final class GridEventMonitor: ObservableObject {
    var handleKey: ((NSEvent) -> Bool)?
    /// Key-up is only needed by the Canvas, where Space is a held modifier (pan-armed) rather
    /// than a one-shot shortcut. Optional, so the grid's behaviour is unchanged.
    var handleKeyUp: ((NSEvent) -> Bool)?
    var handleScroll: ((NSEvent) -> Bool)?

    private var tokens: [Any] = []

    func start() {
        guard tokens.isEmpty else { return }

        if let token = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, let handleKey = self.handleKey else { return event }
            return handleKey(event) ? nil : event
        }) {
            tokens.append(token)
        }

        if let token = NSEvent.addLocalMonitorForEvents(matching: .keyUp, handler: { [weak self] event in
            guard let self, let handleKeyUp = self.handleKeyUp else { return event }
            return handleKeyUp(event) ? nil : event
        }) {
            tokens.append(token)
        }

        if let token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            guard let self, let handleScroll = self.handleScroll else { return event }
            return handleScroll(event) ? nil : event
        }) {
            tokens.append(token)
        }
    }

    func stop() {
        for token in tokens {
            NSEvent.removeMonitor(token)
        }
        tokens.removeAll()
    }
}

/// Key codes used by the grid (layout independent, unlike `characters`).
enum GridKey {
    static let space: UInt16 = 49
    static let escape: UInt16 = 53
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
}
