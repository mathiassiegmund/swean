import SwiftUI
import Photos
import AVFoundation

/// Zeigt ein Vorschaubild eines Mediums in der Größe des verfügbaren Platzes.
struct AssetImage: View {
    let asset: PHAsset
    var contentMode: ContentMode = .fill

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    Rectangle().fill(Color(.tertiarySystemFill))
                    if contentMode == .fit { ProgressView() }
                }
            }
            .task(id: "\(asset.localIdentifier)-\(Int(geo.size.width))x\(Int(geo.size.height))") {
                guard geo.size.width > 0, geo.size.height > 0 else { return }
                let size = CGSize(width: geo.size.width * displayScale, height: geo.size.height * displayScale)
                let mode: PHImageContentMode = contentMode == .fill ? .aspectFill : .aspectFit
                for await img in ImageLoader.shared.images(for: asset, targetSize: size, contentMode: mode) {
                    image = img
                }
            }
        }
        .clipped()
    }
}

/// Große Karte in der Swipe-Ansicht, inkl. Videowiedergabe.
struct MediaCard: View {
    let asset: PHAsset
    let isActive: Bool

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var isLoadingVideo = false

    private var isVideo: Bool { asset.mediaType == .video }

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            AssetImage(asset: asset, contentMode: .fit)

            if let player {
                PlayerView(player: player)
                    .onTapGesture { togglePlayback() }
            }

            if isVideo && !isPlaying {
                Button { togglePlayback() } label: {
                    if isLoadingVideo {
                        ProgressView().controlSize(.large).tint(.white)
                    } else {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 68))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.35))
                    }
                }
                .disabled(!isActive)
            }

            VStack {
                Spacer()
                HStack(spacing: 6) {
                    if isVideo { Badge(text: Text(verbatim: durationText), icon: "video.fill") }
                    if asset.mediaSubtypes.contains(.photoLive) { Badge(text: Text("LIVE"), icon: "livephoto") }
                    if asset.mediaSubtypes.contains(.photoScreenshot) { Badge(text: Text("Screenshot"), icon: "camera.viewfinder") }
                    Spacer()
                }
            }
            .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
        .onChange(of: isActive) { _, active in
            if !active { player?.pause(); isPlaying = false }
        }
        .onDisappear { player?.pause() }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard let item = note.object as? AVPlayerItem, item == player?.currentItem else { return }
            isPlaying = false
            player?.seek(to: .zero)
        }
    }

    private var durationText: String {
        let total = Int(asset.duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func togglePlayback() {
        if let player {
            if isPlaying { player.pause() } else { player.play() }
            isPlaying.toggle()
            return
        }
        guard !isLoadingVideo else { return }
        isLoadingVideo = true
        Task {
            defer { isLoadingVideo = false }
            guard let item = await ImageLoader.shared.playerItem(for: asset) else { return }
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            let newPlayer = AVPlayer(playerItem: item)
            player = newPlayer
            newPlayer.play()
            isPlaying = true
        }
    }
}

private struct Badge: View {
    let text: Text
    let icon: String

    var body: some View {
        Label { text } icon: { Image(systemName: icon) }
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

struct PlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        view.playerLayer.player = player
    }

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
