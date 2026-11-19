import SwiftUI
import Photos

struct TrashView: View {
    let showsDoneButton: Bool

    @Environment(PhotoLibrary.self) private var library
    @Environment(ReviewStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var assets: [PHAsset] = []
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @State private var deletedCount: Int?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    var body: some View {
        Group {
            if assets.isEmpty {
                ContentUnavailableView {
                    if deletedCount == nil {
                        Label("Trash Is Empty", systemImage: "trash")
                    } else {
                        Label("Done!", systemImage: "checkmark.circle")
                    }
                } description: {
                    if let deletedCount {
                        Text("Deleted \(deletedCount) items. They stay in “Recently Deleted” in the Photos app for 30 days.")
                    } else {
                        Text("Swipe a photo up to collect it here.")
                    }
                }
            } else {
                ScrollView {
                    Text("Tap a photo to keep it after all.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(assets, id: \.localIdentifier) { asset in
                            Button {
                                withAnimation {
                                    assets.removeAll { $0.localIdentifier == asset.localIdentifier }
                                    store.restore(asset.localIdentifier)
                                }
                            } label: {
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay { AssetImage(asset: asset) }
                                    .clipped()
                                    .overlay(alignment: .bottomTrailing) {
                                        if asset.mediaType == .video {
                                            Image(systemName: "video.fill")
                                                .font(.caption)
                                                .foregroundStyle(.white)
                                                .shadow(radius: 2)
                                                .padding(6)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Button(role: .destructive) {
                        deleteAll()
                    } label: {
                        Group {
                            if isDeleting {
                                ProgressView().tint(.white)
                            } else {
                                Text("Delete \(assets.count) items")
                                    .bold()
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .disabled(isDeleting)
                    .padding()
                    .background(.bar)
                }
            }
        }
        .navigationTitle("Trash")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            if !assets.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Keep All") {
                        withAnimation {
                            store.removeFromTrash(assets.map(\.localIdentifier))
                            assets = []
                        }
                    }
                }
            }
        }
        .alert("Deletion Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task(id: store.trash) { reloadAssets() }
    }

    private func reloadAssets() {
        let ids = Array(store.trash)
        let found = library.assets(withIDs: ids)
        assets = found
        if found.count < ids.count {
            store.pruneTrash(keeping: Set(found.map(\.localIdentifier)))
        }
    }

    private func deleteAll() {
        let toDelete = assets
        guard !toDelete.isEmpty else { return }
        isDeleting = true
        Task {
            defer { isDeleting = false }
            do {
                try await library.delete(toDelete)
                deletedCount = toDelete.count
                store.removeFromTrash(toDelete.map(\.localIdentifier))
                assets = []
            } catch {
                let nsError = error as NSError
                let cancelled = nsError.domain == PHPhotosErrorDomain && nsError.code == PHPhotosError.userCancelled.rawValue
                if !cancelled { errorMessage = error.localizedDescription }
            }
        }
    }
}
