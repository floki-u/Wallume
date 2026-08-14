import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Creates the media profile used by Tahoe's native Aerial lock-screen renderer.
///
/// Tahoe requires a HEVC Main10 asset with a 240fps/240000Hz media timeline. The
/// writer is initialized from the first actual HEVC sample format description: a
/// synthetic or missing format hint leaves Tahoe's AVAssetWriter input permanently
/// not-ready. Encoding and muxing are deliberately decoupled so a VideoToolbox
/// callback never blocks waiting for disk I/O.
public struct TahoeLockScreenVideoPreparer: Sendable {
    public static let frameRate: Int32 = 240
    public static let mediaTimeScale: CMTimeScale = 240_000

    public enum Error: Swift.Error, Equatable, Sendable {
        case missingVideoTrack(URL)
        case unsupportedDimensions(URL)
        case readerFailed(URL)
        case writerFailed(URL)
        case writerBackpressure(URL)
        case encoderFailed(URL, Int32)
        case incompatibleOutput(URL)
    }

    public init() {}

    public func prepare(source: URL, destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw Error.missingVideoTrack(source) }
        let naturalSize = try await track.load(.naturalSize)
        let width = Int(abs(naturalSize.width.rounded()))
        let height = Int(abs(naturalSize.height.rounded()))
        guard width > 0, height > 0, max(width, height) <= 3840 else {
            throw Error.unsupportedDimensions(source)
        }
        let sourceDuration = try await asset.load(.duration)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw Error.readerFailed(source) }
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]
        )
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw Error.readerFailed(source) }
        reader.add(readerOutput)

        let writerBox = DeferredCompressedWriter(destination: destination)
        let encoder = try makeEncoder(width: width, height: height, writerBox: writerBox, destination: destination)
        defer { VTCompressionSessionInvalidate(encoder) }
        guard reader.startReading() else { throw Error.readerFailed(source) }

        var previousBuffer: CVPixelBuffer?
        var nextFrame: Int64 = 0
        while let sample = readerOutput.copyNextSampleBuffer() {
            if let error = writerBox.error { throw error }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let boundary = max(nextFrame + 1, frameIndex(for: CMSampleBufferGetPresentationTimeStamp(sample)))
            if let previousBuffer {
                try encode(previousBuffer, through: boundary, nextFrame: &nextFrame, session: encoder, writerBox: writerBox, destination: destination)
            }
            previousBuffer = pixelBuffer
        }
        guard reader.status == .completed else { throw Error.readerFailed(source) }
        if let previousBuffer {
            try encode(
                previousBuffer,
                through: max(nextFrame + 1, frameIndex(for: sourceDuration)),
                nextFrame: &nextFrame,
                session: encoder,
                writerBox: writerBox,
                destination: destination
            )
        }
        let completion = VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
        guard completion == noErr else { throw Error.encoderFailed(destination, completion) }
        try await writerBox.finish()
        guard try await isCompatible(destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw Error.incompatibleOutput(destination)
        }
    }

    public func isCompatible(_ url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first,
              let format = try await track.load(.formatDescriptions).first,
              CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC else { return false }
        let duration = try await track.load(.minFrameDuration)
        guard duration.isNumeric,
              duration.timescale == Self.mediaTimeScale,
              CMTimeCompare(duration, CMTime(value: 1_000, timescale: Self.mediaTimeScale)) == 0 else { return false }
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any]
        return (extensions?["BitsPerComponent"] as? NSNumber)?.intValue == 10
            && extensions?[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
                == kCVImageBufferColorPrimaries_ITU_R_709_2 as String
            && extensions?[kCMFormatDescriptionExtension_TransferFunction as String] as? String
                == kCVImageBufferTransferFunction_ITU_R_709_2 as String
            && extensions?[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
                == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
    }

    private func makeEncoder(width: Int, height: Int, writerBox: DeferredCompressedWriter, destination: URL) throws -> VTCompressionSession {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: compressedFrameCallback,
            refcon: Unmanaged.passUnretained(writerBox).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else { throw Error.encoderFailed(destination, status) }
        let settings: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main10_AutoLevel),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: Self.frameRate)),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: Self.frameRate)),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: recommendedBitRate(width: width, height: height))),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ]
        for (key, value) in settings where VTSessionSetProperty(session, key: key, value: value) != noErr {
            VTCompressionSessionInvalidate(session)
            throw Error.encoderFailed(destination, -1)
        }
        let preparation = VTCompressionSessionPrepareToEncodeFrames(session)
        guard preparation == noErr else {
            VTCompressionSessionInvalidate(session)
            throw Error.encoderFailed(destination, preparation)
        }
        return session
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, through boundary: Int64, nextFrame: inout Int64, session: VTCompressionSession, writerBox: DeferredCompressedWriter, destination: URL) throws {
        while nextFrame < boundary {
            try writerBox.reserveFrame()
            let timestamp = CMTime(value: nextFrame * 1_000, timescale: Self.mediaTimeScale)
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixelBuffer, presentationTimeStamp: timestamp,
                duration: CMTime(value: 1_000, timescale: Self.mediaTimeScale),
                frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil
            )
            guard status == noErr else {
                writerBox.releaseFrame()
                throw Error.encoderFailed(destination, status)
            }
            nextFrame += 1
        }
    }

    private func frameIndex(for time: CMTime) -> Int64 {
        guard time.isNumeric, time.seconds.isFinite else { return 0 }
        return max(0, Int64((time.seconds * Double(Self.frameRate)).rounded()))
    }

    private func recommendedBitRate(width: Int, height: Int) -> Int {
        max(2_000_000, Int(24_000_000 * Double(width * height) / Double(3840 * 2160)))
    }
}

