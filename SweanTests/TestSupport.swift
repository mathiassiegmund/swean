import Photos

/// PHAsset stand-in with a controllable identifier and creation date.
final class FakeAsset: PHAsset, @unchecked Sendable {
    private let id: String
    private let date: Date?

    init(_ id: String, _ date: Date?) {
        self.id = id
        self.date = date
        super.init()
    }

    override var localIdentifier: String { id }
    override var creationDate: Date? { date }
}

let referenceDate = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// Creates an asset taken `seconds` after `referenceDate`.
func asset(_ id: String, at seconds: TimeInterval?) -> FakeAsset {
    FakeAsset(id, seconds.map { referenceDate.addingTimeInterval($0) })
}

func ids(_ clusters: [[PHAsset]]) -> [[String]] {
    clusters.map { $0.map(\.localIdentifier) }
}
