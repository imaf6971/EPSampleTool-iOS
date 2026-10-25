@preconcurrency import AVFoundation
import Foundation

enum AudioConversionError: LocalizedError {
    case unreadable
    case tooLong(seconds: Double)
    case invalidSampleRate(Double)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: "This file isn't an audio format iOS can read."
        case .tooLong(let s): String(format: "Sample is %.1f s long; the device takes up to 40 s.", s)
        case .invalidSampleRate(let r): "Unsupported sample rate (\(Int(r)) Hz)."
        case .conversionFailed(let s): "Couldn't convert the audio: \(s)"
        }
    }
}

struct ConvertedAudio: Sendable {
    /// Interleaved signed 16-bit little-endian PCM, no header.
    var pcm: [UInt8]
    var channels: Int
    var sampleRate: Int
    var duration: Double
}

/// Converts any audio file iOS can decode into the raw PCM the EP devices store.
enum AudioConverter {
    static let maxDuration: Double = 40
    /// Used when the device doesn't report its formats.
    static let defaultDeviceSampleRate = 46875

    struct SourceInfo: Sendable {
        var sampleRate: Double
        var channels: Int
        var duration: Double
    }

    static func inspect(_ url: URL) throws -> SourceInfo {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw AudioConversionError.unreadable }
        let fmt = file.fileFormat
        return SourceInfo(
            sampleRate: fmt.sampleRate,
            channels: Int(fmt.channelCount),
            duration: Double(file.length) / fmt.sampleRate
        )
    }

    /// - Parameter targetRate: closure picking the output rate from the source's rate and channel count.
    static func convert(_ url: URL, targetRate: (SourceInfo) -> Int) throws -> ConvertedAudio {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw AudioConversionError.unreadable }
        let src = file.processingFormat
        let info = SourceInfo(sampleRate: src.sampleRate, channels: Int(src.channelCount), duration: Double(file.length) / src.sampleRate)

        guard info.sampleRate >= 3000, info.sampleRate <= 768_000 else { throw AudioConversionError.invalidSampleRate(info.sampleRate) }
        guard info.duration <= maxDuration else { throw AudioConversionError.tooLong(seconds: info.duration) }

        let outChannels = AVAudioChannelCount(min(max(info.channels, 1), 2))
        let outRate = Double(targetRate(SourceInfo(sampleRate: info.sampleRate, channels: Int(outChannels), duration: info.duration)))
        guard let dst = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: outRate, channels: outChannels, interleaved: true),
              let converter = AVAudioConverter(from: src, to: dst) else {
            throw AudioConversionError.conversionFailed("unsupported format")
        }
        converter.downmix = info.channels > 2
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering

        let readFrames: AVAudioFrameCount = 8192
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: readFrames) else {
            throw AudioConversionError.conversionFailed("out of memory")
        }
        let outCapacity = AVAudioFrameCount(Double(readFrames) * outRate / info.sampleRate) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: outCapacity) else {
            throw AudioConversionError.conversionFailed("out of memory")
        }

        var pcm: [UInt8] = []
        pcm.reserveCapacity(Int(info.duration * outRate) * Int(outChannels) * 2 + 4096)
        var reachedEnd = false
        var readError: Error?

        while true {
            outBuf.frameLength = 0
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
                // Reading past the end throws (-39) rather than returning 0 frames.
                let remaining = file.length - file.framePosition
                if reachedEnd || remaining <= 0 {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuf, frameCount: min(readFrames, AVAudioFrameCount(remaining)))
                } catch {
                    readError = error
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuf
            }
            if let convError { throw AudioConversionError.conversionFailed(convError.localizedDescription) }
            if let readError { throw AudioConversionError.conversionFailed(readError.localizedDescription) }

            let frames = Int(outBuf.frameLength)
            if frames > 0, let ptr = outBuf.int16ChannelData?[0] {
                let byteCount = frames * Int(outChannels) * 2
                ptr.withMemoryRebound(to: UInt8.self, capacity: byteCount) { bytes in
                    pcm.append(contentsOf: UnsafeBufferPointer(start: bytes, count: byteCount))
                }
            }
            if status == .endOfStream || status == .error { break }
            if status == .inputRanDry && reachedEnd { break }
        }

        return ConvertedAudio(pcm: pcm, channels: Int(outChannels), sampleRate: Int(outRate), duration: info.duration)
    }
}

/// Port of the web app's `normalizeFileName`: ASCII, lowercase, no extension, max 16 chars.
enum SampleName {
    static func normalize(_ input: String, stripSlotPrefix: Bool = false) -> String {
        var a = input
        if stripSlotPrefix, let r = a.range(of: #"^\d{3}\s"#, options: .regularExpression) {
            a.removeSubrange(r)
        }
        let parts = a.components(separatedBy: ".")
        let withoutExt = parts.dropLast().joined(separator: ".")
        if !withoutExt.isEmpty { a = withoutExt }
        a = a.replacingOccurrences(of: "/", with: "")
        a = a.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip diacritics after canonical decomposition.
        a = String(String.UnicodeScalarView(a.decomposedStringWithCanonicalMapping.unicodeScalars.filter {
            !$0.properties.isDiacritic
        }))
        a = String(a.utf16.map { (0x20...0x7F).contains($0) ? Character(UnicodeScalar(UInt8($0))) : "?" })
        a = a.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
        if a.count > 16 {
            a = String(a.prefix(7)) + "." + String(a.suffix(8))
        }
        return a.lowercased()
    }
}
