import Foundation
import Observation

@MainActor
@Observable
final class ReviewStore {
    private(set) var reviewed: Set<String> = []
    private(set) var trash: Set<String> = []
    /// Serien, die im Serien-Duell schon entschieden wurden.
    private(set) var finishedSeries: Set<String> = []

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private struct Snapshot: Codable {
        var reviewed: [String]
        var trash: [String]
        var finishedSeries: [String]? = nil
    }

    nonisolated private static let fileURL: URL =
        URL.applicationSupportDirectory.appending(path: "review-state.json")

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            reviewed = Set(snapshot.reviewed)
            trash = Set(snapshot.trash)
            finishedSeries = Set(snapshot.finishedSeries ?? [])
        }
    }

    func isReviewed(_ id: String) -> Bool { reviewed.contains(id) }
    func isTrashed(_ id: String) -> Bool { trash.contains(id) }
    func isSeriesFinished(_ id: String) -> Bool { finishedSeries.contains(id) }

    func setSeriesFinished(_ id: String, _ finished: Bool) {
        if finished { finishedSeries.insert(id) } else { finishedSeries.remove(id) }
        scheduleSave()
    }

    func markReviewed(_ id: String) {
        reviewed.insert(id)
        scheduleSave()
    }

    func unmarkReviewed(_ id: String) {
        reviewed.remove(id)
        scheduleSave()
    }

    func moveToTrash(_ id: String) {
        trash.insert(id)
        reviewed.insert(id)
        scheduleSave()
    }

    func restore(_ id: String) {
        trash.remove(id)
        scheduleSave()
    }

    func removeFromTrash<S: Sequence>(_ ids: S) where S.Element == String {
        trash.subtract(ids)
        scheduleSave()
    }

    func pruneTrash(keeping existing: Set<String>) {
        trash.formIntersection(existing)
        scheduleSave()
    }

    func resetProgress<S: Sequence>(_ ids: S) where S.Element == String {
        let set = Set(ids)
        reviewed.subtract(set)
        trash.subtract(set)
        scheduleSave()
    }

    func resetAll() {
        reviewed = []
        trash = []
        finishedSeries = []
        scheduleSave()
    }


    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = Snapshot(reviewed: Array(reviewed), trash: Array(trash), finishedSeries: Array(finishedSeries))
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            ReviewStore.write(snapshot)
        }
    }

    func saveNow() {
        saveTask?.cancel()
        Self.write(Snapshot(reviewed: Array(reviewed), trash: Array(trash), finishedSeries: Array(finishedSeries)))
    }

    nonisolated private static func write(_ snapshot: Snapshot) {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("ReviewStore: Speichern fehlgeschlagen: \(error)")
        }
    }
}
