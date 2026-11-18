import CoreGraphics
import Foundation

enum ImageViewerPDFRenderer {
    static func page(at index: Int, in url: URL) throws -> (CGPDFPage, CGSize, CGPDFDocument) {
        try ImageViewerPipeline.checkFile(url)
        guard let document = CGPDFDocument(url as CFURL) else { throw ImageViewerReadError.damaged }
        guard document.isUnlocked else { throw ImageViewerReadError.lockedPDF }
        guard index > 0, let page = document.page(at: index) else { throw ImageViewerReadError.damaged }
        let crop = page.getBoxRect(.cropBox)
        let size = page.rotationAngle % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
        guard size.width >= 1, size.height >= 1, size.width.isFinite, size.height.isFinite,
              size.width * size.height <= ImageViewerPipeline.sourcePixelLimit else { throw ImageViewerReadError.tooLarge }
        return (page, size, document)
    }

    static func render(_ request: ImageViewerRenderRequest, cancelled: () -> Bool) throws -> ImageViewerFrame {
        if cancelled() { throw CancellationError() }
        let (page, size, document) = try page(at: request.page, in: request.url)
        let scale = CGFloat(min(max(1, request.pixels), ImageViewerPipeline.maximumPrintPixels)) / max(size.width, size.height)
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageViewerReadError.tooLarge
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                     rotate: 0, preserveAspectRatio: true))
        if cancelled() { throw CancellationError() }
        context.drawPDFPage(page)
        if cancelled() { throw CancellationError() }
        guard let image = context.makeImage() else { throw ImageViewerReadError.damaged }
        return ImageViewerFrame(image: image, originalSize: size, pageCount: document.numberOfPages)
    }
}
