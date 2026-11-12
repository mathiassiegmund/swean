import Photos
import UIKit
import Vision
import Observation

/// Eine Serie fast gleicher Fotos, z. B. mehrere Aufnahmen vom selben Motiv.
struct PhotoSeries: Identifiable, Hashable {
    let id: String
    let assets: [PHAsset]

    var date: Date? { assets.first?.creationDate }

    static func == (lhs: PhotoSeries, rhs: PhotoSeries) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Findet Serien in zwei Schritten: Erst werden Fotos gesammelt, die kurz
/// nacheinander aufgenommen wurden. Nur diese werden dann per Vision
/// („Feature Print“) auf Ähnlichkeit verglichen, mit einem Pixelvergleich als
/// Ersatz. Alles läuft auf dem Gerät.
enum SeriesFinder {
    /// Maximaler Abstand zwischen zwei Aufnahmen einer Serie.
    static let maxGap: TimeInterval = 90
    /// Maximale Vision-Distanz. Gemessen: gleiche Serie 0,04–0,10,
    /// verschiedene Motive ab ca. 0,22.
    static let maxVisionDistance: Float = 0.25
    /// Maximale Pixel-Distanz (Ersatzverfahren). Gemessen: gleiche Serie
    /// bis 0,018, verschiedene Motive ab ca. 0,046.
    static let maxPixelDistance: Float = 0.04
    private static let pixelSide = 24

    /// Merkmale eines Fotos für den Vergleich.
    enum Signature {
        /// Vision-Feature-Print (Standard auf dem iPhone).
        case vision(VNFeaturePrintObservation)
        /// Verkleinertes Farbbild (Ersatz, falls Vision nicht verfügbar ist, z. B. im Simulator).
        case pixels([Float])
    }

    /// Fotos (ohne Videos und Bildschirmfotos), aufsteigend nach Datum,
    /// gruppiert nach zeitlicher Nähe. Nur Gruppen ab 2 Fotos.
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

    /// Teilt eine zeitliche Gruppe in Serien wirklich ähnlicher Fotos.
    /// Ein Foto gehört zur laufenden Serie, wenn es dem vorherigen oder dem ersten Foto ähnelt.
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

    /// Kleines Vorschaubild laden (nur lokal, kein iCloud-Download) und Merkmale berechnen.
    static func signature(for asset: PHAsset) -> Signature? {
        // Vorrang für die Oberfläche: warten, solange dort Bilder geladen werden
        // (höchstens 2 Sekunden pro Foto, damit die Suche nie ganz stehen bleibt).
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
        // Im Simulator liefert Vision für jedes Bild denselben Feature Print, daher dort nur das Ersatzverfahren.
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

/// Hält die gefundenen Serien und sucht im Hintergrund danach.
/// Ergebnisse pro Zeitgruppe werden zwischengespeichert, damit ein erneuter
/// Scan nur neue Fotos analysiert.
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

    /// Serien, in denen noch mindestens zwei Fotos übrig sind und die noch nicht entschieden wurden.
    func open(store: ReviewStore, removed: Set<String>) -> [PhotoSeries] {
        series.filter { !store.isSeriesFinished($0.id) && available(in: $0, store: store, removed: removed).count >= 2 }
    }

    func available(in series: PhotoSeries, store: ReviewStore, removed: Set<String>) -> [PHAsset] {
        series.assets.filter { !store.isTrashed($0.localIdentifier) && !removed.contains($0.localIdentifier) }
    }

    /// Wie viele Gruppen gleichzeitig analysiert werden. Mehr bringt kaum Tempo,
    /// bremst aber das Laden der Vorschaubilder in der Oberfläche.
    private static let parallelClusters = 3

    func scan(months: [MonthGroup]) {
        // Solange die Mediathek noch nicht geladen ist, nichts tun. Ein leerer Lauf
        // würde sonst den Zwischenspeicher leeren und alles müsste neu analysiert werden.
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
            // Neueste Gruppen zuerst: die interessieren meist am meisten und erscheinen so sofort.
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
                    // Zwischenstand zeigen und sichern, damit ein Abbruch nichts verliert.
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
            // Einträge für Gruppen, die es nicht mehr gibt, verwerfen.
            if !keys.isEmpty {
                let current = Set(keys)
                cache = cache.filter { current.contains($0.key) }
            }
            publish(results, byID: byID)
            saveCache()
            isScanning = false
            progress = 1
            #if DEBUG
            print("Swean: \(series.count) Serien gefunden in \(String(format: "%.0f", Date().timeIntervalSince(started) * 1000)) ms (\(pending.count) von \(clusters.count) Gruppen neu analysiert)")
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
