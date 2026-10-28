import AppKit
import Combine
import SwiftUI
import XCTest
@testable import AtlasOSSApp

/// Pure-logic coverage for the P1-D appearance tokens: clamping, derived tokens that keep
/// the P1-A/B/C look at defaults, persistence round-trips, and the settings search filter.
final class AppearanceTests: XCTestCase {

    // MARK: - Defaults match the shipped chrome

    func testDefaultTokensReproduceP1Chrome() {
        let tokens = AppearanceTokens.default
        // The grid gutter and content padding must equal the P1-A constants, so adding
        // tokens is invisible until the user moves a slider.
        XCTAssertEqual(tokens.spacing, GridDensity.itemSpacing)
        XCTAssertEqual(tokens.contentPadding, GridDensity.contentPadding)
        XCTAssertEqual(tokens.cornerRadius, 8)
        XCTAssertEqual(tokens.innerRadius, 5)        // P1-B sidebar rows
        XCTAssertEqual(tokens.largeRadius, 10)       // P1-C inspector preview
        XCTAssertEqual(tokens.cellPadding, 5)        // tile caption gap
        XCTAssertEqual(tokens.thumbnailInset, 4)     // thumbnail inset inside a tile
        XCTAssertEqual(tokens.sidebarRowHeight, 26)  // P1-B row height
        XCTAssertEqual(tokens.backgroundStyle, .system)
        XCTAssertEqual(tokens.colorScheme, .system)
        XCTAssertNil(tokens.backgroundFill, "system background must leave the window alone")
    }

    func testDerivedTokensFollowTheirSource() {
        let dense = AppearanceTokens(spacing: 4, cornerRadius: 0)
        XCTAssertEqual(dense.contentPadding, 6)
        XCTAssertGreaterThanOrEqual(dense.cellPadding, 2, "cell padding never collapses to 0")
        XCTAssertEqual(dense.innerRadius, 0)
        XCTAssertLessThan(dense.sidebarRowHeight, 26)

        let roomy = AppearanceTokens(spacing: 24, cornerRadius: 20)
        XCTAssertEqual(roomy.contentPadding, 26)
        XCTAssertEqual(roomy.innerRadius, 17)
        XCTAssertEqual(roomy.largeRadius, 22)
        XCTAssertGreaterThan(roomy.sidebarRowHeight, 26)
    }

    func testDensityMathHonoursTokenSpacing() {
        // Column count and exact grid width must both use the token gutter, otherwise the
        // P1-A pointer anchor drifts the moment spacing changes.
        let wideGutter = GridDensity.columns(availableWidth: 1000, cellWidth: 200, spacing: 24, padding: 26)
        let tightGutter = GridDensity.columns(availableWidth: 1000, cellWidth: 200, spacing: 4, padding: 6)
        XCTAssertGreaterThanOrEqual(tightGutter, wideGutter)

        XCTAssertEqual(
            GridDensity.gridWidth(columns: 3, cellWidth: 200, spacing: 24),
            200 * 3 + 24 * 2
        )
    }

    // MARK: - Clamping

    func testClampBoundsAndNonFiniteInput() {
        XCTAssertEqual(AppearanceTokens.clampSpacing(0), AppearanceTokens.spacingRange.lowerBound)
        XCTAssertEqual(AppearanceTokens.clampSpacing(10_000), AppearanceTokens.spacingRange.upperBound)
        XCTAssertEqual(AppearanceTokens.clampSpacing(18), 18)

        XCTAssertEqual(AppearanceTokens.clampCornerRadius(-4), 0)
        XCTAssertEqual(AppearanceTokens.clampCornerRadius(999), 20)

        XCTAssertEqual(AppearanceTokens.clampSelectionOpacity(-1), 0)
        XCTAssertEqual(AppearanceTokens.clampSelectionOpacity(9), 0.6)

        // Non-finite values fall back to the default rather than poisoning a layout pass.
        XCTAssertEqual(AppearanceTokens.clampSpacing(.nan), AppearanceTokens.defaultSpacing)
        XCTAssertEqual(AppearanceTokens.clampSpacing(.infinity), AppearanceTokens.defaultSpacing)
        XCTAssertEqual(AppearanceTokens.clampCornerRadius(-.infinity), AppearanceTokens.defaultCornerRadius)
        XCTAssertEqual(AppearanceTokens.clampSelectionOpacity(.nan), AppearanceTokens.defaultSelectionOpacity)
    }

    func testInitialiserClampsEveryToken() {
        let tokens = AppearanceTokens(spacing: -3, cornerRadius: 100, selectionOpacity: 4)
        XCTAssertEqual(tokens.spacing, AppearanceTokens.spacingRange.lowerBound)
        XCTAssertEqual(tokens.cornerRadius, AppearanceTokens.cornerRadiusRange.upperBound)
        XCTAssertEqual(tokens.selectionOpacity, AppearanceTokens.selectionOpacityRange.upperBound)
    }

