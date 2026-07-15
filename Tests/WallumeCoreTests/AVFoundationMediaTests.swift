import AVFoundation
import CoreVideo
import Foundation
import XCTest
@testable import WallumeCore

final class AVFoundationMediaTests: XCTestCase {
    func testTranscodedOutputIsReadableHVC1MovWithinLimits() async throws {
        let fixture = try AVFoundationMediaFixture()
        defer { fixture.remove() }
        try fixture.writeVideo(to: fixture.input, width: 64, height: 64, frames: 3)
        let output = fixture.root.appending(path: "output.mov")

        try await fixture.transcoder.transcode(fixture.input, to: output, policy: .singleVariant)
        let metadata = try await fixture.inspector.inspect(output)

        XCTAssertEqual(output.pathExtension, "mov")
        XCTAssertEqual(metadata.codec, "hvc1")
        XCTAssertLessThanOrEqual(max(metadata.pixelWidth, metadata.pixelHeight), 3840)
        XCTAssertLessThanOrEqual(metadata.frameRate, 60)
    }

    func testArtworkGeneratorCreatesReadableJPEGs() async throws {
        let fixture = try AVFoundationMediaFixture()
        defer { fixture.remove() }
        try fixture.writeVideo(to: fixture.input, width: 64, height: 64, frames: 2)
        let thumbnail = fixture.root.appending(path: "thumbnail.jpg")
        let cover = fixture.root.appending(path: "cover.jpg")

        try await fixture.artwork.generateArtwork(for: fixture.input, thumbnail: thumbnail, cover: cover)

        XCTAssertEqual(try Data(contentsOf: thumbnail).prefix(2), Data([0xff, 0xd8]))
        XCTAssertEqual(try Data(contentsOf: cover).prefix(2), Data([0xff, 0xd8]))
    }

    func testInspectorRejectsAssetWithoutVideoTrack() async throws {
        let fixture = try AVFoundationMediaFixture()
        defer { fixture.remove() }
        let unreadable = fixture.root.appending(path: "audio-only.mov")
        try Data("not-video".utf8).write(to: unreadable)

        do {
            _ = try await fixture.inspector.inspect(unreadable)
            XCTFail("Expected inspector to reject an asset without a video track")
        } catch {
            // Expected.
        }
    }

    func testTranscoderCancellationDeletesPartialOutput() async throws {
        let fixture = try AVFoundationMediaFixture()
        defer { fixture.remove() }
        try fixture.writeVideo(to: fixture.input, width: 64, height: 64, frames: 2)
        let output = fixture.root.appending(path: "cancelled.mov")
        let transcoder = fixture.transcoder
        let input = fixture.input

        let task = Task {
            try await transcoder.transcode(input, to: output, policy: .singleVariant)
        }
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }
}

private final class AVFoundationMediaFixture {
    let root: URL
    let input: URL
    let inspector = AVFoundationMediaInspector()
    let transcoder = AVFoundationMediaTranscoder()
    let artwork = AVFoundationArtworkGenerator()

    init() throws {
        let temporary = FileManager.default.temporaryDirectory
        let base = temporary.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private" + temporary.path) : temporary
        root = base.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        input = root.appending(path: "input.mov")
    }

    func writeVideo(to url: URL, width: Int, height: Int, frames: Int) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        )
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
            let buffer = try makePixelBuffer(width: width, height: height, frame: index)
            let time = CMTime(value: CMTimeValue(index), timescale: 30)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: time))
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        if let error = writer.error { throw error }
        XCTAssertEqual(writer.status, .completed)
    }

    private func makePixelBuffer(width: Int, height: Int, frame: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                bytes[offset] = 255
                bytes[offset + 1] = UInt8((x + frame * 17) % 255)
                bytes[offset + 2] = UInt8((y + frame * 29) % 255)
                bytes[offset + 3] = UInt8((x + y + frame * 11) % 255)
            }
        }
        return buffer
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