private final class DeferredCompressedWriter: @unchecked Sendable {
    private let destination: URL
    private let queue = DispatchQueue(label: "com.wallume.tahoe-aerial-muxer")
    // HEVC generally emits its first compressed sample after about a second at this timebase.
    // Keep that much work available before backpressuring the producer.
    private let inFlightFrames = DispatchSemaphore(value: 240)
    private let lock = NSLock()
    private var recordedError: TahoeLockScreenVideoPreparer.Error?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var pending: [CMSampleBuffer] = []
    private var encoderFinished = false
    private var finishing = false
    private var completion: CheckedContinuation<Void, Swift.Error>?

    init(destination: URL) { self.destination = destination }

    var error: TahoeLockScreenVideoPreparer.Error? {
        lock.lock(); defer { lock.unlock() }
        return recordedError
    }

    func reserveFrame() throws {
        guard inFlightFrames.wait(timeout: .now() + 60) == .success else {
            record(.writerBackpressure(destination)); throw TahoeLockScreenVideoPreparer.Error.writerBackpressure(destination)
        }
        if let error { inFlightFrames.signal(); throw error }
    }

    func releaseFrame() { inFlightFrames.signal() }

    func accept(_ sample: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.startIfNeeded(using: sample) else { self.releaseFrame(); return }
            self.pending.append(sample)
            self.drain()
        }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Swift.Error>) in
            queue.async { [weak self] in
                guard let self else { continuation.resume(throwing: TahoeLockScreenVideoPreparer.Error.writerFailed(URL(fileURLWithPath: "/dev/null"))); return }
                self.encoderFinished = true
                self.completion = continuation
                self.drain()
                self.finishIfPossible()
            }
        }
    }

    private func startIfNeeded(using sample: CMSampleBuffer) -> Bool {
        if input != nil { return true }
        guard let format = CMSampleBufferGetFormatDescription(sample) else {
            record(.writerFailed(destination)); return false
        }
        do {
            let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
            writer.movieTimeScale = TahoeLockScreenVideoPreparer.mediaTimeScale
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
            input.mediaTimeScale = TahoeLockScreenVideoPreparer.mediaTimeScale
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                record(.writerFailed(destination)); return false
            }
            writer.add(input)
            guard writer.startWriting() else {
                record(.writerFailed(destination)); return false
            }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            self.input = input
            input.requestMediaDataWhenReady(on: queue) { [weak self] in self?.drain() }
            return true
        } catch {
            record(.writerFailed(destination)); return false
        }
    }

    private func drain() {
        guard let input else { return }
        while !pending.isEmpty, input.isReadyForMoreMediaData {
            let sample = pending.removeFirst()
            guard input.append(sample) else {
                record(.writerFailed(destination))
                releaseFrame()
                while !pending.isEmpty { pending.removeFirst(); releaseFrame() }
                finishIfPossible()
                return
            }
            releaseFrame()
        }
        finishIfPossible()
    }

    private func finishIfPossible() {
        guard encoderFinished, pending.isEmpty, !finishing else { return }
        finishing = true
        guard let writer, let input else {
            resolve(error ?? .writerFailed(destination)); return
        }
        input.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard writer.status == .completed else { self.resolve(.writerFailed(self.destination)); return }
                self.resolve(self.error)
            }
        }
    }

    private func record(_ error: TahoeLockScreenVideoPreparer.Error) {
        lock.lock()
        if recordedError == nil { recordedError = error }
        lock.unlock()
    }

    func recordEncoderFailure(_ status: OSStatus) {
        record(.encoderFailed(destination, status))
    }

    private func resolve(_ error: TahoeLockScreenVideoPreparer.Error?) {
        let continuation = completion
        completion = nil
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }
}

private func compressedFrameCallback(outputCallbackRefCon: UnsafeMutableRawPointer?, sourceFrameRefCon: UnsafeMutableRawPointer?, status: OSStatus, infoFlags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
    guard let outputCallbackRefCon else { return }
    let box = Unmanaged<DeferredCompressedWriter>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
    guard status == noErr, let sampleBuffer else {
        box.recordEncoderFailure(status)
        box.releaseFrame()
        return
    }
    box.accept(sampleBuffer)
}
