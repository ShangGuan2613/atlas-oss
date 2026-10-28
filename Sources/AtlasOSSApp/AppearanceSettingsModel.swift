import Foundation

// MARK: - Settings catalogue

/// Which block of the Appearance page a row belongs to. Order is the page order.
enum AppearanceSection: String, CaseIterable, Identifiable, Sendable {
    case density
    case shape
    case color
    case preview
    case manage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .density: return "Layout"
        case .shape: return "Shape"
        case .color: return "Color"
        case .preview: return "Preview"
        case .manage: return "Manage"
        }
    }
}

/// One searchable control on the Appearance page.
///
/// The catalogue is data, not view code, so the search filter is a pure function that can
/// be tested without rendering — the same reason the grid maths lives in `GridDensity`.
enum AppearanceSetting: String, CaseIterable, Identifiable, Sendable {
    case spacing
    case cornerRadius
    case selectionOpacity
    case backgroundStyle
    case colorScheme
    case preview
    case reset

    var id: String { rawValue }

    var section: AppearanceSection {
        switch self {
        case .spacing: return .density
        case .cornerRadius: return .shape
        case .selectionOpacity, .backgroundStyle, .colorScheme: return .color
        case .preview: return .preview
        case .reset: return .manage
        }
    }

    var title: String {
        switch self {
        case .spacing: return "Grid spacing"
        case .cornerRadius: return "Corner radius"
        case .selectionOpacity: return "Selection highlight"
        case .backgroundStyle: return "Content background"
        case .colorScheme: return "Color scheme"
        case .preview: return "Live preview"
        case .reset: return "Reset appearance"
        }
    }

    /// Extra words a user might type instead of the title (VS Code calls these aliases).
    var keywords: [String] {
        switch self {
        case .spacing: return ["gutter", "gap", "padding", "density", "grid", "tile", "margin", "spacing"]
        case .cornerRadius: return ["radius", "round", "rounded", "corners", "tile", "shape", "chrome"]
        case .selectionOpacity: return ["selection", "selected", "highlight", "opacity", "accent"]
        case .backgroundStyle: return ["background", "bg", "style", "surface", "fill", "window", "panel"]
        case .colorScheme: return ["appearance", "mode", "light", "dark", "theme", "scheme", "night", "system"]
        case .preview: return ["preview", "sample", "example", "tokens"]
        case .reset: return ["reset", "default", "defaults", "restore", "clear"]
        }
    }

    /// One-line explanation shown under the control.
    var summary: String {
        switch self {
        case .spacing: return "Gutter between tiles, plus the padding around the grid and inspector."
        case .cornerRadius: return "Rounded corners on grid tiles, sidebar rows and the preview."
        case .selectionOpacity: return "Fill opacity of the accent wash behind selected items."
        case .backgroundStyle: return "Backdrop behind the grid: follow the system, a subtle wash, or a solid surface."
        case .colorScheme: return "Force light or dark, or follow macOS. Applied without restarting."
        case .preview: return "A strip that uses the live tokens, so every change is visible here first."
        case .reset: return "Restore the shipping defaults for every appearance token."
        }
    }
}

/// One section's visible rows. A struct (not a tuple) so `ForEach` can identify it.
struct AppearanceSectionGroup: Identifiable, Equatable, Sendable {
    let section: AppearanceSection
    let settings: [AppearanceSetting]

    var id: AppearanceSection { section }
}

// MARK: - Search

/// Pure settings search (VS Code-style).
///
/// Multi-word queries are AND-ed; each word may match any word of the title, the aliases,
/// the section name or the summary. That is enough to make "spacing" jump straight to the
/// spacing control, "dark" to the color scheme and "round" to the corner radius, without
/// pulling in a dependency.
enum SettingsSearch {
    /// Lowercased words, with `camelCase` split so a query of `cornerRadius` behaves like
    /// `corner radius` and an all-caps query (`SPACING`) stays one word.
    static func words(_ text: String) -> [String] {
        var spaced = ""
        var previousWasLower = false
        for character in text {
            if character.isUppercase, previousWasLower { spaced.append(" ") }
            spaced.append(character)
            previousWasLower = character.isLowercase || character.isNumber
        }
        return spaced.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Everything a query is matched against for one row. The raw value is included so the
    /// catalogue's own identifiers (`cornerRadius`) always resolve to their row.
    static func haystack(for setting: AppearanceSetting) -> [String] {
        words(
            ([setting.title, setting.rawValue, setting.section.title, setting.summary] + setting.keywords)
                .joined(separator: " ")
        )
    }

    static func matches(_ setting: AppearanceSetting, query: String) -> Bool {
        let terms = words(query)
        guard !terms.isEmpty else { return true }
        let haystack = haystack(for: setting)
        let joined = haystack.joined()
        return terms.allSatisfy { term in
            haystack.contains { $0.contains(term) } || joined.contains(term)
        }
    }

    /// Matching rows, in catalogue order.
    static func filter(_ query: String, in settings: [AppearanceSetting] = AppearanceSetting.allCases) -> [AppearanceSetting] {
        let terms = words(query)
        guard !terms.isEmpty else { return settings }
        return settings.filter { matches($0, query: query) }
    }

    /// Matching rows grouped into their sections, empty sections dropped. The view renders
    /// exactly this, so search and page order can never disagree.
    static func sections(_ query: String) -> [AppearanceSectionGroup] {
        let hits = filter(query)
        return AppearanceSection.allCases.compactMap { section in
            let rows = hits.filter { $0.section == section }
            return rows.isEmpty ? nil : AppearanceSectionGroup(section: section, settings: rows)
        }
    }

    /// Id of the row a query should scroll to, if any.
    static func firstMatch(_ query: String) -> AppearanceSetting? {
        filter(query).first
    }
}
