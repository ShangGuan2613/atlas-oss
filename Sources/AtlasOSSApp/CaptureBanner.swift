import AppKit
import SwiftUI

/// One transient line of feedback about a capture batch.
///
/// Deliberately *not* an alert: a drop should never steal focus or block the next drop.
/// One banner per batch (see `CaptureCenter.present`), auto-dismissed, manually dismissable.
struct CaptureBanner: Identifiable, Equatable {
    enum Style: Equatable {
        /// Everything was new.
        case success
        /// Something was already in the library — the duplicate message.
        case notice
        /// The batch failed, wholly or partly.
        case failure
    }

    /// How long the banner stays up. Long enough to read a two-clause summary, short enough
    /// that a second drop replaces it rather than stacking.
    static let visibleSeconds: Double = 3.5

    let id = UUID()
    let text: String
    let style: Style
}

/// The banner chrome: a small material capsule pinned to the top of the grid.
struct CaptureBannerView: View {
    @Environment(\.appearance) private var tokens

    let banner: CaptureBanner
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)

            Text(banner.text)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: tokens.largeRadius))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.largeRadius)
                .strokeBorder(.quaternary)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(banner.text)
    }

    private var symbol: String {
        switch banner.style {
        case .success: return "checkmark.circle.fill"
        case .notice: return "arrow.triangle.2.circlepath"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch banner.style {
        case .success: return .accentColor
        case .notice: return .secondary
        case .failure: return .orange
        }
    }
}
