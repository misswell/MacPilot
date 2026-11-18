import CoreGraphics

struct ImageViewerGeometry: Equatable {
    private(set) var turn = 0
    private(set) var absoluteZoom: CGFloat?
    private(set) var pan = CGPoint.zero

    var swapsAxes: Bool { turn % 2 == 1 }
    var radians: CGFloat { -CGFloat(turn) * .pi / 2 }

    func fitScale(_ original: CGSize, in viewport: CGSize) -> CGFloat {
        guard original.width > 0, original.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        let dimensions = swapsAxes ? CGSize(width: original.height, height: original.width) : original
        return min(viewport.width / dimensions.width, viewport.height / dimensions.height)
    }

    func pointScale(_ original: CGSize, in viewport: CGSize, backing: CGFloat) -> CGFloat {
        absoluteZoom.map { $0 / max(1, backing) } ?? fitScale(original, in: viewport)
    }

    mutating func fit() {
        absoluteZoom = nil
        pan = .zero
    }

    mutating func actualSize() {
        absoluteZoom = 1
        pan = .zero
    }

    mutating func rotate(_ direction: Int) {
        turn = (turn + direction % 4 + 4) % 4
        pan = .zero
    }

    mutating func zoom(by factor: CGFloat, original: CGSize, viewport: CGSize, backing: CGFloat,
                       anchor: CGPoint = .zero) {
        guard factor.isFinite, factor > 0 else { return }
        let current = pointScale(original, in: viewport, backing: backing) * max(1, backing)
        let next = min(max(current * factor, 0.05), 8)
        let ratio = next / current
        absoluteZoom = next
        pan = CGPoint(x: anchor.x + (pan.x - anchor.x) * ratio, y: anchor.y + (pan.y - anchor.y) * ratio)
        clamp(original: original, viewport: viewport, backing: backing)
    }

    mutating func move(_ delta: CGPoint, original: CGSize, viewport: CGSize, backing: CGFloat) {
        pan.x += delta.x
        pan.y += delta.y
        clamp(original: original, viewport: viewport, backing: backing)
    }

    mutating func clamp(original: CGSize, viewport: CGSize, backing: CGFloat) {
        let scale = pointScale(original, in: viewport, backing: backing)
        let maxX = max(0, ((swapsAxes ? original.height : original.width) * scale - viewport.width) / 2)
        let maxY = max(0, ((swapsAxes ? original.width : original.height) * scale - viewport.height) / 2)
        pan = CGPoint(x: min(max(pan.x, -maxX), maxX), y: min(max(pan.y, -maxY), maxY))
    }
}
