import AppKit
import SwiftUI

// MARK: - Enumerated tokens

/// Background treatment for the content area.
///
/// Deliberately a closed set of three — Obsidian-style *named* tokens, not user CSS.
enum AppearanceBackgroundStyle: String, CaseIterable, Identifiable, Sendable {
    case system
    case subtle
    case solid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .subtle: return "Subtle"
        case .solid: return "Solid"
        }
    }
}

/// App-wide appearance override. `system` follows macOS.
enum AppearanceColorScheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` means "let the window decide" (i.e. follow the user's macOS setting).
    var swiftUI: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Tokens

/// The named design tokens every piece of chrome reads (P1-D, dimension C).
///
/// Exemplar: Obsidian's CSS variables — spacing, radius, background, selection and the
/// light/dark switch are *named values*, so the grid, sidebar and inspector can never
/// drift apart on a magic number. Not copied: user-authored CSS, theme marketplace.
///
/// Every token is clamped on write (including member-wise mutation and values restored
/// from disk), so a stale or hand-edited `UserDefaults` entry can never produce an
/// unusable layout. Defaults reproduce the P1-A/B/C chrome exactly:
/// `spacing == GridDensity.itemSpacing (14)` and `cornerRadius == 8`.
struct AppearanceTokens: Equatable {
    // MARK: Ranges & defaults

    static let spacingRange: ClosedRange<Double> = 4 ... 24
    static let cornerRadiusRange: ClosedRange<Double> = 0 ... 20
    static let selectionOpacityRange: ClosedRange<Double> = 0 ... 0.6

    static let defaultSpacing: Double = 14
    static let defaultCornerRadius: Double = 8
    static let defaultSelectionOpacity: Double = 0.14
    static let defaultBackgroundStyle: AppearanceBackgroundStyle = .system
    static let defaultColorScheme: AppearanceColorScheme = .system

    /// The grid gutter. Drives guttering, content padding, cell padding and caption gaps.
    var spacing: Double {
        didSet { spacing = Self.clampSpacing(spacing) }
    }

    /// Corner radius for tiles and inspector chrome.
    var cornerRadius: Double {
        didSet { cornerRadius = Self.clampCornerRadius(cornerRadius) }
    }

    var backgroundStyle: AppearanceBackgroundStyle
    var colorScheme: AppearanceColorScheme

    /// Fill opacity of the selection highlight (the accent ring keeps its own weight).
    var selectionOpacity: Double {
        didSet { selectionOpacity = Self.clampSelectionOpacity(selectionOpacity) }
    }

    init(
        spacing: Double = AppearanceTokens.defaultSpacing,
        cornerRadius: Double = AppearanceTokens.defaultCornerRadius,
        backgroundStyle: AppearanceBackgroundStyle = AppearanceTokens.defaultBackgroundStyle,
        colorScheme: AppearanceColorScheme = AppearanceTokens.defaultColorScheme,
        selectionOpacity: Double = AppearanceTokens.defaultSelectionOpacity
    ) {
        // `didSet` does not run during `init`, so clamp explicitly here too.
        self.spacing = Self.clampSpacing(spacing)
        self.cornerRadius = Self.clampCornerRadius(cornerRadius)
        self.backgroundStyle = backgroundStyle
        self.colorScheme = colorScheme
        self.selectionOpacity = Self.clampSelectionOpacity(selectionOpacity)
    }

    static let `default` = AppearanceTokens()

    // MARK: Clamping

    static func clampSpacing(_ value: Double) -> Double {
        clamp(value, to: spacingRange, fallback: defaultSpacing)
    }

    static func clampCornerRadius(_ value: Double) -> Double {
        clamp(value, to: cornerRadiusRange, fallback: defaultCornerRadius)
    }

    static func clampSelectionOpacity(_ value: Double) -> Double {
        clamp(value, to: selectionOpacityRange, fallback: defaultSelectionOpacity)
    }

    /// Non-finite input (`NaN`, `±infinity`) falls back to the token default instead of
    /// leaking into a layout pass, where it would trap or collapse the grid.
    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    // MARK: Derived tokens

    /// Padding around the grid content. Trails `spacing` so density stays proportional;
    /// `14 → 16` keeps the P1-A look byte-identical at defaults.
    var contentPadding: Double { spacing + 2 }

    /// Sidebar row / chip radius. `8 → 5`, matching the P1-B sidebar.
    var innerRadius: Double { max(0, cornerRadius - 3) }

    /// Inspector preview / large surface radius. `8 → 10`.
    var largeRadius: Double { cornerRadius + 2 }

    /// Padding inside a tile (caption gap). `14 → 5`.
    var cellPadding: Double { max(2, (spacing / 3).rounded()) }

    /// Inset between a thumbnail and its tile frame. `14 → 4`.
    var thumbnailInset: Double { max(1, cellPadding - 1) }

    /// Sidebar row height, so density changes reach the tree too.
    var sidebarRowHeight: Double { max(18, 26 + (spacing - 14) * 0.5) }

    // MARK: Colour tokens

    /// Semantic AppKit colour behind the content area.
    ///
    /// `system` is the window's own colour (and `backgroundFill` is `nil`, so the window is
    /// left untouched). `subtle` is the system's slightly recessed page tone; `solid` is a
    /// deliberately darker flat panel, because `.windowBackgroundColor` and
    /// `.textBackgroundColor` resolve to the *same* white in light mode — three names for
    /// one colour would make the picker lie.
    var backgroundNSColor: NSColor {
        switch backgroundStyle {
        case .system: return .windowBackgroundColor
        case .subtle: return .underPageBackgroundColor
        case .solid: return NSColor.windowBackgroundColor.blended(withFraction: 0.08, of: .black) ?? .textBackgroundColor
        }
    }

    /// SwiftUI fill for the grid backdrop; `nil` leaves the window background untouched.
    var backgroundFill: Color? {
        backgroundStyle == .system ? nil : Color(nsColor: backgroundNSColor)
    }
}

// MARK: - Persistence

extension AppearanceTokens {
    /// `UserDefaults` keys. Namespaced and stable: they are the on-disk contract for
    /// remembering appearance across launches (no separate settings file).
    enum Key {
        static let spacing = "appearance.spacing"
        static let cornerRadius = "appearance.cornerRadius"
        static let backgroundStyle = "appearance.backgroundStyle"
        static let colorScheme = "appearance.colorScheme"
        static let selectionOpacity = "appearance.selectionOpacity"

        static let all = [spacing, cornerRadius, backgroundStyle, colorScheme, selectionOpacity]
    }

    /// Restores tokens, clamping whatever is on disk and falling back to the default for
    /// any missing or unparseable entry.
    init(defaults: UserDefaults) {
        self.init(
            spacing: Self.storedDouble(defaults, Key.spacing) ?? Self.defaultSpacing,
            cornerRadius: Self.storedDouble(defaults, Key.cornerRadius) ?? Self.defaultCornerRadius,
            backgroundStyle: (defaults.string(forKey: Key.backgroundStyle)
                .flatMap(AppearanceBackgroundStyle.init(rawValue:))) ?? Self.defaultBackgroundStyle,
            colorScheme: (defaults.string(forKey: Key.colorScheme)
                .flatMap(AppearanceColorScheme.init(rawValue:))) ?? Self.defaultColorScheme,
            selectionOpacity: Self.storedDouble(defaults, Key.selectionOpacity) ?? Self.defaultSelectionOpacity
        )
    }

    func write(to defaults: UserDefaults) {
        defaults.set(spacing, forKey: Key.spacing)
        defaults.set(cornerRadius, forKey: Key.cornerRadius)
        defaults.set(backgroundStyle.rawValue, forKey: Key.backgroundStyle)
        defaults.set(colorScheme.rawValue, forKey: Key.colorScheme)
        defaults.set(selectionOpacity, forKey: Key.selectionOpacity)
    }

    /// `object(forKey:)` rather than `double(forKey:)`: a stored `0` (a legal radius) must
    /// not be mistaken for "absent".
    private static func storedDouble(_ defaults: UserDefaults, _ key: String) -> Double? {
        switch defaults.object(forKey: key) {
        case let number as NSNumber: return number.doubleValue
        case let value as Double: return value
        default: return nil
        }
    }
}

// MARK: - Environment injection

private struct AppearanceTokensKey: EnvironmentKey {
    static let defaultValue = AppearanceTokens.default
}

extension EnvironmentValues {
    /// Reads the current appearance tokens. Views never take a token as a parameter, so a
    /// settings change re-renders the whole tree without recreating a window.
    var appearance: AppearanceTokens {
        get { self[AppearanceTokensKey.self] }
        set { self[AppearanceTokensKey.self] = newValue }
    }
}

// MARK: - Store

/// Owns the live tokens and write-through persistence.
///
/// A single `@StateObject` in the `App` (not one `@AppStorage` per view) so that a change
/// made in the Settings window reaches the main window through the environment in the same
/// run loop — no relaunch, and no window recreation, so there is no white flash on a
/// light/dark flip.
final class AppearanceStore: ObservableObject {
    @Published var tokens: AppearanceTokens {
        didSet { tokens.write(to: defaults) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.tokens = AppearanceTokens(defaults: defaults)
    }

    func reset() {
        tokens = .default
    }

    // MARK: Test seam

    /// A store backed by a throwaway suite, for tests and offscreen renders.
    static func ephemeral(suiteName: String) -> AppearanceStore {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return AppearanceStore(defaults: defaults)
    }
}
