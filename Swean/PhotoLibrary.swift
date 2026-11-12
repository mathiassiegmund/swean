import Photos
import PhotosUI
import UIKit
import AVFoundation
import Observation

/// Alle Medien eines Kalendermonats (oder eine andere Auswahl, z. B. der Zufallsmix).
struct MonthGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let date: Date
    var assets: [PHAsset]

    static func == (lhs: MonthGroup, rhs: MonthGroup) -> Bool {
        lhs.id == rhs.id && lhs.assets.count == rhs.assets.count
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Zugriff auf die Fotomediathek: Laden, Alben, Favoriten, Löschen.
@MainActor
@Observable
final class PhotoLibrary: NSObject {
    var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var months: [MonthGroup] = []
    var albums: [PHAssetCollection] = []
    var isLoading = false
    /// IDs von Medien, die seit dem Start gelöscht wurden (in Swean oder anderswo).
    /// Offene Ansichten nutzen das, um verschwundene Fotos auszublenden.
    private(set) var removedIDs: Set<String> = []

    @ObservationIgnored private var allAssets: PHFetchResult<PHAsset>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var registered = false

    override init() {
        super.init()
        if canRead { start() }
    }

    var canRead: Bool { status == .authorized || status == .limited }

    var totalCount: Int { months.reduce(0) { $0 + $1.assets.count } }

    func requestAccess() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if canRead { start() }
    }

    func refreshStatus() {
        let newStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard newStatus != status else { return }
        status = newStatus
        if canRead { start() }
    }

    private func start() {
        if !registered {
            PHPhotoLibrary.shared().register(self)
            registered = true
        }
        Task {
            #if DEBUG
            await seedDemoAlbumsIfRequested()
            #endif
            await reload()
        }
    }

    #if DEBUG
    /// Nur für Screenshots: Startargument `-SweanDemoAlbums "Bali,Berlin"` legt fehlende Alben an.
    private func seedDemoAlbumsIfRequested() async {
        guard let names = UserDefaults.standard.string(forKey: "SweanDemoAlbums") else { return }
        let existing = Set(PhotoLibrary.fetchAlbums().compactMap(\.localizedTitle))
        for name in names.split(separator: ",").map(String.init) where !existing.contains(name) {
            _ = try? await createAlbum(named: name)
        }
    }
    #endif

    /// Öffnet die iOS-Auswahl, mit der man bei eingeschränktem Zugriff weitere Fotos freigibt.
    func presentLimitedLibraryPicker() {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var controller = scene?.keyWindow?.rootViewController else { return }
        while let presented = controller.presentedViewController { controller = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }

    func reload() async {
        isLoading = months.isEmpty
        #if DEBUG
        let started = Date()
        #endif
        let (result, groups) = await Task.detached(priority: .userInitiated) {
            PhotoLibrary.buildMonths()
        }.value
        #if DEBUG
        print("Swean: \(result.count) Medien in \(groups.count) Gruppen geladen in \(String(format: "%.0f", Date().timeIntervalSince(started) * 1000)) ms")
        #endif
        allAssets = result
        months = groups
        albums = PhotoLibrary.fetchAlbums()
        isLoading = false
    }

    // MARK: - Laden

    nonisolated static func buildMonths() -> (PHFetchResult<PHAsset>, [MonthGroup]) {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
        )
        let result = PHAsset.fetchAssets(with: options)

        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")

        var groups: [MonthGroup] = []
        var indexByKey: [String: Int] = [:]
        result.enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate else {
                if let i = indexByKey["none"] {
                    groups[i].assets.append(asset)
                } else {
                    indexByKey["none"] = groups.count
                    groups.append(MonthGroup(id: "none", title: String(localized: "No Date"), date: .distantPast, assets: [asset]))
                }
                return
            }
            let comps = calendar.dateComponents([.year, .month], from: date)
            let key = String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
            if let i = indexByKey[key] {
                groups[i].assets.append(asset)
            } else {
                indexByKey[key] = groups.count
                let start = calendar.date(from: comps) ?? date
                groups.append(MonthGroup(id: key, title: formatter.string(from: start), date: start, assets: [asset]))
            }
        }
        return (result, groups)
    }

    nonisolated static func fetchAlbums() -> [PHAssetCollection] {
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var list: [PHAssetCollection] = []
        result.enumerateObjects { collection, _, _ in
            if collection.canPerform(.addContent) { list.append(collection) }
        }
        return list.sorted {
            ($0.localizedTitle ?? "").localizedStandardCompare($1.localizedTitle ?? "") == .orderedAscending
        }
    }

    func assets(withIDs ids: [String]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        return list
    }

    func albumIDs(containing asset: PHAsset) -> Set<String> {
        let result = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var ids = Set<String>()
        result.enumerateObjects { collection, _, _ in ids.insert(collection.localIdentifier) }
        return ids
    }

    // MARK: - Änderungen

    func add(_ asset: PHAsset, to album: PHAssetCollection) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.addAssets([asset] as NSArray)
        }
    }

    func remove(_ asset: PHAsset, from album: PHAssetCollection) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.removeAssets([asset] as NSArray)
        }
    }

    func createAlbum(named title: String) async throws -> PHAssetCollection? {
        final class Box: @unchecked Sendable { var id: String? }
        let box = Box()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            box.id = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        albums = PhotoLibrary.fetchAlbums()
        guard let id = box.id else { return nil }
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    }

    func setFavorite(_ asset: PHAsset, _ favorite: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).isFavorite = favorite
        }
    }

    /// Löscht Medien. iOS zeigt dabei selbst eine Bestätigung an; gelöschte Medien
    /// landen 30 Tage im Album „Zuletzt gelöscht“.
    func delete(_ assets: [PHAsset]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    fileprivate func handle(_ change: PHChange) {
        if let all = allAssets, let details = change.changeDetails(for: all) {
            allAssets = details.fetchResultAfterChanges
            if details.hasIncrementalChanges {
                let removed = details.removedObjects.map(\.localIdentifier)
                if !removed.isEmpty { removedIDs.formUnion(removed) }
            }
            let onlyContentChanged = details.hasIncrementalChanges
                && details.insertedObjects.isEmpty
                && details.removedObjects.isEmpty
            if !onlyContentChanged { scheduleReload() }
        }
        albums = PhotoLibrary.fetchAlbums()
    }
}

