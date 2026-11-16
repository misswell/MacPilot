import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Single owner of screenshot bytes on disk.
///
/// Every consumer (Quick Access, clipboard, history, pin) references the same
/// artifact; encoding happens once here, through a staging file that is
/// validated before it is atomically committed. The store never deletes a
/// source file before its replacement committed successfully.
final class CaptureArtifactStore: @unchecked Sendable {
    typealias Encoder = @Sendable (CGImage, URL, ScreenCaptureImageFormat, Double) -> Bool
    typealias Validator = @Sendable (URL, Int, Int) -> Bool

    struct WriteRequest: Sendable {
        let captureID: UUID
        let image: SendableScreenCaptureImage
        let directory: URL
        let baseName: String
        let format: ScreenCaptureImageFormat
        let quality: Double
        let isTemporary: Bool

        init(
            captureID: UUID,
            image: SendableScreenCaptureImage,
            directory: URL,
            baseName: String,
            format: ScreenCaptureImageFormat,
            quality: Double,
            isTemporary: Bool
        ) {
            self.captureID = captureID
            self.image = image
            self.directory = directory
            self.baseName = baseName
            self.format = format
            self.quality = quality
            self.isTemporary = isTemporary
        }
    }

    static let shared = CaptureArtifactStore()

    private let fileManager: FileManager
    private let encoder: Encoder
    private let validator: Validator
    private let nameBuilder: @Sendable (String, ScreenCaptureImageFormat) -> String

    init(
        fileManager: FileManager = .default,
        encoder: Encoder? = nil,
        validator: Validator? = nil,
        nameBuilder: (@Sendable (String, ScreenCaptureImageFormat) -> String)? = nil
    ) {
        self.fileManager = fileManager
        self.encoder = encoder ?? Self.imageIOEncoder
        self.validator = validator ?? Self.imageIODecoderValidator
        self.nameBuilder = nameBuilder ?? { baseName, format in
            "\(baseName).\(format.fileExtension)"
        }
    }

    @discardableResult
    func write(_ request: WriteRequest) throws -> CaptureArtifact {
        do {
            try fileManager.createDirectory(at: request.directory, withIntermediateDirectories: true)
        } catch {
            throw CaptureArtifactError.destinationUnavailable
        }
        guard isWritableDirectory(request.directory) else {
            throw CaptureArtifactError.destinationNotWritable
        }

        let finalURL = uniqueFileURL(
            in: request.directory,
            fileName: nameBuilder(request.baseName, request.format)
        )
        let stagingURL = stagingURL(for: finalURL)

        do {
            guard encoder(request.image.value, stagingURL, request.format, request.quality) else {
                throw CaptureArtifactError.encodeFailed
            }
            guard validator(stagingURL, request.image.value.width, request.image.value.height) else {
                throw CaptureArtifactError.validationFailed
            }
            guard let size = fileSize(at: stagingURL), size > 0 else {
                throw CaptureArtifactError.validationFailed
            }
            try fileManager.moveItem(at: stagingURL, to: finalURL)
            return CaptureArtifact(
                captureID: request.captureID,
                url: finalURL,
                isTemporary: request.isTemporary,
                format: request.format,
                pixelWidth: request.image.value.width,
                pixelHeight: request.image.value.height,
                byteCount: size,
                state: .ready
            )
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    /// Promotes a temporary artifact into the export folder.
    ///
    /// Returns the artifact unchanged when it already points at a permanent
    /// file: “save” must never produce a second copy of the same screenshot.
    func promote(
        _ artifact: CaptureArtifact,
        to directory: URL,
        baseName: String,
        format: ScreenCaptureImageFormat? = nil
    ) throws -> CaptureArtifact {
        guard artifact.state == .ready else { throw CaptureArtifactError.notReady }
        guard fileManager.fileExists(atPath: artifact.url.path) else {
            throw CaptureArtifactError.sourceMissing
        }
        guard artifact.isTemporary else { return artifact }

        guard artifact.url.standardizedFileURL.deletingLastPathComponent()
            != directory.standardizedFileURL else {
            // Already inside the export folder; only the temp flag is stale.
            return CaptureArtifact(
                id: artifact.id,
                captureID: artifact.captureID,
                url: artifact.url,
                isTemporary: false,
                format: artifact.format,
                pixelWidth: artifact.pixelWidth,
                pixelHeight: artifact.pixelHeight,
                byteCount: artifact.byteCount,
                state: .ready,
                errorDescription: nil,
                createdAt: artifact.createdAt
            )
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw CaptureArtifactError.destinationUnavailable
        }
        guard isWritableDirectory(directory) else {
            throw CaptureArtifactError.destinationNotWritable
        }

        let targetFormat = format ?? artifact.format
        let finalURL = uniqueFileURL(
            in: directory,
            fileName: nameBuilder(baseName, targetFormat)
        )
        let stagingURL = stagingURL(for: finalURL)

        do {
            try fileManager.copyItem(at: artifact.url, to: stagingURL)
            guard validator(stagingURL, artifact.pixelWidth, artifact.pixelHeight) else {
                throw CaptureArtifactError.validationFailed
            }
            guard let size = fileSize(at: stagingURL), size > 0 else {
                throw CaptureArtifactError.validationFailed
            }
            try fileManager.moveItem(at: stagingURL, to: finalURL)
            // Only now may the temporary source disappear.
            try? fileManager.removeItem(at: artifact.url)
            return CaptureArtifact(
                id: artifact.id,
                captureID: artifact.captureID,
                url: finalURL,
                isTemporary: false,
                format: targetFormat,
                pixelWidth: artifact.pixelWidth,
                pixelHeight: artifact.pixelHeight,
                byteCount: size,
                state: .ready,
                errorDescription: nil,
                createdAt: artifact.createdAt
            )
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    func remove(_ artifact: CaptureArtifact) throws {
        guard fileManager.fileExists(atPath: artifact.url.path) else { return }
        do {
            try fileManager.removeItem(at: artifact.url)
        } catch {
            throw CaptureArtifactError.moveFailed
        }
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    private func isWritableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return fileManager.isWritableFile(atPath: url.path)
    }

    private func stagingURL(for finalURL: URL) -> URL {
        finalURL.deletingLastPathComponent().appendingPathComponent(
            ".\(finalURL.deletingPathExtension().lastPathComponent).\(UUID().uuidString).staging.\(finalURL.pathExtension)"
        )
    }

    private func uniqueFileURL(in directory: URL, fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(fileName)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)_\(index).\(ext)")
            index += 1
        }
        return candidate
    }

    private func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    static func imageIOEncoder(
        _ image: CGImage,
        _ url: URL,
        _ format: ScreenCaptureImageFormat,
        _ quality: Double
    ) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.utType.identifier as CFString,
            1,
            nil
        ) else { return false }
        if format.supportsQuality {
            CGImageDestinationAddImage(destination, image, [
                kCGImageDestinationLossyCompressionQuality: max(0.05, min(1, quality))
            ] as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, nil)
        }
        return CGImageDestinationFinalize(destination)
    }

    static func imageIODecoderValidator(_ url: URL, _ width: Int, _ height: Int) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let decodedWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let decodedHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return false }
        return decodedWidth == width && decodedHeight == height
    }
}
