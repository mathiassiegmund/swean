import SwiftUI
import Photos

/// Full-screen view for zooming into one photo, or into several photos that can be switched
/// between at the same zoom position (e.g. to compare sharpness in a series duel).
struct PhotoZoomView<Actions: View>: View {
    let assets: [PHAsset]
    /// Labels for the photo switcher; only shown when there is more than one photo.
    let titles: [Text]
    /// Decision buttons for the photo currently shown. The closure's second argument dismisses the view.
    private let actions: (PHAsset, @escaping () -> Void) -> Actions

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int
    @State private var images: [String: UIImage] = [:]
    @State private var loading: Set<String> = []
    @State private var failed: Set<String> = []
    @State private var attempt = 0
    @State private var dismissOffset: CGFloat = 0
    @State private var showsChrome = true

    init(assets: [PHAsset], titles: [Text] = [], initialIndex: Int = 0,
         @ViewBuilder actions: @escaping (PHAsset, @escaping () -> Void) -> Actions) {
        self.assets = assets
        self.titles = titles
        self.actions = actions
        _selection = State(initialValue: assets.indices.contains(initialIndex) ? initialIndex : 0)
    }

    private var current: PHAsset? { assets.indices.contains(selection) ? assets[selection] : nil }
    private var dragProgress: Double { min(1, abs(dismissOffset) / 300) }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - dragProgress)
                .ignoresSafeArea()

            if let current { content(for: current) }

            if showsChrome {
                chrome
                    .opacity(1 - min(1, dragProgress * 3))
                    .transition(.opacity)
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(!showsChrome)
        .persistentSystemOverlays(showsChrome ? .automatic : .hidden)
        .task(id: attempt) { await loadAll() }
    }

    @ViewBuilder
    private func content(for asset: PHAsset) -> some View {
        let id = asset.localIdentifier
        if let image = images[id] {
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
        } else if failed.contains(id) {
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
        VStack(spacing: 12) {
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

                if let current, loading.contains(current.localIdentifier), images[current.localIdentifier] != nil {
                    ProgressView()
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                        .accessibilityLabel("Loading full resolution")
                }
            }

            if assets.count > 1 {
                Picker("Photo", selection: $selection) {
                    ForEach(assets.indices, id: \.self) { index in
                        (titles.indices.contains(index) ? titles[index] : Text(verbatim: "\(index + 1)"))
                            .tag(index)
                    }
                }
                .pickerStyle(.segmented)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            Spacer()

            if let current {
                HStack(spacing: 28) {
                    actions(current) { dismiss() }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
    }

    /// Loads the photo shown first, then the others, so switching between them is instant.
    private func loadAll() async {
        failed = []
        let ordered = assets.enumerated().filter { $0.offset == selection } + assets.enumerated().filter { $0.offset != selection }
        for (_, asset) in ordered {
            guard !Task.isCancelled else { return }
            await load(asset)
        }
    }

    private func load(_ asset: PHAsset) async {
        let id = asset.localIdentifier
        loading.insert(id)
        defer { loading.remove(id) }
        let size = ImageLoader.zoomTargetSize(pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight)
        // Delivers a quick low-resolution image first, then the sharp one (downloaded from iCloud if needed).
        for await event in ImageLoader.shared.images(for: asset, targetSize: size, contentMode: .aspectFit, exactSize: true) {
            switch event {
            case .image(let img): images[id] = img
            case .failed: if images[id] == nil { failed.insert(id) }
            }
        }
    }
}

/// Round decision button used in the zoom view.
struct ZoomActionButton: View {
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
