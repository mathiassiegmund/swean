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
        Button {
            pick(championWins: isChampion)
        } label: {
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
        }
        .buttonStyle(DuelCardStyle())
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

private struct DuelCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
