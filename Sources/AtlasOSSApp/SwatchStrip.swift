import AtlasCore
import SwiftUI

// MARK: - Hex → Color

extension Color {
    /// sRGB colour from `#RRGGBB` (also accepts `RRGGBB` and `#RGB`).
    ///
    /// Parsing lives in `ColorProbe` so the App layer and the Core layer can never disagree
    /// about what a hex string means.
    init?(hex: String) {
        guard let rgb = ColorProbe.rgbComponents(fromHex: hex) else { return nil }
        self.init(
            .sRGB,
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255,
            opacity: 1
        )
    }
}

// MARK: - Chip flow

/// Wrapping row layout for chips: macOS 14's SwiftUI has no flow layout, and a fixed
/// `LazyVGrid` would either clip long tag names or leave ragged gaps.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Swatches

/// The dominant-colour row. Every swatch is a button that filters the grid by that colour.
struct SwatchStrip: View {
    let swatches: [Swatch]
    let onSelect: (String) -> Void

    var body: some View {
        ChipFlow(spacing: 6, lineSpacing: 6) {
            ForEach(swatches, id: \.hex) { swatch in
                Button {
                    onSelect(swatch.hex)
                } label: {
                    SwatchChip(swatch: swatch)
                }
                .buttonStyle(.plain)
                .help(help(for: swatch))
            }
        }
    }

    private func help(for swatch: Swatch) -> String {
        let share = Int((swatch.weight * 100).rounded())
        return "Filter the grid by \(swatch.hex) — \(share)% of sampled pixels"
    }
}

/// One swatch: the colour itself plus its canonical hex, so the chip is readable without
/// relying on colour perception alone.
struct SwatchChip: View {
    let swatch: Swatch

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(hex: swatch.hex) ?? Color.gray)
                .frame(width: 16, height: 16)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18))
                )
            Text(swatch.hex)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .contentShape(Capsule())
    }
}

/// Header chip for an active colour filter: `Color #AABBCC  12  ✕`.
struct ColorFilterChip: View {
    let hex: String
    let count: Int
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(hex: hex) ?? Color.gray)
                .frame(width: 12, height: 12)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18))
                )
            Text("Color \(hex)")
                .font(.callout.weight(.medium))
                .monospacedDigit()
            Text("\(count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear the color filter")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary))
    }
}
