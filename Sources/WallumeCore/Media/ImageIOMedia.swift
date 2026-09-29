import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageIOMediaError: Error, Equatable {
    case unreadable(URL)
    case missingProperties(URL)
    case artworkFailed(URL)
}

public struct ImageIOMediaProcessor: ImageMediaProcessing {
    public init() {}

    public func inspect(_ source: URL) async throws -> MediaInspection {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ImageIOMediaError.unreadable(source)
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let rawHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw ImageIOMediaError.missingProperties(source)
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsDimensions = [5, 6, 7, 8].contains(orientation)
        let byteCount = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let type = CGImageSourceGetType(imageSource)
            .flatMap { UTType($0 as String) }
        let codec = type?.preferredFilenameExtension?.uppercased()
            ?? source.pathExtension.uppercased()

        return MediaInspection(
            sourceByteCount: Int64(byteCount),
            pixelWidth: swapsDimensions ? rawHeight.intValue : rawWidth.intValue,
            pixelHeight: swapsDimensions ? rawWidth.intValue : rawHeight.intValue,
            frameRate: 0,
            durationSeconds: 0,
            codec: codec
        )
    }

    public func generateArtwork(for source: URL, thumbnail: URL, cover: URL) async throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ImageIOMediaError.unreadable(source)
        }
        try writeJPEG(
            thumbnailImage(from: imageSource, maximumPixelSize: 640, source: source),
            to: thumbnail,
            compression: 0.82
        )
        try writeJPEG(
            thumbnailImage(from: imageSource, maximumPixelSize: 2_560, source: source),
            to: cover,
            compression: 0.92
        )
    }

    private func thumbnailImage(
        from source: CGImageSource,
        maximumPixelSize: Int,
        source sourceURL: URL
    ) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageIOMediaError.artworkFailed(sourceURL)
        }
        return image
    }

    private func writeJPEG(_ image: CGImage, to url: URL, compression: Double) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageIOMediaError.artworkFailed(url)
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: compression] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw ImageIOMediaError.artworkFailed(url)
        }
    }
}
