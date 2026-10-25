import Foundation

struct Sound: Identifiable, Sendable, Equatable {
    /// Slot number 1…999; also the file's node ID on the device.
    var slot: Int
    var name: String
    var size: UInt32
    var channels: Int?
    var sampleRate: Int?

    var id: Int { slot }

    var duration: Double? {
        guard let channels, let sampleRate, channels > 0, sampleRate > 0 else { return nil }
        return Double(size) / Double(2 * channels * sampleRate)
    }
}

enum DeviceServiceError: LocalizedError {
    case noSoundsFolder
    case libraryFull

    var errorDescription: String? {
        switch self {
        case .noSoundsFolder: "Couldn't find the sound library on the device."
        case .libraryFull: "All 999 sound slots are in use."
        }
    }
}

/// Sound-library operations on one EP device, ported from the web app's DeviceService.
actor DeviceService {
    static let slotRange = 1...999

    let files: FileClient
    private(set) var soundsFolderID: UInt16?
    /// The `formats` array from the sounds folder metadata, if the device reports it.
    private var formats: [JSONValue]?

    init(files: FileClient) {
        self.files = files
    }

    func prepare() async throws {
        try await files.initialize()
        let root = try await files.list(0)
        guard let sounds = root.first(where: { $0.name == "sounds" && $0.isDirectory }) else {
            throw DeviceServiceError.noSoundsFolder
        }
        soundsFolderID = sounds.id
        formats = (try? await files.metadata(sounds.id))?["formats"]?.arrayValue
    }

    private func soundsID() throws -> UInt16 {
        guard let soundsFolderID else { throw DeviceServiceError.noSoundsFolder }
        return soundsFolderID
    }

    /// Highest sample rate the device accepts for s16 PCM with this channel count,
    /// capped at the source rate (no upsampling), as the web app does.
    func targetSampleRate(sourceRate: Double, channels: Int) -> Int {
        let pcmFormats = (formats ?? [])
            .compactMap(\.objectValue)
            .filter { $0["type"]?.stringValue == "pcm" }
            .flatMap { $0["formats"]?.arrayValue ?? [] }
            .compactMap(\.objectValue)
        let match = pcmFormats.first { f in
            let fmt = f["format"]
            let hasS16 = fmt?.stringValue?.contains("s16") == true
                || fmt?.arrayValue?.contains(.string("s16")) == true
            let ch = f["channels"]?.arrayValue?.compactMap(\.intValue) ?? []
            return hasS16 && ch.contains(channels)
        }
        let maxRate = match?["samplerate.range"]?.arrayValue?.dropFirst().first?.intValue
            ?? match?["samplerate.native"]?.intValue
        guard let maxRate else { return AudioConverter.defaultDeviceSampleRate }
        return min(Int(sourceRate), maxRate)
    }

    func listSounds() async throws -> [Sound] {
        let nodes = try await files.list(try soundsID())
        return nodes
            .filter { $0.isFile && Self.slotRange.contains(Int($0.id)) }
            .map { Sound(slot: Int($0.id), name: $0.name, size: $0.size) }
            .sorted { $0.slot < $1.slot }
    }

    /// Fills in name, channels and sample rate from the sound's metadata.
    func details(for sound: Sound) async throws -> Sound {
        let meta = try await files.metadata(UInt16(sound.slot))
        var s = sound
        if let name = meta["name"]?.stringValue, !name.isEmpty { s.name = name }
        s.channels = meta["channels"]?.intValue
        s.sampleRate = meta["samplerate"]?.intValue
        return s
    }

    func upload(_ url: URL, toSlot slot: Int, progress: @escaping @Sendable (UploadProgress) -> Void) async throws {
        let folder = try soundsID()
        progress(.converting)
        let source = try AudioConverter.inspect(url)
        let rate = targetSampleRate(sourceRate: source.sampleRate, channels: min(max(source.channels, 1), 2))
        let audio = try await Task.detached(priority: .userInitiated) {
            try AudioConverter.convert(url) { _ in rate }
        }.value

        let meta: JSONObject = ["channels": .number(Double(audio.channels)), "samplerate": .number(Double(audio.sampleRate))]
        let name = SampleName.normalize(url.lastPathComponent)
        let nodeID = try await files.put(
            data: audio.pcm, name: name, parentID: folder, fileID: UInt16(slot), metadata: meta
        ) { sent, total in
            progress(.sending(fraction: total > 0 ? Double(sent) / Double(total) : 1))
        }
        try await files.setMetadata(nodeID, meta)
        // The web app re-initializes after every write; keep the same behaviour.
        try await files.initialize()
    }

    func delete(slot: Int) async throws {
        try await files.delete(UInt16(slot))
        try await files.initialize()
    }

    func rename(slot: Int, to name: String) async throws -> String {
        let clean = SampleName.normalize(name + ".x")
        try await files.setMetadata(UInt16(slot), ["name": .string(clean)])
        return clean
    }

    func play(slot: Int) async throws { try await files.startPlayback(UInt16(slot)) }
    func stop(slot: Int) async throws { try await files.stopPlayback(UInt16(slot)) }
}

enum UploadProgress: Sendable, Equatable {
    case queued
    case converting
    case sending(fraction: Double)
    case done
    case failed(String)

    var isActive: Bool {
        switch self {
        case .queued, .converting, .sending: true
        case .done, .failed: false
        }
    }
}

enum EPModel {
    static let supportedSKUs: [String: String] = [
        "TE032AS001": "EP-133 K.O. II",
        "TE032AS005": "EP-1320 Medieval",
        "TE032AS006": "EP-40 Riddim",
    ]

    /// Minimum production firmware the web tool accepts.
    static let minimumFirmware: [String: String] = [
        "TE032AS001": "2.0.5",
        "TE032AS005": "1.0.2",
        "TE032AS006": "1.0.5",
    ]

    static func isFirmwareTooOld(sku: String, version: String) -> Bool {
        guard !version.hasPrefix("0."), let min = minimumFirmware[sku] else { return false }
        return version.compare(min, options: .numeric) == .orderedAscending
    }
}
