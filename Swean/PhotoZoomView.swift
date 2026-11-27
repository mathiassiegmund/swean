import SwiftUI
import Photos

/// Full-screen view for zooming into a photo, offering the same decisions as the review screen.
struct PhotoZoomView: View {
    let asset: PHAsset
    let isFavorite: Bool
    let onTrash: () -> Void
    let onToggleFavorite: () -> Void
    let onKeep: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var isLoadingFullResolution = true
    @State private var failed = false
    @State private var attempt = 0
    @State private var dismissOffset: CGFloat = 0
    @State private var showsChrome = true

    private var dragProgress: Double { min(1, abs(dismissOffset) / 300) }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - dragProgress)
                .ignoresSafeArea()

            content

            if showsChrome {
                chrome
                    .opacity(1 - min(1, dragProgress * 3))
                    .transition(.opacity)
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(!showsChrome)
        .persistentSystemOverlays(showsChrome ? .automatic : .hidden)
        .task(id: attempt) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            ZoomableImageView(
                image: image,
                pixelSize: CGSize(width: asset.pixelWidth, height: asset.pixelHeight),
                onSingleTap: {
                    withAnimation(.easeInOut(duration: 0.2)) { showsChrome.toggle() }
                },
                onDismissDrag: { dismissOffset = $0 },
                onDismissEnd: { translation, velocity in
                    if abs(translation) > 120 || abs(velocity) > 900 {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dismissOffset = 0 }
                    }
                }
            )
            .offset(y: dismissOffset)
            .ignoresSafeArea()
        } else if failed {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.icloud")
                    .font(.largeTitle)
                Text("Couldn't load photo")
                    .font(.subheadline)
                Button("Try Again") { attempt += 1 }
                    .buttonStyle(.bordered)
            }
            .foregroundStyle(.secondary)
        } else {
            ProgressView()
                .controlSize(.large)
        }
    }

    private var chrome: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.bold))
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")

                Spacer()

                if isLoadingFullResolution && image != nil {
                    ProgressView()
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                        .accessibilityLabel("Loading full resolution")
                }
            }

            Spacer()

            HStack(spacing: 28) {
                ZoomActionButton(icon: "trash.fill", color: .red) { decide(onTrash) }
                    .accessibilityLabel("Move to Trash")
                ZoomActionButton(icon: isFavorite ? "heart.fill" : "heart", color: .pink) { onToggleFavorite() }
                    .accessibilityLabel("Favorite")
                    .accessibilityAddTraits(isFavorite ? .isSelected : [])
                ZoomActionButton(icon: "checkmark", color: .green) { decide(onKeep) }
                    .accessibilityLabel("Keep")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
    }

    private func decide(_ action: () -> Void) {
        action()
        dismiss()
    }

    private func load() async {
        failed = false
        isLoadingFullResolution = true
        let size = ImageLoader.zoomTargetSize(pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight)
        // Delivers a quick low-resolution image first, then the sharp one (downloaded from iCloud if needed).
        for await event in ImageLoader.shared.images(for: asset, targetSize: size, contentMode: .aspectFit, exactSize: true) {
            switch event {
            case .image(let img): image = img
            case .failed: if image == nil { failed = true }
            }
        }
        isLoadingFullResolution = false
    }
}

private struct ZoomActionButton: View {
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 58, height: 58)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }
}
