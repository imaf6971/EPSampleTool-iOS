import AVFoundation
import XCTest
@testable import EPSampleTool

/// End-to-end tests against the simulated device: framing, request IDs, paging and uploads.
final class DeviceFlowTests: XCTestCase {
    private func connect(_ device: MockEPDevice) async throws -> (DeviceService, Task<Void, Never>) {
        let client = TEClient(transport: device, destination: MockEPDevice.destinationID, source: MockEPDevice.sourceID, deviceID: 0)
        let pump = Task {
            for await msg in device.incoming { await client.handle(msg.bytes) }
        }
        let greet = try await client.request(.greet)
        XCTAssertEqual(DeviceMetadata(greeting: String(decoding: greet.data, as: UTF8.self)).sku, "TE032AS001")
        let service = DeviceService(files: FileClient(client: client))
        try await service.prepare()
        return (service, pump)
    }

    func testListsPreloadedSoundsAcrossPages() async throws {
        let device = MockEPDevice()
        let (service, pump) = try await connect(device)
        defer { pump.cancel() }
        let sounds = try await service.listSounds()
        XCTAssertEqual(sounds.count, 16) // mock pages 5 entries at a time, so this crosses 4 pages
        XCTAssertEqual(sounds.first?.name, "kick")
        let detailed = try await service.details(for: sounds[0])
        XCTAssertEqual(detailed.channels, 2)
        XCTAssertEqual(detailed.sampleRate, 46875)
    }

    func testTargetSampleRateFollowsDeviceFormats() async throws {
        let (service, pump) = try await connect(MockEPDevice())
        defer { pump.cancel() }
        let a = await service.targetSampleRate(sourceRate: 96000, channels: 2)
        let b = await service.targetSampleRate(sourceRate: 44100, channels: 1)
        XCTAssertEqual(a, 46875)
        XCTAssertEqual(b, 44100)
    }

    func testUploadConvertsAndStoresPCMWithMetadata() async throws {
        // Small chunk size forces many pages.
        let device = MockEPDevice(chunkSize: 256, latency: .zero, preloadSounds: false)
        let (service, pump) = try await connect(device)
        defer { pump.cancel() }

        let url = try makeSine(seconds: 0.5, rate: 48000, channels: 2, name: "Test Tone 01.wav")
        let progress = ProgressRecorder()
        try await service.upload(url, toSlot: 42) { progress.append($0) }

        let file = try XCTUnwrap(device.file(42))
        XCTAssertEqual(file.name, "test tone 01")
        XCTAssertEqual(file.meta["channels"]?.intValue, 2)
        XCTAssertEqual(file.meta["samplerate"]?.intValue, 46875)
        // 0.5 s at 46875 Hz, stereo, 16-bit; allow a few frames of resampler latency.
        let expected = Int(0.5 * 46875) * 2 * 2
        XCTAssertLessThan(abs(file.data.count - expected), 2 * 2 * 64, "got \(file.data.count) bytes, expected ~\(expected)")
        XCTAssertTrue(file.data.contains { $0 != 0 }, "PCM should not be silent")
        XCTAssertEqual(progress.values.first, .converting)
        XCTAssertEqual(progress.values.last, .sending(fraction: 1))

        let sounds = try await service.listSounds()
        XCTAssertEqual(sounds.map(\.slot), [42])
    }

    func testRenameDeleteAndPlayback() async throws {
        let device = MockEPDevice()
        let (service, pump) = try await connect(device)
        defer { pump.cancel() }

        let clean = try await service.rename(slot: 2, to: "Snäre Böx")
        XCTAssertEqual(clean, "snare box")
        XCTAssertEqual(device.file(2)?.meta["name"]?.stringValue, "snare box")

        try await service.play(slot: 3)
        try await service.stop(slot: 3)
        XCTAssertEqual(device.playbackLog.map(\.0), [3, 3])
        XCTAssertEqual(device.playbackLog.map(\.1), [TEFile.playbackStart, TEFile.playbackStop])

        try await service.delete(slot: 1)
        XCTAssertNil(device.file(1))
        do {
            try await service.delete(slot: 1)
            XCTFail("deleting a missing file should fail")
        } catch TEClientError.device {
            // expected
        }
    }

    func testRejectsTooLongSamples() async throws {
        let (service, pump) = try await connect(MockEPDevice(latency: .zero, preloadSounds: false))
        defer { pump.cancel() }
        let url = try makeSine(seconds: 41, rate: 8000, channels: 1, name: "long.wav")
        do {
            try await service.upload(url, toSlot: 1) { _ in }
            XCTFail("expected tooLong")
        } catch AudioConversionError.tooLong {
            // expected
        }
    }

    // MARK: Helpers

    private func makeSine(seconds: Double, rate: Double, channels: AVAudioChannelCount, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for ch in 0..<Int(channels) {
            let p = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) { p[i] = Float(sin(2 * .pi * 440 * Double(i) / rate) * 0.5) }
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ])
        try file.write(from: buffer)
        return url
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [UploadProgress] = []
    func append(_ p: UploadProgress) { lock.withLock { _values.append(p) } }
    var values: [UploadProgress] { lock.withLock { _values } }
}
