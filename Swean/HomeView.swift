import SwiftUI
import Photos

struct HomeView: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(ReviewStore.self) private var store
    @Environment(SeriesStore.self) private var seriesStore
    @State private var path = NavigationPath()
    @State private var confirmResetAll = false
    @State private var showPrivacy = false
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    private var reviewedTotal: Int {
        library.months.reduce(0) { sum, month in
            sum + month.assets.reduce(0) { $0 + (store.isReviewed($1.localIdentifier) ? 1 : 0) }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if library.status == .limited {
                    Section {
                        Label("Limited access – Swean only sees the photos you selected.",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                        Button("Change Selection", systemImage: "photo.badge.plus") {
                            library.presentLimitedLibraryPicker()
                        }
                        Button("Allow Access to All Photos", systemImage: "gear") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }

                if !library.months.isEmpty {
                    Section {
                        overview
                        Button {
                            startShuffle()
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }
                        .disabled(reviewedTotal >= library.totalCount)
                        NavigationLink {
                            SeriesListView()
                        } label: {
                            Label {
                                HStack {
                                    Text("Series Duel")
                                    Spacer()
                                    if seriesStore.isScanning {
                                        ProgressView()
                                    } else {
                                        let count = seriesStore.open(store: store, removed: library.removedIDs).count
                                        if count > 0 {
                                            Text("\(count)")
                                                .foregroundStyle(.secondary)
                                                .monospacedDigit()
                                        }
                                    }
                                }
                            } icon: {
                                Image(systemName: "trophy")
                            }
                        }
                        NavigationLink {
                            TrashView(showsDoneButton: false)
                        } label: {
                            Label {
                                HStack {
                                    Text("Trash")
                                    Spacer()
                                    if !store.trash.isEmpty {
                                        Text("\(store.trash.count)")
                                            .foregroundStyle(.red)
                                            .monospacedDigit()
                                    }
                                }
                            } icon: {
                                Image(systemName: "trash")
                            }
                        }
                    }

                    Section("By Month") {
                        ForEach(library.months) { month in
                            NavigationLink(value: month) {
                                MonthRow(month: month)
                            }
                            .swipeActions {
                                Button("Reset") {
                                    store.resetProgress(month.assets.map(\.localIdentifier))
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }
            }
            .overlay {
                if library.isLoading {
                    ProgressView("Loading photos …")
                } else if library.months.isEmpty {
                    ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle",
                                           description: Text("No photos or videos were found in your library."))
                }
            }
            .navigationTitle("Swean")
            .navigationDestination(for: MonthGroup.self) { month in
                ReviewView(title: month.title, assets: month.assets)
            }
            .refreshable { await library.reload() }
            .task(id: library.months.count &+ library.totalCount) { seriesStore.scan(months: library.months) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker(selection: $appearance) {
                            ForEach(AppAppearance.allCases) { option in
                                Label(option.title, systemImage: option.icon).tag(option)
                            }
                        } label: {
                            Label("Appearance", systemImage: "circle.lefthalf.filled")
                        }
                        .pickerStyle(.menu)
                        Section {
                            Button("Privacy Policy", systemImage: "hand.raised") { showPrivacy = true }
                            Link(destination: LegalLinks.imprint) {
                                Label("Legal Notice", systemImage: "info.circle")
                            }
                        }
                        Button("Reset All Progress", systemImage: "arrow.counterclockwise", role: .destructive) {
                            confirmResetAll = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showPrivacy) {
                NavigationStack { PrivacyView() }
            }
            .confirmationDialog("Reset progress?", isPresented: $confirmResetAll, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { store.resetAll() }
            } message: {
                Text("All items will be marked as unsorted again and the trash will be emptied. No photos will be deleted.")
            }
        }
    }

    private var overview: some View {
        let total = library.totalCount
        let done = reviewedTotal
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(done)")
                    .font(.system(.largeTitle, design: .rounded).bold())
                    .monospacedDigit()
                Text("of \(total) sorted")
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(done), total: Double(max(total, 1)))
        }
        .padding(.vertical, 4)
    }

    private func startShuffle() {
        let pool = library.months.flatMap(\.assets).filter { !store.isReviewed($0.localIdentifier) }
        let picks = Array(pool.shuffled().prefix(50))
        path.append(MonthGroup(id: "shuffle-\(UUID().uuidString)", title: String(localized: "Shuffle"), date: .now, assets: picks))
    }
}

private struct MonthRow: View {
    let month: MonthGroup
    @Environment(ReviewStore.self) private var store

    var body: some View {
        let total = month.assets.count
        let done = month.assets.reduce(0) { $0 + (store.isReviewed($1.localIdentifier) ? 1 : 0) }
        HStack(spacing: 12) {
            if let first = month.assets.first {
                AssetImage(asset: first)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(month.title)
                    .font(.headline)
                Text("\(done) of \(total) sorted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .tint(done == total ? .green : .accentColor)
            }
            if done == total {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            }
        }
        .padding(.vertical, 2)
    }
}
