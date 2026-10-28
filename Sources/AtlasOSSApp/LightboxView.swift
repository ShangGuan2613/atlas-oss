import AtlasCore
import SwiftUI

/// Full-window quick look overlay for one item.
///
/// Decodes at a much larger size than the grid (`LightboxView.decodePixelSize`) and
/// keeps the grid mounted behind it, so closing returns to the same scroll position.
struct LightboxView: View {
    static let decodePixelSize = 1600

    // Qualified: SwiftUI's DeveloperToolsSupport also exports a `LibraryItem`.
    let item: AtlasCore.LibraryItem
    let url: URL?
    let index: Int
    let total: Int
    let onClose: () -> Void
    let onStep: (Int) -> Void

    @State private var image: NSImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.95)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(.horizontal, 64)
                    .padding(.vertical, 72)
                    .allowsHitTesting(false)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
            } else if didFail {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark").font(.system(size: 34))
                    Text("Preview unavailable").font(.callout)
                    Text(item.location).font(.caption).foregroundStyle(.secondary)
                }
                .foregroundStyle(.white.opacity(0.8))
            } else {
                ProgressView().controlSize(.large)
            }

            chrome
        }
        .transition(.opacity)
        .task(id: item.id) {
            image = nil
            didFail = false
            guard let url else {
                didFail = true
                return
            }
            let decoded = await ThumbnailLoader.thumbnail(for: url, maxPixelSize: Self.decodePixelSize)
            image = decoded
            didFail = decoded == nil
        }
    }

    private var chrome: some View {
        VStack {
            HStack(spacing: 12) {
                Text(item.fileName).font(.headline).lineLimit(1).truncationMode(.middle)
                Text("\(index + 1) / \(total)").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.45))

            Spacer()

            HStack(spacing: 16) {
                Text(item.dimensionsDescription)
                Text("←/→ navigate · Esc or Space closes")
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.65))
            .padding(.bottom, 14)
        }
        .overlay(alignment: .leading) { chevron(-1, systemImage: "chevron.left") }
        .overlay(alignment: .trailing) { chevron(1, systemImage: "chevron.right") }
    }

    @ViewBuilder
    private func chevron(_ step: Int, systemImage: String) -> some View {
        let enabled = step < 0 ? index > 0 : index < total - 1
        Button {
            onStep(step)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 64)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(enabled ? 0.85 : 0.2))
        .disabled(!enabled)
        .padding(.horizontal, 12)
    }
}
