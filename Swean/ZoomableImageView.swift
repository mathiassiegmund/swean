import SwiftUI
import UIKit

/// Zoomable image backed by `UIScrollView`: pinch, pan, double-tap zoom and a vertical
/// swipe to dismiss (only while not zoomed in).
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    /// Pixel size of the original; determines the maximum zoom scale.
    let pixelSize: CGSize
    var onZoomChange: (Bool) -> Void = { _ in }
    var onSingleTap: () -> Void = {}
    var onDismissDrag: (CGFloat) -> Void = { _ in }
    var onDismissEnd: (_ translation: CGFloat, _ velocity: CGFloat) -> Void = { _, _ in }

    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView()
        update(view)
        return view
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        update(view)
    }

    private func update(_ view: ZoomScrollView) {
        view.onZoomChange = onZoomChange
        view.onSingleTap = onSingleTap
        view.onDismissDrag = onDismissDrag
        view.onDismissEnd = onDismissEnd
        view.pixelSize = pixelSize
        if view.image !== image { view.image = image }
    }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    var onZoomChange: (Bool) -> Void = { _ in }
    var onSingleTap: () -> Void = {}
    var onDismissDrag: (CGFloat) -> Void = { _ in }
    var onDismissEnd: (CGFloat, CGFloat) -> Void = { _, _ in }

    var pixelSize: CGSize = .zero {
        didSet { if oldValue != pixelSize { updateMaximumZoom() } }
    }

    /// A sharper image with the same aspect ratio is swapped in without losing zoom or position.
    var image: UIImage? {
        didSet {
            imageView.image = image
            if Self.aspect(of: oldValue) == nil
                || abs((Self.aspect(of: oldValue) ?? 0) - (Self.aspect(of: image) ?? 0)) > 0.01 {
                resetLayout()
            }
        }
    }

    private let imageView = UIImageView()
    private let dismissPan = UIPanGestureRecognizer()
    private var lastBoundsSize: CGSize = .zero
    private var isZoomed = false

    private var zoomedIn: Bool { zoomScale > minimumZoomScale + 0.01 }

    init() {
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .clear
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        minimumZoomScale = 1
        maximumZoomScale = 4
        bouncesZoom = true
        isScrollEnabled = false

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)

        dismissPan.addTarget(self, action: #selector(handleDismissPan(_:)))
        dismissPan.maximumNumberOfTouches = 1
        addGestureRecognizer(dismissPan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            resetLayout()
        }
    }

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer === dismissPan {
            guard !zoomedIn else { return false }
            let velocity = dismissPan.velocity(in: self)
            return abs(velocity.y) > abs(velocity.x)
        }
        return super.gestureRecognizerShouldBegin(recognizer)
    }

    // MARK: Layout

    private static func aspect(of image: UIImage?) -> CGFloat? {
        guard let image, image.size.height > 0 else { return nil }
        return image.size.width / image.size.height
    }

    /// Image size at zoom scale 1 (aspect-fit into the bounds).
    private var fitSize: CGSize {
        guard let image, image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    private func resetLayout() {
        zoomScale = minimumZoomScale
        let size = fitSize
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        updateMaximumZoom()
        centerContent()
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
        updateZoomState()
    }

    private func updateMaximumZoom() {
        let fit = fitSize
        guard fit.width > 0 else { return }
        let screenScale = window?.screen.scale ?? traitCollection.displayScale
        // Twice the scale at which one image pixel maps to one screen pixel.
        let nativeZoom = pixelSize.width / (fit.width * max(screenScale, 1))
        maximumZoomScale = min(10, max(4, nativeZoom * 2))
    }

    private func centerContent() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    private func updateZoomState() {
        let zoomed = zoomedIn
        isScrollEnabled = zoomed
        guard zoomed != isZoomed else { return }
        isZoomed = zoomed
        onZoomChange(zoomed)
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        updateZoomState()
    }

    // MARK: Gestures

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomedIn {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let point = recognizer.location(in: imageView)
        let scale = min(maximumZoomScale, 3)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                        width: size.width, height: size.height), animated: true)
    }

    @objc private func handleSingleTap() {
        onSingleTap()
    }

    @objc private func handleDismissPan(_ recognizer: UIPanGestureRecognizer) {
        // Window coordinates, because SwiftUI offsets this view during the gesture.
        let translation = recognizer.translation(in: window).y
        switch recognizer.state {
        case .changed:
            onDismissDrag(translation)
        case .ended, .cancelled, .failed:
            onDismissEnd(translation, recognizer.velocity(in: window).y)
        default:
            break
        }
    }
}
