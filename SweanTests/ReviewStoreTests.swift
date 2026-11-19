import Testing
@testable import Swean

/// ReviewStore persists to the host app's Application Support folder, so every
/// test starts from a reset store and the suite runs serially.
@MainActor
@Suite(.serialized) struct ReviewStoreTests {
    let store: ReviewStore

    init() {
        store = ReviewStore()
        store.resetAll()
    }

    @Test func markAndUnmarkReviewed() {
        store.markReviewed("a")
        #expect(store.isReviewed("a"))
        store.unmarkReviewed("a")
        #expect(!store.isReviewed("a"))
    }

    @Test func moveToTrashAlsoMarksReviewed() {
        store.moveToTrash("a")
        #expect(store.isTrashed("a"))
        #expect(store.isReviewed("a"))
    }

    @Test func restoreKeepsReviewedFlag() {
        store.moveToTrash("a")
        store.restore("a")
        #expect(!store.isTrashed("a"))
        #expect(store.isReviewed("a"))
    }

    @Test func removeFromTrashRemovesOnlyGivenIDs() {
        ["a", "b", "c"].forEach(store.moveToTrash)
        store.removeFromTrash(["a", "c"])
        #expect(store.trash == ["b"])
    }

    @Test func pruneTrashKeepsOnlyExistingAssets() {
        ["a", "b", "c"].forEach(store.moveToTrash)
        store.pruneTrash(keeping: ["b", "x"])
        #expect(store.trash == ["b"])
        #expect(store.reviewed == ["a", "b", "c"])
    }

    @Test func resetProgressClearsReviewedAndTrashForGivenIDs() {
        store.moveToTrash("a")
        store.markReviewed("b")
        store.markReviewed("c")
        store.resetProgress(["a", "b"])
        #expect(store.trash.isEmpty)
        #expect(store.reviewed == ["c"])
    }

    @Test func seriesFinishedToggle() {
        store.setSeriesFinished("s", true)
        #expect(store.isSeriesFinished("s"))
        store.setSeriesFinished("s", false)
        #expect(!store.isSeriesFinished("s"))
    }

    @Test func resetAllClearsEverything() {
        store.moveToTrash("a")
        store.markReviewed("b")
        store.setSeriesFinished("s", true)
        store.resetAll()
        #expect(store.reviewed.isEmpty)
        #expect(store.trash.isEmpty)
        #expect(store.finishedSeries.isEmpty)
    }

    @Test func saveNowPersistsStateForNewInstance() {
        store.moveToTrash("a")
        store.markReviewed("b")
        store.setSeriesFinished("s", true)
        store.saveNow()

        let reloaded = ReviewStore()
        #expect(reloaded.trash == ["a"])
        #expect(reloaded.reviewed == ["a", "b"])
        #expect(reloaded.finishedSeries == ["s"])

        store.resetAll()
        store.saveNow()
    }
}
