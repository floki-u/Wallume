import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum AVFoundationMediaError: Error, Equatable {
    case unreadableAsset(URL)
    case missingVideoTrack(URL)
    case unsupportedExport(URL)
    case exportFailed(URL)
    case imageGenerationFailed(URL)
}

public struct AVFoundationMediaInspector: MediaInspecting {
    public init() {}

    public func inspect(_ url: URL) async throws -> MediaInspection {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw AVFoundationMediaError.missingVideoTrack(url) }
        let size = try await displaySize(for: track)
        let duration = try await asset.load(.duration)
        let frameRate = try await track.load(.nominalFrameRate)
        let codec = try await codecName(for: track)
        let byteCount = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber

        return MediaInspection(
            sourceByteCount: byteCount?.int64Value ?? 0,
            pixelWidth: Int(size.width.rounded()),
            pixelHeight: Int(size.height.rounded()),
            frameRate: Double(frameRate),
            durationSeconds: duration.seconds,
            codec: codec
        )
    }

    private func displaySize(for track: AVAssetTrack) async throws -> CGSize {
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }

    private func codecName(for track: AVAssetTrack) async throws -> String {
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first else { return "" }
        return fourCharacterCode(CMFormatDescriptionGetMediaSubType(description))
    }
}

public struct AVFoundationMediaTranscoder: MediaTranscoding {
    private let inspector = AVFoundationMediaInspector()
    /// A single imported asset can be decoded once per active wallpaper surface. 2560 px
    /// covers a 1440p desktop without making two simultaneous 4K/60 HEVC decoders the
    /// default on multi-display Macs.
    private static let smoothPlaybackLongestEdge: CGFloat = 2560

    public init() {}

    public func transcode(
        _ source: URL,
        to destination: URL,
        policy: MediaTranscodePolicy,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        }
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHEVCHighestQuality
        ) else {
            throw AVFoundationMediaError.unsupportedExport(source)
        }
        export.outputURL = destination
        export.outputFileType = .mov
        export.shouldOptimizeForNetworkUse = false
        export.videoComposition = try await videoComposition(for: asset, source: source)
        let exportBox = ExportSessionBox(export)
        let reporter = Task {
            while !Task.isCancelled {
                progress?(Double(exportBox.session.progress))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    exportBox.session.exportAsynchronously {
                        switch exportBox.session.status {
                        case .completed:
                            continuation.resume()
                        case .cancelled:
                            continuation.resume(throwing: CancellationError())
                        case .failed:
                            continuation.resume(
                                throwing: exportBox.session.error ?? AVFoundationMediaError.exportFailed(source)
                            )
                        default:
                            continuation.resume(throwing: AVFoundationMediaError.exportFailed(source))
                        }
                    }
                }
            } onCancel: {
                exportBox.session.cancelExport()
            }
        } catch is CancellationError {
            reporter.cancel()
            _ = await reporter.result
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        } catch {
            reporter.cancel()
            _ = await reporter.result
            throw error
        }
        reporter.cancel()
        _ = await reporter.result
        progress?(1)

        let output = try await inspector.inspect(destination)
        guard output.codec == "hvc1",
              max(output.pixelWidth, output.pixelHeight) <= Int(Self.smoothPlaybackLongestEdge),
              output.frameRate <= 60 else {
            try? FileManager.default.removeItem(at: destination)
            throw AVFoundationMediaError.exportFailed(destination)
        }
    }

    private func videoComposition(for asset: AVAsset, source: URL) async throws -> AVMutableVideoComposition? {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw AVFoundationMediaError.missingVideoTrack(source) }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let frameRate = try await track.load(.nominalFrameRate)
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let displayWidth = abs(transformedRect.width)
        let displayHeight = abs(transformedRect.height)
        let longestEdge = max(displayWidth, displayHeight)
        let scale = min(1, Self.smoothPlaybackLongestEdge / longestEdge)
        let renderSize = CGSize(
            width: max(1, (displayWidth * scale).rounded()),
            height: max(1, (displayHeight * scale).rounded())
        )

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        var normalized = transform
        normalized = normalized.translatedBy(x: -transformedRect.minX, y: -transformedRect.minY)
        if scale < 1 {
            normalized = normalized.scaledBy(x: scale, y: scale)
        }
        layer.setTransform(normalized, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]

        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(min(max(frameRate, 1), 60)))
        return composition
    }
}

public struct AVFoundationArtworkGenerator: ArtworkGenerating {
    public init() {}

    public func generateArtwork(for variant: URL, thumbnail: URL, cover: URL) async throws {
        let asset = AVURLAsset(url: variant)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let duration = try await asset.load(.duration)
        let seconds = duration.seconds.isFinite ? max(0, duration.seconds / 2) : 0
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        let image = try generator.copyCGImage(at: time, actualTime: nil)
        try writeJPEG(image, to: thumbnail, compression: 0.82)
        try writeJPEG(image, to: cover, compression: 0.92)
    }

    private func writeJPEG(_ image: CGImage, to url: URL, compression: Double) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw AVFoundationMediaError.imageGenerationFailed(url)
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: compression] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw AVFoundationMediaError.imageGenerationFailed(url)
        }
    }
}

private func fourCharacterCode(_ code: FourCharCode) -> String {
    let bytes = [
        UInt8((code >> 24) & 0xff),
        UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff),
        UInt8(code & 0xff),
    ]
    return String(bytes: bytes, encoding: .macOSRoman) ?? ""
}

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}