extension PhotoLibrary: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.handle(changeInstance) }
    }
}

/// Lädt Vorschaubilder und Videos über PhotoKit (inkl. iCloud-Download).
final class ImageLoader {
    static let shared = ImageLoader()
    let manager = PHCachingImageManager()

    /// Zahl der Bildanfragen, auf die die Oberfläche gerade wartet. Die Seriensuche
    /// pausiert, solange sie größer als null ist, damit sichtbare Bilder Vorrang haben.
    /// Hängende Anfragen (z. B. ein langsamer iCloud-Download) zählen nach einer Sekunde
    /// ohne Bewegung nicht mehr, damit die Suche nicht endlos wartet.
    private let activeLock = NSLock()
    private var activeRequests = 0
    private var lastActivity = Date.distantPast

    var isBusy: Bool {
        activeLock.lock(); defer { activeLock.unlock() }
        return activeRequests > 0 && Date().timeIntervalSince(lastActivity) < 1
    }

    private func changeActive(by delta: Int) {
        activeLock.lock()
        activeRequests += delta
        if delta > 0 { lastActivity = Date() }
        activeLock.unlock()
    }

    private func noteActivity() {
        activeLock.lock(); lastActivity = Date(); activeLock.unlock()
    }

    enum ImageEvent {
        case image(UIImage)
        /// Kein Bild bekommen, auch nicht im zweiten Versuch (z. B. iCloud-Download fehlgeschlagen).
        case failed
    }

    /// Liefert erst ein schnelles, dann das scharfe Bild. Kommt am Ende kein Bild an,
    /// wird einmal mit höchster Qualität nachgeladen, danach `.failed` gemeldet.
    func images(for asset: PHAsset, targetSize: CGSize, contentMode: PHImageContentMode) -> AsyncStream<ImageEvent> {
        let manager = self.manager
        return AsyncStream { continuation in
            final class State: @unchecked Sendable {
                var requestID: PHImageRequestID = PHInvalidImageRequestID
                var gotImage = false
            }
            let state = State()
            self.changeActive(by: 1)

            func request(_ mode: PHImageRequestOptionsDeliveryMode, isRetry: Bool) {
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = mode
                options.resizeMode = isRetry ? .exact : .fast
                state.requestID = manager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode, options: options) { image, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true {
                        continuation.finish()
                        return
                    }
                    self.noteActivity()
                    if let image {
                        state.gotImage = true
                        continuation.yield(.image(image))
                    }
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    guard !degraded else { return }
                    let finalImageMissing = image == nil
                    if finalImageMissing && !isRetry {
                        request(.highQualityFormat, isRetry: true)
                    } else {
                        if finalImageMissing && !state.gotImage { continuation.yield(.failed) }
                        continuation.finish()
                    }
                }
            }
            request(.opportunistic, isRetry: false)
            continuation.onTermination = { [weak self] _ in
                manager.cancelImageRequest(state.requestID)
                self?.changeActive(by: -1)
            }
        }
    }

    func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic
            manager.requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }
}
