import SwiftUI
import Photos

struct ReviewView: View {
    let title: String
    @State private var assets: [PHAsset]

    init(title: String, assets: [PHAsset]) {
        self.title = title
        _assets = State(initialValue: assets)
    }

    @Environment(PhotoLibrary.self) private var library
    @Environment(ReviewStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var index = 0
    @State private var didSetStart = false
    @State private var drag: CGSize = .zero
    @State private var isAnimatingOut = false
    @State private var history: [HistoryEntry] = []
    @State private var memberships: Set<String> = []
    @State private var favoriteOverrides: [String: Bool] = [:]
    @State private var showTrash = false
    @State private var showNewAlbum = false
    @State private var newAlbumName = ""
    @State private var errorMessage: String?
    @State private var trashTrigger = 0
    @State private var keepTrigger = 0
    @State private var zoomTarget: ZoomTarget?
    @State private var pendingZoomAction: (() -> Void)?

    private struct ZoomTarget: Identifiable {
        let asset: PHAsset
        var id: String { asset.localIdentifier }
    }

    private struct HistoryEntry {
        let id: String
        let index: Int
        let wasReviewed: Bool
        let wasTrashed: Bool
    }

    private var current: PHAsset? { assets.indices.contains(index) ? assets[index] : nil }

    var body: some View {
        VStack(spacing: 12) {
            if let current {
                header(current)
                cardStack(current)
                albumBar(current)
                controls(current)
            } else {
                doneView
            }
        }
        .padding(.bottom, 8)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { undo() } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .disabled(history.isEmpty)
                .accessibilityLabel("Undo")

                Button { showTrash = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: store.trash.isEmpty ? "trash" : "trash.fill")
                        if !store.trash.isEmpty {
                            Text("\(store.trash.count)")
                                .font(.subheadline.bold())
                                .monospacedDigit()
                        }
                    }
                    .foregroundStyle(store.trash.isEmpty ? Color.primary : Color.red)
                }
                .accessibilityLabel("Trash")
            }
        }
        .sheet(isPresented: $showTrash) {
            NavigationStack { TrashView(showsDoneButton: true) }
        }
        .fullScreenCover(item: $zoomTarget, onDismiss: runPendingZoomAction) { target in
            PhotoZoomView(assets: [target.asset]) { asset, dismissZoom in
                ZoomActionButton(icon: "trash.fill", color: .red) {
                    pendingZoomAction = { trashCurrent() }
                    dismissZoom()
                }
                .accessibilityLabel("Move to Trash")
                ZoomActionButton(icon: isFavorite(asset) ? "heart.fill" : "heart", color: .pink) {
                    toggleFavorite(asset)
                }
                .accessibilityLabel("Favorite")
                .accessibilityAddTraits(isFavorite(asset) ? .isSelected : [])
                ZoomActionButton(icon: "checkmark", color: .green) {
                    pendingZoomAction = { keepCurrent() }
                    dismissZoom()
                }
                .accessibilityLabel("Keep")
            }
            .presentationBackground(.clear)
        }
        .alert("New Album", isPresented: $showNewAlbum) {
            TextField("Name", text: $newAlbumName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createAlbum() }
        } message: {
            Text("The current photo will be added right away.")
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: trashTrigger)
        .sensoryFeedback(.selection, trigger: keepTrigger)
        .onAppear {
            guard !didSetStart else { return }
            didSetStart = true
            dropRemovedAssets()
            index = assets.firstIndex { !store.isReviewed($0.localIdentifier) } ?? assets.count
        }
        .onChange(of: library.removedIDs) { dropRemovedAssets() }
        .task(id: current?.localIdentifier) {
            if let current { memberships = library.albumIDs(containing: current) }
        }
    }


    @ViewBuilder
    private func header(_ asset: PHAsset) -> some View {
        VStack(spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.creationDate?.formatted(date: .long, time: .shortened) ?? String(localized: "No Date"))
                        .font(.subheadline.weight(.semibold))
                    Text("\(index + 1) of \(assets.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                if store.isTrashed(asset.localIdentifier) {
                    Button {
                        store.restore(asset.localIdentifier)
                    } label: {
                        Label("In Trash – Keep", systemImage: "arrow.uturn.backward")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
            ProgressView(value: Double(index), total: Double(max(assets.count, 1)))
        }
        .padding(.horizontal)
    }

    private func cardStack(_ top: PHAsset) -> some View {
        let visible = Array(assets[index..<min(index + 2, assets.count)])
        let progress = min(1, hypot(drag.width, drag.height) / 160)
        return ZStack {
            ForEach(visible.reversed(), id: \.localIdentifier) { asset in
                let isTop = asset.localIdentifier == top.localIdentifier
                let canZoom = isTop && asset.mediaType == .image
                MediaCard(asset: asset, isActive: isTop)
                    .overlay(alignment: .topTrailing) {
                        if canZoom { zoomButton(asset) }
                    }
                    .overlay { if isTop { dragHint } }
                    .gesture(TapGesture(count: 2).onEnded { openZoom(asset) },
                             including: canZoom ? .all : .subviews)
                    .simultaneousGesture(MagnifyGesture().onChanged { value in
                        if value.magnification > 1.15 { openZoom(asset) }
                    }, including: canZoom ? .all : .subviews)
                    .accessibilityAction(named: Text("Zoom")) {
                        if canZoom { openZoom(asset) }
                    }
                    .scaleEffect(isTop ? 1 : 0.92 + 0.08 * progress)
                    .opacity(isTop ? 1 : 0.4 + 0.6 * progress)
                    .offset(isTop ? drag : .zero)
                    .rotationEffect(.degrees(isTop ? Double(drag.width / 25) : 0))
                    .allowsHitTesting(isTop)
                    .zIndex(isTop ? 1 : 0)
            }
        }
        .padding(.horizontal)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(swipeGesture)
    }

    private func zoomButton(_ asset: PHAsset) -> some View {
        Button { openZoom(asset) } label: {
            Image(systemName: "plus.magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(12)
        .opacity(drag == .zero ? 1 : 0)
        .accessibilityLabel("Zoom")
    }

    @ViewBuilder
    private var dragHint: some View {
        let vertical = abs(drag.height) > abs(drag.width)
        if vertical && drag.height < -30 {
            hint("DELETE", icon: "trash.fill", color: .red, strength: (-drag.height - 30) / 90)
        } else if !vertical && drag.width < -30 {
            hint("KEEP", icon: "checkmark", color: .green, strength: (-drag.width - 30) / 90)
        } else if !vertical && drag.width > 30 && index > 0 {
            hint("BACK", icon: "arrow.uturn.backward", color: .blue, strength: (drag.width - 30) / 90)
        }
    }

    private func hint(_ text: LocalizedStringKey, icon: String, color: Color, strength: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(color.opacity(0.25))
            Label(text, systemImage: icon)
                .font(.title.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(color, in: Capsule())
        }
        .opacity(Double(min(1, max(0, strength))))
        .allowsHitTesting(false)
    }

    private func albumBar(_ asset: PHAsset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Album")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal)
            albumChips(asset)
        }
    }

    private func albumChips(_ asset: PHAsset) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    newAlbumName = ""
                    showNewAlbum = true
                } label: {
                    Label("New", systemImage: "plus")
                        .chip(selected: false)
                }
                ForEach(library.albums, id: \.localIdentifier) { album in
                    let isMember = memberships.contains(album.localIdentifier)
                    Button {
                        toggle(album, for: asset, isMember: isMember)
                    } label: {
                        HStack(spacing: 4) {
                            if isMember { Image(systemName: "checkmark") }
                            Text(album.localizedTitle ?? String(localized: "Album"))
                        }
                        .chip(selected: isMember)
                    }
                }
            }
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
    }

    private func controls(_ asset: PHAsset) -> some View {
        HStack(spacing: 22) {
            RoundButton(icon: "chevron.left", color: .blue, size: 60) { goBack() }
                .disabled(index == 0)
                .accessibilityLabel("Back")
            RoundButton(icon: "trash.fill", color: .red, size: 60) { trashCurrent() }
                .accessibilityLabel("Move to Trash")
            RoundButton(icon: isFavorite(asset) ? "heart.fill" : "heart", color: .pink, size: 60) {
                toggleFavorite(asset)
            }
            .accessibilityLabel("Favorite")
            RoundButton(icon: "checkmark", color: .green, size: 60) { keepCurrent() }
                .accessibilityLabel("Keep")
        }
        .disabled(isAnimatingOut)
    }

    private var doneView: some View {
        ContentUnavailableView {
            Label("All Done!", systemImage: "checkmark.seal.fill")
        } description: {
            if assets.isEmpty {
                Text("Nothing to sort here.")
            } else {
                Text("You've reviewed everything in “\(title)”.")
            }
        } actions: {
            if !store.trash.isEmpty {
                Button("Empty Trash (\(store.trash.count))") { showTrash = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            if !assets.isEmpty {
                Button("Start Over") {
                    index = 0
                    history = []
                }
            }
            Button("Back to Overview") { dismiss() }
        }
    }


    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isAnimatingOut, zoomTarget == nil else { return }
                drag = value.translation
            }
            .onEnded { value in
                guard !isAnimatingOut else { return }
                guard zoomTarget == nil else { drag = .zero; return }
                let t = value.translation
                let p = value.predictedEndTranslation
                let vertical = abs(t.height) > abs(t.width)
                if vertical && (t.height < -120 || p.height < -450) {
                    trashCurrent()
                } else if !vertical && (t.width < -100 || p.width < -450) {
                    keepCurrent()
                } else if !vertical && index > 0 && (t.width > 100 || p.width > 450) {
                    goBack()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { drag = .zero }
                }
            }
    }

    private func openZoom(_ asset: PHAsset) {
        guard !isAnimatingOut, zoomTarget == nil, asset.mediaType == .image,
              asset.localIdentifier == current?.localIdentifier else { return }
        drag = .zero
        zoomTarget = ZoomTarget(asset: asset)
    }

    /// Decisions made in the zoom view run after it is dismissed, so the card visibly flies out.
    private func runPendingZoomAction() {
        let action = pendingZoomAction
        pendingZoomAction = nil
        action?()
    }

    private func flyOut(to offset: CGSize, then action: @escaping () -> Void) {
        isAnimatingOut = true
        withAnimation(.easeIn(duration: 0.18)) {
            drag = offset
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                action()
                drag = .zero
            }
            isAnimatingOut = false
        }
    }

    private func keepCurrent() {
        guard let asset = current, !isAnimatingOut else { return }
        let id = asset.localIdentifier
        let i = index
        keepTrigger += 1
        let entry = HistoryEntry(id: id, index: i, wasReviewed: store.isReviewed(id), wasTrashed: store.isTrashed(id))
        flyOut(to: CGSize(width: -700, height: drag.height)) {
            // Behalten holt ein Foto auch wieder aus dem Papierkorb (z. B. nach Löschen → Zurück).
            if entry.wasTrashed { store.restore(id) }
            store.markReviewed(id)
            history.append(entry)
            index = i + 1
        }
    }

    private func trashCurrent() {
        guard let asset = current, !isAnimatingOut else { return }
        let id = asset.localIdentifier
        let i = index
        let wasTrashed = store.isTrashed(id)
        let wasReviewed = store.isReviewed(id)
        trashTrigger += 1
        flyOut(to: CGSize(width: drag.width, height: -1000)) {
            store.moveToTrash(id)
            history.append(HistoryEntry(id: id, index: i, wasReviewed: wasReviewed, wasTrashed: wasTrashed))
            index = i + 1
        }
    }

    private func goBack() {
        guard index > 0 else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            drag = .zero
            index -= 1
        }
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        if last.wasTrashed { store.moveToTrash(last.id) } else { store.restore(last.id) }
        if last.wasReviewed { store.markReviewed(last.id) } else { store.unmarkReviewed(last.id) }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            index = assets.firstIndex { $0.localIdentifier == last.id } ?? min(last.index, assets.count)
        }
    }

    /// Entfernt Medien, die inzwischen gelöscht wurden, und bleibt dabei beim aktuellen Foto.
    private func dropRemovedAssets() {
        let removed = library.removedIDs
        guard assets.contains(where: { removed.contains($0.localIdentifier) }) else { return }
        let currentID = current?.localIdentifier
        let removedBefore = assets.prefix(index).filter { removed.contains($0.localIdentifier) }.count
        assets.removeAll { removed.contains($0.localIdentifier) }
        history.removeAll { removed.contains($0.id) }
        if let currentID, let i = assets.firstIndex(where: { $0.localIdentifier == currentID }) {
            index = i
        } else {
            index = min(max(0, index - removedBefore), assets.count)
        }
    }

    private func toggle(_ album: PHAssetCollection, for asset: PHAsset, isMember: Bool) {
        let albumID = album.localIdentifier
        if isMember { memberships.remove(albumID) } else { memberships.insert(albumID) }
        Task {
            do {
                if isMember {
                    try await library.remove(asset, from: album)
                } else {
                    try await library.add(asset, to: album)
                }
            } catch {
                if isMember { memberships.insert(albumID) } else { memberships.remove(albumID) }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func createAlbum() {
        let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let asset = current else { return }
        Task {
            do {
                if let album = try await library.createAlbum(named: name) {
                    try await library.add(asset, to: album)
                    memberships.insert(album.localIdentifier)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func isFavorite(_ asset: PHAsset) -> Bool {
        favoriteOverrides[asset.localIdentifier] ?? asset.isFavorite
    }

    private func toggleFavorite(_ asset: PHAsset) {
        let id = asset.localIdentifier
        let newValue = !isFavorite(asset)
        favoriteOverrides[id] = newValue
        Task {
            do {
                try await library.setFavorite(asset, newValue)
            } catch {
                favoriteOverrides[id] = !newValue
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Hilfsviews

private struct RoundButton: View {
    let icon: String
    let color: Color
    let size: CGFloat
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .background(color.opacity(0.14), in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
    }
}

private extension View {
    func chip(selected: Bool) -> some View {
        self
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
            .contentShape(Capsule())
    }
}
