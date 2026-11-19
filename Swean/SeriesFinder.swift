import Photos
import UIKit
import Vision
import Observation

/// A series of nearly identical photos, e.g. several shots of the same subject.
struct PhotoSeries: Identifiable, Hashable {
    let id: String
    let assets: [PHAsset]

    var date: Date? { assets.first?.creationDate }

    static func == (lhs: PhotoSeries, rhs: PhotoSeries) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Finds series in two steps: first, photos taken in quick succession are
/// grouped together. Only those are then compared for similarity using Vision
/// ("feature print"), with a pixel comparison as fallback. Everything runs
/// on device.
enum SeriesFinder {
    /// Maximum time between two shots of the same series.
    static let maxGap: TimeInterval = 90
    /// Maximum Vision distance. Measured: same series 0.04–0.10,
    /// different subjects from about 0.22.
    static let maxVisionDistance: Float = 0.25
    /// Maximum pixel distance (fallback). Measured: same series up to
    /// 0.018, different subjects from about 0.046.
    static let maxPixelDistance: Float = 0.04
    private static let pixelSide = 24

    /// Features of a photo used for comparison.
    enum Signature {
        /// Vision feature print (default on iPhone).
        case vision(VNFeaturePrintObservation)
        /// Downscaled color image (fallback when Vision is unavailable, e.g. in the Simulator).
        case pixels([Float])
    }

    /// Photos (no videos or screenshots), sorted ascending by date,
    /// grouped by proximity in time. Only groups of at least 2 photos.
    static func timeClusters(_ assets: [PHAsset]) -> [[PHAsset]] {
        var clusters: [[PHAsset]] = []
        var current: [PHAsset] = []
        var lastDate: Date?
        for asset in assets {
            guard let date = asset.creationDate else { continue }
            if let lastDate, date.timeIntervalSince(lastDate) <= maxGap {
                current.append(asset)
            } else {
                if current.count >= 2 { clusters.append(current) }
                current = [asset]
            }
            lastDate = date
        }
        if current.count >= 2 { clusters.append(current) }
        return clusters
    }

    static func cacheKey(for cluster: [PHAsset]) -> String {
        "\(cluster.first!.localIdentifier)|\(cluster.last!.localIdentifier)|\(cluster.count)"
    }

    /// Splits a time cluster into series of truly similar photos.
    /// A photo joins the current series if it resembles the previous or the first photo.
    static func similarGroups(in cluster: [PHAsset]) -> [[String]] {
        let signatures = cluster.map(signature(for:))
        var groups: [[String]] = []
        var current: [Int] = []
        func close() {
            if current.count >= 2 { groups.append(current.map { cluster[$0].localIdentifier }) }
        }
        for i in cluster.indices {
            guard let sig = signatures[i] else {
                close()
                current = []
                continue
            }
            let matchesLast = current.last.flatMap { signatures[$0] }.map { isSimilar(sig, $0) } ?? false
            let matchesFirst = current.first.flatMap { signatures[$0] }.map { isSimilar(sig, $0) } ?? false
            if matchesLast || matchesFirst {
                current.append(i)
            } else {
                close()
                current = [i]
            }
        }
        close()
        return groups
    }

    static func isSimilar(_ a: Signature, _ b: Signature) -> Bool {
        switch (a, b) {
        case let (.vision(x), .vision(y)):
            var value: Float = .greatestFiniteMagnitude
            guard (try? x.computeDistance(&value, to: y)) != nil else { return false }
            return value <= maxVisionDistance
        case let (.pixels(x), .pixels(y)):
            guard x.count == y.count, !x.isEmpty else { return false }
            let diff = zip(x, y).reduce(Float(0)) { $0 + abs($1.0 - $1.1) } / Float(x.count)
            return diff <= maxPixelDistance
        default:
            return false
        }
    }

    /// Loads a small thumbnail (local only, no iCloud download) and computes its features.
    static func signature(for asset: PHAsset) -> Signature? {
        // Give the UI priority: wait while it is loading images
        // (at most 2 seconds per photo, so the scan never stalls completely).
        var waited = 0
        while ImageLoader.shared.isBusy && waited < 40 {
            Thread.sleep(forTimeInterval: 0.05)
            waited += 1
        }
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        var result: UIImage?
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 256, height: 256),
                                              contentMode: .aspectFit, options: options) { image, _ in
            result = image
        }
        guard let image = result, let cgImage = image.cgImage else { return nil }
        #if !targetEnvironment(simulator)
        // In the Simulator, Vision returns the same feature print for every image, so only the fallback is used there.
        if let print = visionPrint(cgImage, orientation: CGImagePropertyOrientation(image.imageOrientation)) {
            return .vision(print)
        }
        #endif
        return pixelSignature(cgImage).map(Signature.pixels)
    }

    private static func visionPrint(_ image: CGImage, orientation: CGImagePropertyOrientation) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        guard (try? handler.perform([request])) != nil else { return nil }
        return request.results?.first
    }

    private static func pixelSignature(_ image: CGImage) -> [Float]? {
        let side = pixelSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var values: [Float] = []
        values.reserveCapacity(side * side * 3)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            values.append(Float(pixels[i]) / 255)
            values.append(Float(pixels[i + 1]) / 255)
            values.append(Float(pixels[i + 2]) / 255)
        }
        return values
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

