import AppKit
import SwiftUI

/// Appearance page (P1-D, dimension C).
///
/// VS Code's settings-search pattern, not a megamenu: one search field, one page, and
/// typing "spacing" scrolls the spacing control into view. Every control writes straight
/// into `AppearanceStore`, which re-injects the tokens into the main window — changes are
/// live, no relaunch, and a light/dark flip only re-tints the existing window.
struct AppearanceSettingsView: View {
    @EnvironmentObject private var store: AppearanceStore

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var tokens: AppearanceTokens { store.tokens }

    private var rows: [AppearanceSectionGroup] {
        SettingsSearch.sections(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            results
            Divider()
            footer
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 520, idealHeight: 640)
        .background(tokens.backgroundFill ?? Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(tokens.colorScheme.swiftUI)
        .onAppear { searchFocused = true }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Search appearance settings", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }

            Text("\(SettingsSearch.filter(query).count)")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .help("Matching settings")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: tokens.innerRadius))
        .padding(tokens.contentPadding)
    }

    // MARK: - Rows

    @ViewBuilder
    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: tokens.spacing) {
                    if rows.isEmpty {
                        noResults
                    } else {
                        ForEach(rows) { group in
                            VStack(alignment: .leading, spacing: tokens.cellPadding) {
                                sectionHeader(group.section.title)
                                ForEach(group.settings) { setting in
                                    settingRow(setting)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, tokens.contentPadding)
                .padding(.bottom, tokens.contentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: query) { _, newValue in
                // Jump to the first hit, so "spacing" lands on the spacing slider.
                guard let first = SettingsSearch.firstMatch(newValue) else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    @ViewBuilder
    private func settingRow(_ setting: AppearanceSetting) -> some View {
        VStack(alignment: .leading, spacing: tokens.cellPadding) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(setting.title)
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                valueLabel(setting)
            }
            control(setting)
            Text(setting.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(tokens.cellPadding + 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: tokens.innerRadius))
        .id(setting.id)
    }

    @ViewBuilder
    private func valueLabel(_ setting: AppearanceSetting) -> some View {
        switch setting {
        case .spacing, .cornerRadius, .selectionOpacity, .backgroundStyle, .colorScheme:
            Text(currentValueText(setting))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case .preview, .reset:
            EmptyView()
        }
    }

    private func currentValueText(_ setting: AppearanceSetting) -> String {
        switch setting {
        case .spacing: return "\(Int(tokens.spacing.rounded())) pt"
        case .cornerRadius: return "\(Int(tokens.cornerRadius.rounded())) pt"
        case .selectionOpacity: return "\(Int((tokens.selectionOpacity * 100).rounded())) %"
        case .backgroundStyle: return tokens.backgroundStyle.title
        case .colorScheme: return tokens.colorScheme.title
        case .preview, .reset: return ""
        }
    }

    @ViewBuilder
    private func control(_ setting: AppearanceSetting) -> some View {
        switch setting {
        case .spacing:
            Slider(value: spacingBinding, in: AppearanceTokens.spacingRange, step: 1)
                .accessibilityLabel("Grid spacing")
        case .cornerRadius:
            Slider(value: cornerRadiusBinding, in: AppearanceTokens.cornerRadiusRange, step: 1)
                .accessibilityLabel("Corner radius")
        case .selectionOpacity:
            Slider(value: selectionOpacityBinding, in: AppearanceTokens.selectionOpacityRange, step: 0.02)
                .accessibilityLabel("Selection highlight opacity")
        case .backgroundStyle:
            Picker("Content background", selection: backgroundStyleBinding) {
                ForEach(AppearanceBackgroundStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        case .colorScheme:
            Picker("Color scheme", selection: colorSchemeBinding) {
                ForEach(AppearanceColorScheme.allCases) { scheme in
                    Text(scheme.title).tag(scheme)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        case .preview:
            AppearancePreviewStrip(tokens: tokens)
        case .reset:
            HStack(spacing: 8) {
                Button("Reset to defaults") { store.reset() }
                Spacer()
                Text(defaultsSummary)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var noResults: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No settings match “\(query)”")
                .font(.callout.weight(.medium))
            Text("Try spacing, radius, background, dark or reset.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Applied live and remembered — no restart.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(liveSummary)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, tokens.contentPadding)
        .padding(.vertical, tokens.cellPadding + 2)
    }

    /// The resolved values, so the current state is readable at a glance.
    private var liveSummary: String {
        "\(Int(tokens.spacing.rounded())) / \(Int(tokens.cornerRadius.rounded())) / "
            + "\(tokens.backgroundStyle.title) / \(tokens.colorScheme.title)"
    }

    private var defaultsSummary: String {
        "defaults \(Int(AppearanceTokens.defaultSpacing)) / \(Int(AppearanceTokens.defaultCornerRadius))"
    }

    // MARK: - Bindings (clamped in the token `didSet`)

    private var spacingBinding: Binding<Double> {
        Binding(get: { store.tokens.spacing }, set: { store.tokens.spacing = $0 })
    }

    private var cornerRadiusBinding: Binding<Double> {
        Binding(get: { store.tokens.cornerRadius }, set: { store.tokens.cornerRadius = $0 })
    }

    private var selectionOpacityBinding: Binding<Double> {
        Binding(get: { store.tokens.selectionOpacity }, set: { store.tokens.selectionOpacity = $0 })
    }

    private var backgroundStyleBinding: Binding<AppearanceBackgroundStyle> {
        Binding(get: { store.tokens.backgroundStyle }, set: { store.tokens.backgroundStyle = $0 })
    }

    private var colorSchemeBinding: Binding<AppearanceColorScheme> {
        Binding(get: { store.tokens.colorScheme }, set: { store.tokens.colorScheme = $0 })
    }
}

// MARK: - Preview strip

/// A miniature of the real chrome that uses the live tokens: tile radius + spacing, the
/// selection wash, and a sidebar row. Extracted so it can be rendered offscreen in tests.
struct AppearancePreviewStrip: View {
    let tokens: AppearanceTokens

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.cellPadding) {
            HStack(spacing: tokens.spacing) {
                ForEach(0..<3, id: \.self) { index in
                    tile(isSelected: index == 1)
                }
            }
            HStack(spacing: tokens.spacing) {
                row(isSelected: true, width: 104)
                row(isSelected: false, width: 72)
            }
        }
        .padding(tokens.contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.backgroundFill ?? Color.primary.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: tokens.largeRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.largeRadius, style: .continuous)
                .strokeBorder(.quaternary)
        )
    }

    private func tile(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: tokens.cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.07))
            .frame(width: 46, height: 34)
            .overlay(
                RoundedRectangle(cornerRadius: tokens.cornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .quaternaryLabelColor), lineWidth: isSelected ? 2 : 1)
            )
            .background(
                RoundedRectangle(cornerRadius: tokens.cornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(isSelected ? tokens.selectionOpacity : 0))
            )
    }

    private func row(isSelected: Bool, width: Double) -> some View {
        RoundedRectangle(cornerRadius: tokens.innerRadius, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(tokens.selectionOpacity) : Color.primary.opacity(0.06))
            .frame(width: width, height: 18)
    }
}