    func testMemberMutationIsClamped() {
        // Sliders bind straight to members, so the `didSet` clamps must be live.
        var tokens = AppearanceTokens.default
        tokens.spacing = 1_000
        XCTAssertEqual(tokens.spacing, 24)
        tokens.spacing = 1
        XCTAssertEqual(tokens.spacing, 4)

        tokens.cornerRadius = -10
        XCTAssertEqual(tokens.cornerRadius, 0, "0 is a legal radius and must survive")

        tokens.selectionOpacity = 12
        XCTAssertEqual(tokens.selectionOpacity, 0.6)
        tokens.selectionOpacity = 0
        XCTAssertEqual(tokens.selectionOpacity, 0)
    }

    func testEquatableDistinguishesEveryToken() {
        XCTAssertEqual(AppearanceTokens.default, AppearanceTokens())
        XCTAssertNotEqual(AppearanceTokens(spacing: 16), AppearanceTokens(spacing: 14))
        XCTAssertNotEqual(AppearanceTokens(cornerRadius: 4), AppearanceTokens(cornerRadius: 8))
        XCTAssertNotEqual(AppearanceTokens(backgroundStyle: .solid), AppearanceTokens(backgroundStyle: .subtle))
        XCTAssertNotEqual(AppearanceTokens(colorScheme: .dark), AppearanceTokens(colorScheme: .light))
        XCTAssertNotEqual(AppearanceTokens(selectionOpacity: 0.4), AppearanceTokens())
    }

    func testBackgroundStylesMapToDistinctColours() {
        XCTAssertNil(AppearanceTokens(backgroundStyle: .system).backgroundFill)
        XCTAssertNotNil(AppearanceTokens(backgroundStyle: .subtle).backgroundFill)
        XCTAssertNotNil(AppearanceTokens(backgroundStyle: .solid).backgroundFill)

        // The two *painted* styles must be visibly different surfaces: three names for one
        // white would make the picker lie.
        for style in AppearanceBackgroundStyle.allCases {
            XCTAssertNotNil(
                AppearanceTokens(backgroundStyle: style).backgroundNSColor.usingColorSpace(.sRGB),
                "\(style.rawValue) must resolve to a concrete colour"
            )
        }
        XCTAssertNotEqual(
            srgbTriple(AppearanceTokens(backgroundStyle: .subtle).backgroundNSColor),
            srgbTriple(AppearanceTokens(backgroundStyle: .solid).backgroundNSColor)
        )
    }

    func testColorSchemeOverrideMapsToSwiftUI() {
        XCTAssertNil(AppearanceColorScheme.system.swiftUI)
        XCTAssertEqual(AppearanceColorScheme.light.swiftUI, .light)
        XCTAssertEqual(AppearanceColorScheme.dark.swiftUI, .dark)
    }

    // MARK: - Persistence

    func testRoundTripThroughUserDefaults() throws {
        let defaults = try makeDefaults()
        let tokens = AppearanceTokens(
            spacing: 20,
            cornerRadius: 0,
            backgroundStyle: .solid,
            colorScheme: .dark,
            selectionOpacity: 0.32
        )
        tokens.write(to: defaults)

        XCTAssertEqual(AppearanceTokens(defaults: defaults), tokens)
    }

    func testMissingKeysFallBackToDefaults() throws {
        let defaults = try makeDefaults()
        XCTAssertEqual(AppearanceTokens(defaults: defaults), AppearanceTokens.default)
    }

    func testCorruptStoredValuesAreClampedOrIgnored() throws {
        let defaults = try makeDefaults()
        defaults.set(9_999.0, forKey: AppearanceTokens.Key.spacing)
        defaults.set(-40.0, forKey: AppearanceTokens.Key.cornerRadius)
        defaults.set("neon", forKey: AppearanceTokens.Key.backgroundStyle)
        defaults.set("sepia", forKey: AppearanceTokens.Key.colorScheme)
        defaults.set(Double.nan, forKey: AppearanceTokens.Key.selectionOpacity)

        let tokens = AppearanceTokens(defaults: defaults)
        XCTAssertEqual(tokens.spacing, 24)
        XCTAssertEqual(tokens.cornerRadius, 0)
        XCTAssertEqual(tokens.backgroundStyle, .system)
        XCTAssertEqual(tokens.colorScheme, .system)
        XCTAssertEqual(tokens.selectionOpacity, AppearanceTokens.defaultSelectionOpacity)
    }

    func testStorePersistsAndResets() throws {
        let defaults = try makeDefaults()
        let store = AppearanceStore(defaults: defaults)

        store.tokens.spacing = 22
        store.tokens.colorScheme = .dark
        XCTAssertEqual(defaults.double(forKey: AppearanceTokens.Key.spacing), 22, "write-through")
        XCTAssertEqual(defaults.string(forKey: AppearanceTokens.Key.colorScheme), "dark")

        // A fresh store (next launch) sees the persisted values.
        XCTAssertEqual(AppearanceStore(defaults: defaults).tokens.spacing, 22)

        store.reset()
        XCTAssertEqual(store.tokens, .default)
        XCTAssertEqual(AppearanceStore(defaults: defaults).tokens, .default)
    }

