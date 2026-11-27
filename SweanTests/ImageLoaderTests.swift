import Testing
import CoreGraphics
@testable import Swean

@Suite struct ZoomTargetSizeTests {
    @Test func smallPhotoKeepsFullResolution() {
        #expect(ImageLoader.zoomTargetSize(pixelWidth: 4032, pixelHeight: 3024) == CGSize(width: 4032, height: 3024))
    }

    @Test func largePhotoIsCappedOnLongestSide() {
        // 48 MP landscape photo.
        #expect(ImageLoader.zoomTargetSize(pixelWidth: 8064, pixelHeight: 6048) == CGSize(width: 4096, height: 3072))
    }

    @Test func portraitPhotoIsCappedOnHeight() {
        #expect(ImageLoader.zoomTargetSize(pixelWidth: 6048, pixelHeight: 8064) == CGSize(width: 3072, height: 4096))
    }

    @Test func customMaximumIsRespected() {
        #expect(ImageLoader.zoomTargetSize(pixelWidth: 2000, pixelHeight: 1000, maxDimension: 1000) == CGSize(width: 1000, height: 500))
    }

    @Test func unknownDimensionsFallBackToSquareMaximum() {
        #expect(ImageLoader.zoomTargetSize(pixelWidth: 0, pixelHeight: 0) == CGSize(width: 4096, height: 4096))
    }
}
