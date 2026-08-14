import Foundation
import ImageIO
import UniformTypeIdentifiers

public protocol TahoeThumbnailRendering: Sendable {
    func renderPNG(from source: URL, to destination: URL) throws
}

public enum TahoeThumbnailRendererError: Error, Equatable, Sendable {
    case unreadableSource(URL)
    case cannotCreateDestination(URL)
    case writeFailed(URL)
}

/// Converts Wallume's JPEG cover into the PNG preview format used by Apple's Aerial catalog.
/// The conversion is intentionally local and deterministic; the source cover is never altered.
public struct PNGTahoeThumbnailRenderer: TahoeThumbnailRendering {
    public init() {}

    public func renderPNG(from source: URL, to destination: URL) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw TahoeThumbnailRendererError.unreadableSource(source)
        }
        guard let imageDestination = CGImageDestinationCreateWithURL(
            destination as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw TahoeThumbnailRendererError.cannotCreateDestination(destination) }
        CGImageDestinationAddImage(imageDestination, image, nil)
        guard CGImageDestinationFinalize(imageDestination) else {
            throw TahoeThumbnailRendererError.writeFailed(destination)
        }
    }
}

/// Test-only/default compatibility renderer.  Production composes `PNGTahoeThumbnailRenderer`
/// explicitly at the process boundary; this keeps the transaction usable with synthetic files.
public struct CopyingTahoeThumbnailRenderer: TahoeThumbnailRendering {
    private let files: any FileStore

    public init(files: any FileStore) { self.files = files }

    public func renderPNG(from source: URL, to destination: URL) throws {
        try files.copyExclusively(source, to: destination)
    }
}