/// Holds the detected series and searches for them in the background.
/// Results are cached per time cluster, so a rescan only analyzes new photos.
@MainActor
@Observable
final class SeriesStore {
    private(set) var series: [PhotoSeries] = []
    private(set) var isScanning = false
    private(set) var progress: Double = 0

    @ObservationIgnored private var cache: [String: [[String]]] = [:]
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var lastSignature = ""

    nonisolated private static let cacheURL: URL =
        URL.applicationSupportDirectory.appending(path: "series-cache.json")

    init() {
        if let data = try? Data(contentsOf: Self.cacheURL),
           let decoded = try? JSONDecoder().decode([String: [[String]]].self, from: data) {
            cache = decoded
        }
    }

    /// Series that still have at least two photos left and have not been decided yet.
    func open(store: ReviewStore, removed: Set<String>) -> [PhotoSeries] {
        series.filter { !store.isSeriesFinished($0.id) && available(in: $0, store: store, removed: removed).count >= 2 }
    }

    func available(in series: PhotoSeries, store: ReviewStore, removed: Set<String>) -> [PHAsset] {
        series.assets.filter { !store.isTrashed($0.localIdentifier) && !removed.contains($0.localIdentifier) }
    }

    /// How many clusters are analyzed concurrently. More barely improves speed
    /// but slows down thumbnail loading in the UI.
    private static let parallelClusters = 3

    func scan(months: [MonthGroup]) {
        // Do nothing until the library has loaded. An empty run would otherwise
        // clear the cache and everything would have to be analyzed again.
        guard !months.isEmpty else { return }
        let total = months.reduce(0) { $0 + $1.assets.count }
        let signature = "\(months.count)|\(total)|\(months.first?.assets.first?.localIdentifier ?? "")"
        guard signature != lastSignature else { return }
        lastSignature = signature

        let photos = Array(months.flatMap(\.assets)
            .filter { $0.mediaType == .image && !$0.mediaSubtypes.contains(.photoScreenshot) }
            .reversed())
        let byID = Dictionary(photos.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { a, _ in a })

        scanTask?.cancel()
        isScanning = true
        progress = 0
        scanTask = Task {
            #if DEBUG
            let started = Date()
            #endif
            // Newest clusters first: they are usually the most interesting and show up right away.
            let clusters: [[PHAsset]] = await Task.detached(priority: .utility) {
                Array(SeriesFinder.timeClusters(photos).reversed())
            }.value
            guard !Task.isCancelled else { return }

            let keys = clusters.map(SeriesFinder.cacheKey(for:))
            var results = [[[String]]?](repeating: nil, count: clusters.count)
            var pending: [Int] = []
            for i in clusters.indices {
                if let cached = cache[keys[i]] { results[i] = cached } else { pending.append(i) }
            }
            publish(results, byID: byID)
            var finished = clusters.count - pending.count
            progress = clusters.isEmpty ? 1 : Double(finished) / Double(clusters.count)

            await withTaskGroup(of: (Int, [[String]]).self) { group in
                var queue = pending.makeIterator()
                func enqueue() {
                    guard let i = queue.next() else { return }
                    let cluster = clusters[i]
                    group.addTask(priority: .utility) { (i, SeriesFinder.similarGroups(in: cluster)) }
                }
                for _ in 0..<Self.parallelClusters { enqueue() }
                var sinceSave = 0
                while let (i, groups) = await group.next() {
                    if Task.isCancelled { group.cancelAll(); break }
                    results[i] = groups
                    cache[keys[i]] = groups
                    finished += 1
                    sinceSave += 1
                    progress = Double(finished) / Double(clusters.count)
                    // Publish and persist intermediate results so a cancellation loses nothing.
                    if sinceSave >= 25 {
                        sinceSave = 0
                        publish(results, byID: byID)
                        saveCache()
                    }
                    enqueue()
                }
            }
            guard !Task.isCancelled else {
                saveCache()
                return
            }
            // Drop entries for clusters that no longer exist.
            if !keys.isEmpty {
                let current = Set(keys)
                cache = cache.filter { current.contains($0.key) }
            }
            publish(results, byID: byID)
            saveCache()
            isScanning = false
            progress = 1
            #if DEBUG
            print("Swean: found \(series.count) series in \(String(format: "%.0f", Date().timeIntervalSince(started) * 1000)) ms (\(pending.count) of \(clusters.count) clusters newly analyzed)")
            #endif
        }
    }

    private func publish(_ results: [[[String]]?], byID: [String: PHAsset]) {
        series = results.compactMap { $0 }.flatMap { groups in
            groups.reversed().compactMap { ids -> PhotoSeries? in
                let assets = ids.compactMap { byID[$0] }
                return assets.count >= 2 ? PhotoSeries(id: ids[0], assets: assets) : nil
            }
        }
    }

    private func saveCache() {
        let snapshot = cache
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: SeriesStore.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: SeriesStore.cacheURL, options: .atomic)
        }
    }

    func nextSeries(after id: String, store: ReviewStore, removed: Set<String>) -> PhotoSeries? {
        open(store: store, removed: removed).first { $0.id != id }
    }
}
