import SwiftUI
import Photos

/// Liste aller gefundenen Serien.
struct SeriesListView: View {
    @Environment(SeriesStore.self) private var seriesStore
    @Environment(ReviewStore.self) private var store
    @Environment(PhotoLibrary.self) private var library

    var body: some View {
        let open = seriesStore.open(store: store, removed: library.removedIDs)
        List {
            Section {
                Text("Swean found series of similar photos. Let them compete – the best one stays.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if seriesStore.isScanning {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Searching for series …")
                            .font(.subheadline)
                        ProgressView(value: seriesStore.progress)
                    }
                    .padding(.vertical, 4)
                }
            }
            if !open.isEmpty {
                Section {
                    ForEach(open) { series in
                        NavigationLink {
                            DuelView(series: series)
                        } label: {
                            SeriesRow(assets: seriesStore.available(in: series, store: store, removed: library.removedIDs))
                        }
                    }
                }
            }
        }
        .overlay {
            if open.isEmpty && !seriesStore.isScanning {
                ContentUnavailableView("No Series Found", systemImage: "trophy",
                                       description: Text("Swean looks for photos taken seconds apart that look almost the same."))
            }
        }
        .navigationTitle("Series Duel")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SeriesRow: View {
    let assets: [PHAsset]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(assets.prefix(5), id: \.localIdentifier) { asset in
                    AssetImage(asset: asset)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                if assets.count > 5 {
                    Text(verbatim: "+\(assets.count - 5)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 36)
                }
            }
            HStack {
                Text("\(assets.count) similar photos")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let date = assets.first?.creationDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct DuelView: View {
    @State private var series: PhotoSeries

    @Environment(SeriesStore.self) private var seriesStore
    @Environment(ReviewStore.self) private var store
    @Environment(PhotoLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var assets: [PHAsset] = []
    @State private var championIndex = 0
    @State private var challengerIndex = 1
    @State private var steps: [Step] = []
    @State private var loaded = false
    @State private var pickTrigger = 0
    @State private var zoomTarget: ZoomTarget?
    @State private var pendingZoomAction: (() -> Void)?
    @State private var zoomTrigger = 0
    @State private var press: Press?
    @State private var pressTask: Task<Void, Never>?

    /// A touch on a duel card: a short tap picks the photo, holding it opens the zoom view.
    private struct Press: Equatable {
        let id: String
        var isActive = true
        var openedZoom = false
    }

    /// The duel pair being compared in the zoom view; `startsWithChampion` picks the photo shown first.
    private struct ZoomTarget: Identifiable {
        let champion: PHAsset
        let challenger: PHAsset
        let startsWithChampion: Bool
        var id: String { champion.localIdentifier + "|" + challenger.localIdentifier }
    }

    private struct Step {
        let loser: String?
        let kept: String?
        let champion: Int
        let challenger: Int
    }

    init(series: PhotoSeries) {
        _series = State(initialValue: series)
    }

    private var isDone: Bool { loaded && challengerIndex >= assets.count }
    private var duelCount: Int { max(assets.count - 1, 1) }
    private var trashedCount: Int { steps.filter { $0.loser != nil }.count }

    var body: some View {
        VStack(spacing: 12) {
            if !loaded {
                ProgressView()
            } else if assets.count < 2 {
                ContentUnavailableView("This series is already sorted.", systemImage: "checkmark.seal")
            } else if isDone {
                finishedView
            } else {
                duel
            }
        }
        .padding(.bottom, 8)
        .navigationTitle("Series Duel")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { undo() } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .disabled(steps.isEmpty)
                .accessibilityLabel("Undo")
            }
        }
        .sensoryFeedback(.selection, trigger: pickTrigger)
        .sensoryFeedback(.impact(weight: .light), trigger: zoomTrigger)
        .fullScreenCover(item: $zoomTarget, onDismiss: runPendingZoomAction) { target in
            PhotoZoomView(
                assets: [target.champion, target.challenger],
                titles: [Text("Current Favorite"), Text("Other Photo")],
                initialIndex: target.startsWithChampion ? 0 : 1
            ) { asset, dismissZoom in
                Button {
                    let championWins = asset.localIdentifier == target.champion.localIdentifier
                    pendingZoomAction = { pick(championWins: championWins) }
                    dismissZoom()
                } label: {
                    Label("Choose This Photo", systemImage: "crown.fill")
                        .font(.headline)
                        .padding(.horizontal, 22)
                        .frame(height: 54)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .presentationBackground(.clear)
        }
        .onAppear { if !loaded { load() } }
        .onChange(of: isDone) { _, done in
            guard done, assets.indices.contains(championIndex) else { return }
            store.markReviewed(assets[championIndex].localIdentifier)
            store.setSeriesFinished(series.id, true)
        }
    }

    private var duel: some View {
        VStack(spacing: 10) {
            VStack(spacing: 4) {
                Text("Tap the better photo")
                    .font(.headline)
                Text("Duel \(challengerIndex) of \(duelCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                ProgressView(value: Double(challengerIndex - 1), total: Double(duelCount))
                    .padding(.horizontal)
            }
            .padding(.horizontal)

            card(for: assets[championIndex], isChampion: true)
            Text(verbatim: "VS")
                .font(.caption.weight(.heavy))
                .foregroundStyle(.secondary)
            card(for: assets[challengerIndex], isChampion: false)

            Button {
                keepBoth()
            } label: {
                Label("Keep Both", systemImage: "square.on.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.horizontal)
        }
    }

    private func card(for asset: PHAsset, isChampion: Bool) -> some View {
        MediaCard(asset: asset, isActive: false)
            .overlay(alignment: .topLeading) {
                if isChampion {
                    Label("Current Favorite", systemImage: "crown.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.accentColor, in: Capsule())
                        .padding(10)
                }
            }
            .scaleEffect(press?.id == asset.localIdentifier && press?.isActive == true ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: press?.isActive)
            .contentShape(Rectangle())
            .gesture(pressGesture(for: asset, isChampion: isChampion))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { pick(championWins: isChampion) }
        .overlay(alignment: .topTrailing) {
            if asset.mediaType == .image {
                Button { openZoom(startingWithChampion: isChampion) } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .accessibilityLabel("Zoom")
            }
        }
        .accessibilityAction(named: Text("Zoom")) { openZoom(startingWithChampion: isChampion) }
        .id(asset.localIdentifier)
        .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity),
                                removal: .move(edge: .top).combined(with: .opacity)))
        .padding(.horizontal)
        .frame(maxHeight: .infinity)
        .accessibilityLabel(isChampion ? Text("Current Favorite") : Text("Other Photo"))
    }

    private var finishedView: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Label("Best Shot", systemImage: "crown.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.tint)
                Text("\(trashedCount) photos moved to the trash.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
            if assets.indices.contains(championIndex) {
                MediaCard(asset: assets[championIndex], isActive: true)
                    .padding(.horizontal)
                    .frame(maxHeight: .infinity)
            }
            VStack(spacing: 10) {
                if let next = seriesStore.nextSeries(after: series.id, store: store, removed: library.removedIDs) {
                    Button {
                        series = next
                        load()
                    } label: {
                        Text("Next Series").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Button {
                    dismiss()
                } label: {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal)
        }
    }


    private func load() {
        assets = seriesStore.available(in: series, store: store, removed: library.removedIDs)
        championIndex = 0
        challengerIndex = 1
        steps = []
        loaded = true
    }

    private func pick(championWins: Bool) {
        guard !isDone else { return }
        let loserIndex = championWins ? challengerIndex : championIndex
        let loser = assets[loserIndex].localIdentifier
        steps.append(Step(loser: loser, kept: nil, champion: championIndex, challenger: challengerIndex))
        store.moveToTrash(loser)
        pickTrigger += 1
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if !championWins { championIndex = challengerIndex }
            challengerIndex += 1
        }
    }

    /// Tap and long press in one gesture. SwiftUI's tap gesture has no time limit and wins over
    /// `onLongPressGesture`, and a Button fires when a long press ends, so neither works here.
    private func pressGesture(for asset: PHAsset, isChampion: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if press == nil {
                    press = Press(id: asset.localIdentifier)
                    pressTask = Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled, press?.isActive == true else { return }
                        press?.isActive = false
                        press?.openedZoom = true
                        openZoom(startingWithChampion: isChampion)
                    }
                } else if hypot(value.translation.width, value.translation.height) > 12 {
                    pressTask?.cancel()
                    press?.isActive = false
                }
            }
            .onEnded { _ in
                pressTask?.cancel()
                let wasTap = press?.isActive == true && press?.openedZoom == false
                press = nil
                if wasTap { pick(championWins: isChampion) }
            }
    }

    private func openZoom(startingWithChampion: Bool) {
        guard !isDone, zoomTarget == nil,
              assets.indices.contains(championIndex), assets.indices.contains(challengerIndex) else { return }
        let champion = assets[championIndex], challenger = assets[challengerIndex]
        guard champion.mediaType == .image || challenger.mediaType == .image else { return }
        zoomTrigger += 1
        zoomTarget = ZoomTarget(champion: champion, challenger: challenger, startsWithChampion: startingWithChampion)
    }

    /// A pick made in the zoom view runs after it is dismissed, so the duel animation is visible.
    private func runPendingZoomAction() {
        // Presenting the zoom view cancels the card gesture without calling `onEnded`, so reset it here.
        pressTask?.cancel()
        press = nil
        let action = pendingZoomAction
        pendingZoomAction = nil
        action?()
    }

    private func keepBoth() {
        guard !isDone else { return }
        let kept = assets[challengerIndex].localIdentifier
        steps.append(Step(loser: nil, kept: kept, champion: championIndex, challenger: challengerIndex))
        store.markReviewed(kept)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            challengerIndex += 1
        }
    }

    private func undo() {
        guard let last = steps.popLast() else { return }
        if isDone {
            store.setSeriesFinished(series.id, false)
            if assets.indices.contains(championIndex) {
                store.unmarkReviewed(assets[championIndex].localIdentifier)
            }
        }
        if let loser = last.loser {
            store.restore(loser)
            store.unmarkReviewed(loser)
        }
        if let kept = last.kept { store.unmarkReviewed(kept) }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            championIndex = last.champion
            challengerIndex = last.challenger
        }
    }
}
