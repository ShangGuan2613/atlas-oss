import AppKit
import QuartzCore

/// Opt-in frame-time probe for the grid (`ATLAS_SCROLL_PROBE=<seconds>`).
///
/// P1f has to answer "is a `LazyVGrid` + disk thumbnails good enough at 1k items, or does
/// the grid host need to become an `NSCollectionView`?" Answering that with a guess is how
/// you end up rewriting the grid for nothing. So the app can measure itself:
///
/// * a `CADisplayLink` on the scroll view's clip view ticks once per **drawn** frame — a
///   main thread that overruns simply misses a tick, which is exactly what a dropped frame
///   is;
/// * each tick nudges the scroll offset by `ATLAS_SCROLL_STEP` points (default 18 ≈ a fast
///   flick), bouncing at the ends, so the grid is continuously realizing and recycling
///   cells for the whole run;
/// * when the run ends it prints p50/p95/p99/max frame interval and the dropped-frame count,
///   then quits.
///
/// Deliberately *not* an animation-framework benchmark: no `CADisplayLink` smoothing, no
/// "target FPS". The number reported is the wall-clock gap between frames the system
/// actually asked us to draw.
@MainActor
final class GridScrollProbe {

    /// Set to the run length in seconds. Unset (the normal case) = probe disabled.
    static var requestedDuration: Double? {
        guard let raw = ProcessInfo.processInfo.environment["ATLAS_SCROLL_PROBE"],
              let seconds = Double(raw), seconds > 0 else { return nil }
        return seconds
    }

    static var isRequested: Bool { requestedDuration != nil }

    private weak var scroll: GridScrollController?
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var startedAt: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var direction: Double = 1
    private var lastOffset: CGFloat = 0
    private let step: Double
    private let duration: Double
    private var hasFinished = false

    init(scroll: GridScrollController, duration: Double, step: Double? = nil) {
        self.scroll = scroll
        self.duration = duration
        self.step = step ?? Double(ProcessInfo.processInfo.environment["ATLAS_SCROLL_STEP"] ?? "") ?? 18
    }

    /// Starts ticking. No-op when the scroll view is not attached yet.
    func start(on view: NSView) {
        guard link == nil else { return }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastOffset = scroll?.offset ?? 0
        print("P1F-SCROLL started: \(String(format: "%.1f", duration))s, step \(Int(step))pt/frame")
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if startedAt == 0 {
            startedAt = now
            lastTimestamp = now
            return
        }
        intervals.append(now - lastTimestamp)
        lastTimestamp = now

        guard let scroll else { return finish() }
        let target = scroll.offset + direction * step
        scroll.setOffset(target)
        // `setOffset` clamps at both ends; if the offset stopped moving we are at an edge.
        if abs(scroll.offset - lastOffset) < 0.5 { direction *= -1 }
        lastOffset = scroll.offset

        if now - startedAt >= duration { finish() }
    }

    private func finish() {
        guard !hasFinished else { return }
        hasFinished = true
        link?.invalidate()
        link = nil

        let measured = intervals
        guard !measured.isEmpty else {
            print("P1F-SCROLL no frames measured (window never drew)")
            flushAndExit()
            return
        }
        let sorted = measured.sorted()
        func percentile(_ p: Double) -> Double {
            let index = min(sorted.count - 1, max(0, Int((p / 100 * Double(sorted.count)).rounded(.up)) - 1))
            return sorted[index] * 1000
        }
        let elapsed = sorted.reduce(0, +)
        // The display refreshes every 16.67ms here, so a healthy interval *is* 16.67ms.
        // A dropped frame is one that took a second vsync slot, not one that rounded up.
        let vsync = 1.0 / 60.0
        let dropped = sorted.filter { $0 > vsync * 1.5 }.count

        print(String(
            format: "P1F-SCROLL frames=%d over=%.1fs avgFPS=%.1f p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms",
            sorted.count,
            elapsed,
            Double(sorted.count) / elapsed,
            percentile(50), percentile(95), percentile(99), (sorted.last ?? 0) * 1000
        ))
        print(String(
            format: "P1F-SCROLL vsync=60Hz frames-on-time=%d (%.1f%%) dropped>=2vsync(>25ms)=%d (%.1f%%)",
            sorted.count - dropped, Double(sorted.count - dropped) / Double(sorted.count) * 100,
            dropped, Double(dropped) / Double(sorted.count) * 100
        ))
        flushAndExit()
    }

    private func flushAndExit() {
        fflush(stdout)
        // The probe owns a throwaway library; quit instead of waiting for a human.
        exit(0)
    }
}
