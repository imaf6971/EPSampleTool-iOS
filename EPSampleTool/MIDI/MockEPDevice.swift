import Foundation

/// An in-memory EP-133 that speaks the same SysEx protocol as the hardware.
/// Used in the Simulator (which can't see USB MIDI) and in tests.
final class MockEPDevice: SysExTransport, @unchecked Sendable {
    static let sourceID: EndpointID = 1
    static let destinationID: EndpointID = 2
    static let soundsFolderID: UInt16 = 1000
    static let projectsFolderID: UInt16 = 2000

    let incoming: AsyncStream<IncomingSysEx>
    let setupChanged: AsyncStream<Void>
    private let incomingContinuation: AsyncStream<IncomingSysEx>.Continuation
    private let setupContinuation: AsyncStream<Void>.Continuation

    struct File {
        var name: String
        var data: [UInt8]
        var meta: JSONObject
    }

    private let lock = NSLock()
    private(set) var files: [UInt16: File] = [:]
    private var pendingPut: (id: UInt16, name: String, size: Int, meta: JSONObject, data: [UInt8])?
    private var pendingMeta: (id: UInt16, data: [UInt8])?
    private(set) var playbackLog: [(UInt16, UInt8)] = []
    private var plugged = true
    let chunkSize: Int
    let latency: Duration

