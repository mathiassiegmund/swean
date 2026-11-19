import Testing
import Photos
@testable import Swean

@Suite struct TimeClusterTests {
    @Test func emptyInputYieldsNoClusters() {
        #expect(SeriesFinder.timeClusters([]).isEmpty)
    }

    @Test func singlePhotoIsNotACluster() {
        #expect(SeriesFinder.timeClusters([asset("a", at: 0)]).isEmpty)
    }

    @Test func photosWithinGapFormOneCluster() {
        let assets = [asset("a", at: 0), asset("b", at: 30), asset("c", at: 100)]
        #expect(ids(SeriesFinder.timeClusters(assets)) == [["a", "b", "c"]])
    }

    @Test func gapIsMeasuredBetweenNeighboursNotFromFirstPhoto() {
        // Each step is within maxGap, even though the total span is much larger.
        let step = SeriesFinder.maxGap - 1
        let assets = (0..<5).map { asset("\($0)", at: Double($0) * step) }
        #expect(SeriesFinder.timeClusters(assets).count == 1)
        #expect(SeriesFinder.timeClusters(assets)[0].count == 5)
    }

    @Test func gapExactlyAtLimitStillJoins() {
        let assets = [asset("a", at: 0), asset("b", at: SeriesFinder.maxGap)]
        #expect(ids(SeriesFinder.timeClusters(assets)) == [["a", "b"]])
    }

    @Test func gapAboveLimitSplits() {
        let assets = [
            asset("a", at: 0), asset("b", at: 10),
            asset("c", at: 10 + SeriesFinder.maxGap + 1), asset("d", at: 20 + SeriesFinder.maxGap + 1),
        ]
        #expect(ids(SeriesFinder.timeClusters(assets)) == [["a", "b"], ["c", "d"]])
    }

    @Test func isolatedPhotosBetweenClustersAreDropped() {
        let assets = [
            asset("a", at: 0), asset("b", at: 5),
            asset("lonely", at: 1_000),
            asset("c", at: 2_000), asset("d", at: 2_005),
        ]
        #expect(ids(SeriesFinder.timeClusters(assets)) == [["a", "b"], ["c", "d"]])
    }

    @Test func trailingClusterIsIncluded() {
        let assets = [asset("lonely", at: 0), asset("a", at: 1_000), asset("b", at: 1_001)]
        #expect(ids(SeriesFinder.timeClusters(assets)) == [["a", "b"]])
    }

    @Test func photosWithoutDateAreSkipped() {
        let assets = [asset("a", at: 0), asset("noDate", at: nil), asset("b", at: 10)]
        #expect(ids(SeriesFinder.timeClusters(assets)) == [["a", "b"]])
    }
}

@Suite struct CacheKeyTests {
    @Test func keyCombinesFirstLastAndCount() {
        let cluster = [asset("first", at: 0), asset("mid", at: 1), asset("last", at: 2)]
        #expect(SeriesFinder.cacheKey(for: cluster) == "first|last|3")
    }

    @Test func keyChangesWhenPhotoIsAdded() {
        let a = [asset("x", at: 0), asset("y", at: 2)]
        let b = [asset("x", at: 0), asset("new", at: 1), asset("y", at: 2)]
        #expect(SeriesFinder.cacheKey(for: a) != SeriesFinder.cacheKey(for: b))
    }
}

@Suite struct PixelSimilarityTests {
    private func pixels(_ value: Float, count: Int = 12) -> SeriesFinder.Signature {
        .pixels(Array(repeating: value, count: count))
    }

    @Test func identicalSignaturesAreSimilar() {
        #expect(SeriesFinder.isSimilar(pixels(0.5), pixels(0.5)))
    }

    @Test func differenceAtThresholdIsSimilar() {
        // Mean absolute difference of exactly maxPixelDistance.
        let a: [Float] = [0, 0, 0, 0]
        let b: [Float] = [SeriesFinder.maxPixelDistance * 4, 0, 0, 0]
        #expect(SeriesFinder.isSimilar(.pixels(a), .pixels(b)))
    }

    @Test func differenceAboveThresholdIsNotSimilar() {
        #expect(!SeriesFinder.isSimilar(pixels(0.2), pixels(0.2 + SeriesFinder.maxPixelDistance * 2)))
    }

    @Test func comparisonIsSymmetric() {
        let a = pixels(0.1), b = pixels(0.5)
        #expect(SeriesFinder.isSimilar(a, b) == SeriesFinder.isSimilar(b, a))
    }

    @Test func differentLengthsAreNotSimilar() {
        #expect(!SeriesFinder.isSimilar(pixels(0.5, count: 3), pixels(0.5, count: 6)))
    }

    @Test func emptySignaturesAreNotSimilar() {
        #expect(!SeriesFinder.isSimilar(.pixels([]), .pixels([])))
    }
}

@Suite struct PhotoSeriesTests {
    @Test func equalityAndHashUseIDOnly() {
        let a = PhotoSeries(id: "s", assets: [asset("1", at: 0)])
        let b = PhotoSeries(id: "s", assets: [asset("2", at: 50), asset("3", at: 60)])
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
        #expect(a != PhotoSeries(id: "other", assets: a.assets))
    }

    @Test func dateIsCreationDateOfFirstAsset() {
        let series = PhotoSeries(id: "s", assets: [asset("1", at: 10), asset("2", at: 20)])
        #expect(series.date == referenceDate.addingTimeInterval(10))
        #expect(PhotoSeries(id: "empty", assets: []).date == nil)
    }
}
