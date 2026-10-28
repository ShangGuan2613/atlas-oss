import AppKit
import AtlasCore
import SwiftUI

/// Right-hand inspector (P1 plan dimension E).
///
/// Single selection: preview, big-type dimensions/size/kind, path, dates, collection and
/// tag chips, dominant-colour swatches. Multi selection: counts, "Multiple" dimensions
/// when they differ, per-item tag/collection counts (shared first) and the top colours
/// across the selection. Nothing here writes to the library — every mutation is a closure
/// the model owns, which keeps this view testable and dumb.
struct InfoPanelView: View {
    /// Section rhythm and padding are design tokens (P1-D); defaults match P1-C exactly.
    @Environment(\.appearance) private var tokens

    let summary: InfoSummary
    let swatches: [Swatch]
    let tagBadges: [TagBadge]
    let collectionChips: [CollectionChip]
    let previewURL: URL?
    let addableTags: [LibraryTag]
    let isLoadingSwatches: Bool

    var onSelectTag: (UUID) -> Void = { _ in }
    var onAddTag: (UUID) -> Void = { _ in }
    var onRemoveTag: (UUID) -> Void = { _ in }
    var onSelectCollection: (UUID) -> Void = { _ in }
    var onSelectColor: (String) -> Void = { _ in }
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: tokens.spacing) {
                    if summary.isEmpty {
                        placeholder
                    } else {
                        if summary.isSingle, let previewURL {
                            InfoPreview(url: previewURL)
                        }
                        bigType
                        Divider()
                        details
                        if !collectionChips.isEmpty {
                            collectionSection
                        }
                        tagSection
                        swatchSection
                    }
                }
                .padding(tokens.contentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 260)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Info")
                .font(.headline)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide info (I)")
        }
        .padding(.horizontal, tokens.contentPadding)
        .padding(.vertical, 9)
    }

    // MARK: - Single / multi summary

    private var bigType: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary.headline)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
                .truncationMode(.middle)
            Text(summary.dimensions)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("\(summary.byteSize) · \(summary.kindLabel)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let location = summary.location {
                detailRow("Location") {
                    Text(location)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            if let imported = summary.importedAt {
                detailRow("Imported") {
                    Text(InfoFormat.date(imported))
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
            if let modified = summary.fileModifiedAt {
                detailRow("Modified") {
                    Text(InfoFormat.date(modified))
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
            if let mode = summary.importModeLabel {
                detailRow("Storage") {
                    Text(mode)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func detailRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    // MARK: - Chips

    private var collectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Collections")
            ChipFlow(spacing: 6, lineSpacing: 6) {
                ForEach(collectionChips) { chip in
                    InfoChip(
                        title: chip.collection.name,
                        systemImage: chip.collection.isInbox ? "tray" : "folder",
                        detail: chip.detail,
                        onTap: { onSelectCollection(chip.collection.id) }
                    )
                }
            }
        }
    }

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                sectionTitle(summary.isSingle ? "Tags" : "Tags · shared first")
                Spacer()
                if !addableTags.isEmpty {
                    Menu {
                        ForEach(addableTags) { tag in
                            Button(tag.name) { onAddTag(tag.id) }
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(summary.isSingle ? "Add a tag" : "Add this tag to every selected item")
                }
            }

            if tagBadges.isEmpty {
                Text(summary.isSingle ? "No tags yet" : "No shared tags")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ChipFlow(spacing: 6, lineSpacing: 6) {
                    ForEach(tagBadges) { badge in
                        InfoChip(
                            title: badge.tag.name,
                            systemImage: "number",
                            tint: badge.tag.color.flatMap(Color.init(hex:)),
                            detail: badge.detail,
                            onTap: { onSelectTag(badge.tag.id) },
                            onRemove: summary.isSingle ? nil : { onRemoveTag(badge.tag.id) }
                        )
                    }
                }
            }
        }
    }

    private var swatchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(summary.swatchCaption)
            if swatches.isEmpty {
                HStack(spacing: 6) {
                    if isLoadingSwatches {
                        ProgressView().controlSize(.mini)
                    }
                    Text(isLoadingSwatches ? "Reading colors…" : "No colors")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                SwatchStrip(swatches: swatches, onSelect: onSelectColor)
                Text("Click a swatch to filter the grid (sRGB distance ≤ \(ColorProbe.defaultTolerance)).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    // MARK: - Empty

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("Select an item")
                .font(.headline)
            Text("Dimensions, size, tags, collections and dominant colors appear here. Press I to hide the panel.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Preview

/// Async downsampled preview. Reuses `ThumbnailLoader`, so opening the panel costs the same
/// decode the grid already paid for.
struct InfoPreview: View {
    @Environment(\.appearance) private var tokens

    let url: URL

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: tokens.largeRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(6)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: tokens.largeRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.largeRadius, style: .continuous)
                .strokeBorder(.quaternary)
        )
        .task(id: url.path) {
            image = await ThumbnailLoader.thumbnail(for: url, maxPixelSize: 640)
        }
    }
}

// MARK: - Chip

/// A capsule chip: collection membership or tag, with an optional per-item count and an
/// optional remove button (multi-select tag editing).
struct InfoChip: View {
    let title: String
    var systemImage: String?
    var tint: Color?
    var detail: String?
    var onTap: (() -> Void)?
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(tint ?? .secondary)
            }
            Text(title)
                .font(.caption)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from selection")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(tint?.opacity(0.4) ?? Color.clear))
        .contentShape(Capsule())
        .onTapGesture { onTap?() }
        .help(onTap == nil ? title : "Filter the sidebar by \(title)")
    }
}