    init(chunkSize: Int = 2048, latency: Duration = .milliseconds(3), preloadSounds: Bool = true) {
        self.chunkSize = chunkSize
        self.latency = latency
        (incoming, incomingContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (setupChanged, setupContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        if preloadSounds {
            let names = ["kick", "snare", "closed hat", "open hat", "clap", "rim", "tom low", "tom hi",
                         "crash", "ride", "shaker", "cowbell", "bass c1", "chord stab", "vox chop", "fx riser"]
            for (i, name) in names.enumerated() {
                let seconds = 0.2 + Double(i % 5) * 0.3
                let channels = i % 3 == 0 ? 2 : 1
                let size = Int(seconds * 46875) * 2 * channels
                files[UInt16(i + 1)] = File(name: name, data: [UInt8](repeating: 0, count: size),
                                            meta: ["name": .string(name), "channels": .number(Double(channels)), "samplerate": 46875])
            }
        }
    }

    func file(_ id: UInt16) -> File? { lock.withLock { files[id] } }

    /// Simulates unplugging the cable.
    func unplug() {
        lock.withLock { plugged = false }
        setupContinuation.yield()
    }

    // MARK: SysExTransport

    func destinations() -> [MIDIEndpointInfo] {
        lock.withLock { plugged } ? [MIDIEndpointInfo(id: Self.destinationID, name: "EP-133 (simulated)")] : []
    }

    func destination(pairedWith source: EndpointID) -> EndpointID? {
        source == Self.sourceID ? Self.destinationID : nil
    }

    func isConnected(destination: EndpointID) -> Bool {
        destination == Self.destinationID && lock.withLock { plugged }
    }

    func send(_ bytes: [UInt8], to destination: EndpointID) async throws {
        guard isConnected(destination: destination) else { throw TransportError.destinationGone }
        try? await Task.sleep(for: latency)
        for reply in handle(bytes) {
            incomingContinuation.yield(IncomingSysEx(source: Self.sourceID, bytes: reply))
        }
    }

    // MARK: Device logic

    private func handle(_ bytes: [UInt8]) -> [[UInt8]] {
        if bytes == TESysEx.identityRequest {
            // F0 7E <id> 06 02 <00 20 76> <family 32> <model 1> <version x4> F7
            return [[0xF0, 0x7E, 0x00, 0x06, 0x02, 0x00, 0x20, 0x76, 32, 0, 1, 0, 2, 0, 5, 0, 0xF7]]
        }
        guard let msg = TESysEx.parse(bytes), msg.isRequest, let id = msg.requestID else { return [] }
        return lock.withLock {
            var events: [[UInt8]] = []
            let (status, data) = respond(to: msg, events: &events)
            return [Self.frameResponse(deviceID: msg.deviceID, requestID: id, command: msg.command, status: status, data: data)] + events
        }
    }

    private func respond(to msg: TESysEx.Message, events: inout [[UInt8]]) -> (UInt8, [UInt8]) {
        let ok = TESysEx.Status.ok
        switch msg.command {
        case TESysEx.Command.greet.rawValue:
            let s = "chip_id:SIM;mode:normal;os_version:2.0.5;product:EP-133;serial:SIM0001;sku:TE032AS001;sw_version:2.0.5;base_sku:TE032AS001"
            return (ok, Array(s.utf8))
        case TESysEx.Command.file.rawValue:
            return file(msg.data, events: &events)
        default:
            return (TESysEx.Status.commandNotFound, [])
        }
    }

    private func file(_ d: [UInt8], events: inout [[UInt8]]) -> (UInt8, [UInt8]) {
        let ok = TESysEx.Status.ok
        guard let op = d.first.flatMap(TEFile.Op.init(rawValue:)) else { return (TESysEx.Status.badRequest, []) }
        var w = ByteWriter()
        switch op {
        case .initialize:
            w.u8(0); w.u32(UInt32(chunkSize))
            return (ok, w.bytes)

        case .list:
            let page = Int(d.u16(at: 1)), node = d.u16(at: 3)
            let entries = children(of: node)
            let perPage = 5
            w.u16(UInt16(page))
            for n in entries.dropFirst(page * perPage).prefix(perPage) {
                w.u16(n.id); w.u8(n.flags); w.u32(n.size); w.string(n.name, nullTerminated: true)
            }
            return (ok, w.bytes)

        case .info:
            let id = d.u16(at: 1)
            guard let n = node(id) else { return (TESysEx.Status.specificErrorStart, Array("no such file".utf8)) }
            w.u16(n.id); w.u16(n.parentID); w.u8(n.flags); w.u32(n.size); w.string(n.name, nullTerminated: true)
            return (ok, w.bytes)

        case .put:
            if d[1] == TEFile.putTypeInit {
                let id = d.u16(at: 3), size = Int(d.u32(at: 7))
                let (name, end) = d.cString(at: 11)
                let metaText = String(decoding: d[(end + 1)...], as: UTF8.self)
                let meta = JSONCoding.decode(metaText) ?? [:]
                guard (1...999).contains(Int(id)) else { return (TESysEx.Status.badRequest, []) }
                pendingPut = (id, name, size, meta, [])
                w.u16(id)
                return (ok, w.bytes)
            }
            guard var put = pendingPut else { return (TESysEx.Status.badRequest, []) }
            let chunk = d.dropFirst(4)
            if chunk.isEmpty {
                let existed = files[put.id] != nil
                files[put.id] = File(name: put.name, data: put.data, meta: put.meta)
                pendingPut = nil
                events.append(Self.event(existed ? .fileUpdated : .fileAdded, id: put.id))
            } else {
                put.data += chunk
                pendingPut = put
            }
            return (ok, [])

        case .delete:
            let id = d.u16(at: 1)
            guard files.removeValue(forKey: id) != nil else { return (TESysEx.Status.specificErrorStart, Array("no such file".utf8)) }
            events.append(Self.event(.fileDeleted, id: id))
            return (ok, [])

        case .metadata:
            switch d[1] {
            case TEFile.metadataGet:
                let id = d.u16(at: 2), page = d.u16(at: 4)
                w.u16(page)
                if page == 0 { w.string((try? JSONCoding.encode(meta(id))) ?? "{}", nullTerminated: true) }
                return (ok, w.bytes)
            case TEFile.metadataSet:
                let id = d.u16(at: 2)
                if let patch = JSONCoding.decode(d.cString(at: 4).0) { mergeMeta(id, patch) }
                return (ok, [])
            case TEFile.metadataSetPaged:
                if d[2] == 0 {
                    pendingMeta = (d.u16(at: 3), [])
                } else if let pm = pendingMeta {
                    let chunk = d.dropFirst(5)
                    if chunk.isEmpty {
                        if let patch = JSONCoding.decode(String(decoding: pm.data, as: UTF8.self)) { mergeMeta(pm.id, patch) }
                        pendingMeta = nil
                    } else {
                        pendingMeta = (pm.id, pm.data + chunk)
                    }
                }
                return (ok, [])
            default:
                return (TESysEx.Status.badRequest, [])
            }

        case .playback:
            playbackLog.append((d.u16(at: 2), d[1]))
            return (ok, [])

        case .get, .move:
            return (TESysEx.Status.commandNotFound, [])
        }
    }

    private func children(of node: UInt16) -> [FSNode] {
        switch node {
        case 0:
            return [
                FSNode(id: Self.soundsFolderID, parentID: 0, name: "sounds", flags: TEFile.typeDir | TEFile.capRead | TEFile.capWrite, size: 0),
                FSNode(id: Self.projectsFolderID, parentID: 0, name: "projects", flags: TEFile.typeDir | TEFile.capRead, size: 0),
            ]
        case Self.soundsFolderID:
            return files.keys.sorted().compactMap { self.node($0) }
        default:
            return []
        }
    }

    private func node(_ id: UInt16) -> FSNode? {
        if let f = files[id] {
            let flags = TEFile.typeFile | TEFile.capRead | TEFile.capWrite | TEFile.capDelete | TEFile.capMove | TEFile.capPlayback
            return FSNode(id: id, parentID: Self.soundsFolderID, name: f.name, flags: flags, size: UInt32(f.data.count))
        }
        return children(of: 0).first { $0.id == id }
    }

    private func meta(_ id: UInt16) -> JSONObject {
        if id == Self.soundsFolderID {
            return ["formats": .array([.object([
                "type": "pcm",
                "formats": .array([.object([
                    "format": .array(["s16"]),
                    "channels": .array([1, 2]),
                    "samplerate.native": 46875,
                    "samplerate.range": .array([3000, 46875]),
                ])]),
            ])])]
        }
        return files[id]?.meta ?? [:]
    }

    private func mergeMeta(_ id: UInt16, _ patch: JSONObject) {
        guard var f = files[id] else { return }
        f.meta.merge(patch) { _, new in new }
        files[id] = f
    }

    // MARK: Framing

    static func frameResponse(deviceID: UInt8, requestID: UInt16?, command: UInt8, status: UInt8, data: [UInt8]) -> [UInt8] {
        var b: [UInt8] = [TESysEx.start] + TESysEx.manufacturer + [deviceID, TESysEx.teMarker]
        if let requestID {
            b += [TESysEx.bitRequestIDAvailable | UInt8((requestID >> 7) & 0x1F), UInt8(requestID & 0x7F)]
        } else {
            b += [0, 0]
        }
        b += [command, status]
        b += TESysEx.pack(data)
        b.append(TESysEx.end)
        return b
    }

    private static func event(_ kind: TEFile.Event, id: UInt16) -> [UInt8] {
        var w = ByteWriter()
        w.u8(kind.rawValue); w.u16(id)
        return frameResponse(deviceID: 0, requestID: nil, command: TESysEx.Command.file.rawValue, status: TESysEx.Status.ok, data: w.bytes)
    }
}
