import Foundation
import ImageIO

struct ImageViewerInformation: Sendable {
    let rows: [Row]

    struct Row: Sendable {
        let key: String
        let value: String
    }

    static func read(_ request: ImageViewerRenderRequest, sketch: ImageViewerSketchPreview,
                     cancelled: () -> Bool) throws -> Self {
        let url = request.url
        var rows = [Row(key: "viewerName", value: url.lastPathComponent),
                    Row(key: "viewerType", value: url.pathExtension.uppercased())]
        func add(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            rows.append(Row(key: key, value: value))
        }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            add("viewerFileSize", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if url.pathExtension.lowercased() == "pdf" {
            let (_, size, document) = try ImageViewerPDFRenderer.page(at: request.page, in: url)
            add("viewerDimensions", "\(Int(size.width)) × \(Int(size.height)) pt")
            add("viewerPage", "\(request.page) / \(document.numberOfPages)")
            return Self(rows: rows)
        }
        let source = try ImageViewerPipeline.source(url, sketch: sketch, cancelled: cancelled)
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        if let properties, let size = ImageViewerPipeline.orientedSize(properties),
           size.width * size.height <= ImageViewerPipeline.sourcePixelLimit {
            add("viewerDimensions", "\(Int(size.width)) × \(Int(size.height)) px")
        }
        let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gps = properties?[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        add("viewerDate", exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
        add("viewerMake", tiff?[kCGImagePropertyTIFFMake] as? String)
        add("viewerCamera", tiff?[kCGImagePropertyTIFFModel] as? String)
        add("viewerLens", exif?[kCGImagePropertyExifLensModel] as? String)
        if let aperture = exif?[kCGImagePropertyExifFNumber] as? NSNumber {
            add("viewerAperture", "ƒ/\(aperture)")
        }
        if let exposure = (exif?[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue,
           exposure.isFinite, exposure > 0 {
            add("viewerShutter", exposure < 1 ? String(format: "1/%.0f s", 1 / exposure) : "\(exposure) s")
        }
        if let iso = exif?[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber] {
            add("viewerISO", iso.map(\.stringValue).joined(separator: ", "))
        } else if let iso = exif?[kCGImagePropertyExifISOSpeedRatings] as? NSNumber {
            add("viewerISO", iso.stringValue)
        }
        if let focal = exif?[kCGImagePropertyExifFocalLength] as? NSNumber {
            add("viewerFocal", "\(focal) mm")
        }
        if let latitude = gps?[kCGImagePropertyGPSLatitude] as? NSNumber,
           let longitude = gps?[kCGImagePropertyGPSLongitude] as? NSNumber {
            let latRef = gps?[kCGImagePropertyGPSLatitudeRef] as? String ?? ""
            let lonRef = gps?[kCGImagePropertyGPSLongitudeRef] as? String ?? ""
            add("viewerGPS", "\(latitude)°\(latRef), \(longitude)°\(lonRef)")
        }
        return Self(rows: rows)
    }
}