    func testStoreClampsBeforeWriting() throws {
        let defaults = try makeDefaults()
        let store = AppearanceStore(defaults: defaults)
        store.tokens.spacing = 500
        XCTAssertEqual(store.tokens.spacing, 24)
        XCTAssertEqual(defaults.double(forKey: AppearanceTokens.Key.spacing), 24)
    }

    func testNestedTokenMutationPublishesSoTheUIRefreshes() throws {
        // The live-apply contract: sliders mutate a *member* of a published struct, so the
        // observation must fire for the main window to re-render without a restart.
        let store = AppearanceStore(defaults: try makeDefaults())
        var notifications = 0
        let token = store.objectWillChange.sink { notifications += 1 }

        store.tokens.spacing = 18
        store.tokens.colorScheme = .dark
        store.tokens.selectionOpacity = 0.3

        XCTAssertEqual(notifications, 3, "every token change must notify observers")
        withExtendedLifetime(token) {}
    }

    func testEnvironmentDefaultIsTheShippingLook() {
        XCTAssertEqual(EnvironmentValues().appearance, AppearanceTokens.default)
    }

    // MARK: - Settings search

    func testEmptyQueryShowsEverythingInPageOrder() {
        XCTAssertEqual(SettingsSearch.filter(""), AppearanceSetting.allCases)
        XCTAssertEqual(SettingsSearch.filter("   "), AppearanceSetting.allCases)
        XCTAssertEqual(SettingsSearch.sections("").flatMap(\.settings), AppearanceSetting.allCases)
        XCTAssertEqual(SettingsSearch.sections("").map(\.section), AppearanceSection.allCases)
    }

    func testTypingSpacingRevealsTheSpacingControl() {
        // The acceptance criterion, verbatim.
        XCTAssertEqual(SettingsSearch.filter("spacing"), [.spacing])
        XCTAssertEqual(SettingsSearch.firstMatch("spacing"), .spacing)
        XCTAssertEqual(SettingsSearch.sections("spacing").first?.section, .density)
    }

    func testAliasesResolveToTheirControl() {
        for query in ["gutter", "gap", "padding", "density", "margin"] {
            XCTAssertTrue(SettingsSearch.matches(.spacing, query: query), query)
        }
        for query in ["corner", "radius", "round", "corners"] {
            XCTAssertTrue(SettingsSearch.matches(.cornerRadius, query: query), query)
        }
        XCTAssertTrue(SettingsSearch.matches(.backgroundStyle, query: "bg"))
        XCTAssertTrue(SettingsSearch.matches(.backgroundStyle, query: "surface"))
        XCTAssertTrue(SettingsSearch.matches(.colorScheme, query: "dark"))
        XCTAssertTrue(SettingsSearch.matches(.colorScheme, query: "theme"))
        XCTAssertTrue(SettingsSearch.matches(.reset, query: "restore"))
        XCTAssertTrue(SettingsSearch.matches(.selectionOpacity, query: "highlight"))
    }

    func testSearchIsCaseInsensitiveAndTrimsPunctuation() {
        XCTAssertEqual(SettingsSearch.filter("  SPACING "), [.spacing])
        XCTAssertEqual(SettingsSearch.filter("corner-radius"), [.cornerRadius])
    }

    func testMultiWordQueriesAreAnded() {
        XCTAssertEqual(SettingsSearch.filter("grid spacing"), [.spacing])
        XCTAssertEqual(SettingsSearch.filter("grid radius"), [.cornerRadius])
        XCTAssertTrue(SettingsSearch.filter("grid zebra").isEmpty)
    }

    func testNoMatchYieldsEmptyResults() {
        XCTAssertTrue(SettingsSearch.filter("zzzzz").isEmpty)
        XCTAssertTrue(SettingsSearch.sections("zzzzz").isEmpty)
        XCTAssertNil(SettingsSearch.firstMatch("zzzzz"))
    }

    func testSectionsNeverContainEmptyGroups() {
        for group in SettingsSearch.sections("radius") {
            XCTAssertFalse(group.settings.isEmpty)
            XCTAssertTrue(group.settings.allSatisfy { $0.section == group.section })
        }
        XCTAssertEqual(SettingsSearch.sections("radius").count, 1)
    }

    func testEverySettingIsFindableByItsOwnTitle() {
        for setting in AppearanceSetting.allCases {
            XCTAssertTrue(SettingsSearch.matches(setting, query: setting.title), setting.title)
            XCTAssertTrue(SettingsSearch.matches(setting, query: setting.rawValue), setting.rawValue)
        }
    }

    // MARK: - Helpers

    /// Resolved sRGB triple at 1/1000 resolution, for comparing two system colours.
    private func srgbTriple(_ colour: NSColor) -> [Int] {
        guard let srgb = colour.usingColorSpace(.sRGB) else { return [] }
        return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent]
            .map { Int(($0 * 1_000).rounded()) }
    }

    /// A throwaway defaults suite, cleaned up when the test ends.
    private func makeDefaults() throws -> UserDefaults {
        let suite = "atlas.appearance.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        return defaults
    }
}
