import CoreMIDI
import Foundation
import os

/// CoreMIDI-backed transport. USB class-compliant devices such as the EP series
/// appear as a source/destination pair on the same MIDI entity.
final class CoreMIDITransport: SysExTransport, @unchecked Sendable {
    let incoming: AsyncStream<IncomingSysEx>
    let setupChanged: AsyncStream<Void>

    private let incomingContinuation: AsyncStream<IncomingSysEx>.Continuation
    private let setupContinuation: AsyncStream<Void>.Continuation
    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var connectedSources = Set<MIDIEndpointRef>()
    private let lock = OSAllocatedUnfairLock()
    /// Partial UMP SysEx7 messages, keyed by source and group.
    private var assembling: [UInt64: [UInt8]] = [:]
    private let log = Logger(subsystem: "EPSampleTool", category: "midi")

    init() throws {
        (incoming, incomingContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (setupChanged, setupContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))

        var status = MIDIClientCreateWithBlock("EPSampleTool" as CFString, &client) { [weak self] notification in
            guard let self else { return }
            switch notification.pointee.messageID {
            case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved:
                self.connectAllSources()
                self.setupContinuation.yield()
            default:
                break
            }
        }
        guard status == noErr else { throw TransportError.clientCreationFailed(status) }

        status = MIDIInputPortCreateWithProtocol(client, "EPSampleTool In" as CFString, ._1_0, &inputPort) { [weak self] list, srcRef in
            let source = EndpointID(UInt(bitPattern: srcRef))
            self?.receive(list, from: source)
        }
        guard status == noErr else { throw TransportError.clientCreationFailed(status) }
        connectAllSources()
    }

    deinit {
        MIDIPortDispose(inputPort)
        MIDIClientDispose(client)
        incomingContinuation.finish()
        setupContinuation.finish()
    }

    // MARK: Endpoints

    func destinations() -> [MIDIEndpointInfo] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { i in
            let ref = MIDIGetDestination(i)
            guard ref != 0, !Self.isOffline(ref) else { return nil }
            return MIDIEndpointInfo(id: ref, name: Self.name(of: ref))
        }
    }

    func destination(pairedWith source: EndpointID) -> EndpointID? {
        var sourceEntity = MIDIEntityRef()
        MIDIEndpointGetEntity(source, &sourceEntity)
        let all = (0..<MIDIGetNumberOfDestinations()).map { MIDIGetDestination($0) }
        if sourceEntity != 0 {
            for dest in all {
                var entity = MIDIEntityRef()
                MIDIEndpointGetEntity(dest, &entity)
                if entity == sourceEntity { return dest }
            }
        }
        // Fall back to matching names when the driver doesn't expose entities.
        let sourceName = Self.name(of: source)
        return all.first { Self.name(of: $0) == sourceName }
    }

    func isConnected(destination: EndpointID) -> Bool {
        (0..<MIDIGetNumberOfDestinations()).contains { MIDIGetDestination($0) == destination } && !Self.isOffline(destination)
    }

    private func connectAllSources() {
        lock.withLockUnchecked {
            let current = Set((0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) })
            for src in current.subtracting(connectedSources) where src != 0 {
                let refCon = UnsafeMutableRawPointer(bitPattern: UInt(src))
                if MIDIPortConnectSource(inputPort, src, refCon) == noErr {
                    connectedSources.insert(src)
                }
            }
            connectedSources.formIntersection(current)
        }
    }

    private static func name(of ref: MIDIObjectRef) -> String {
        var cf: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(ref, kMIDIPropertyDisplayName, &cf) == noErr, let cf else { return "MIDI device" }
        return cf.takeRetainedValue() as String
    }

    private static func isOffline(_ ref: MIDIObjectRef) -> Bool {
        var offline: Int32 = 0
        MIDIObjectGetIntegerProperty(ref, kMIDIPropertyOffline, &offline)
        return offline != 0
    }

    // MARK: Receive

    /// Reassembles MIDI 1.0 SysEx carried in UMP type-3 (SysEx7) packets.
    private func receive(_ list: UnsafePointer<MIDIEventList>, from source: EndpointID) {
        var completed: [[UInt8]] = []
        lock.withLockUnchecked {
            for packet in list.unsafeSequence() {
                let words = Array(packet.words())
                var i = 0
                while i < words.count {
                    let w0 = words[i]
                    let messageType = Int(w0 >> 28)
                    let size = Self.umpWordCount(messageType)
                    defer { i += size }
                    guard messageType == 0x3, i + 1 < words.count else { continue }
                    let w1 = words[i + 1]
                    let group = UInt64((w0 >> 24) & 0xF)
                    let status = (w0 >> 20) & 0xF
                    let count = min(Int((w0 >> 16) & 0xF), 6)
                    let all: [UInt8] = [
                        UInt8((w0 >> 8) & 0xFF), UInt8(w0 & 0xFF),
                        UInt8(w1 >> 24), UInt8((w1 >> 16) & 0xFF), UInt8((w1 >> 8) & 0xFF), UInt8(w1 & 0xFF),
                    ]
                    let bytes = all.prefix(count)
                    let key = UInt64(source) << 8 | group
                    switch status {
                    case 0x0: // complete in one packet
                        completed.append([TESysEx.start] + bytes + [TESysEx.end])
                    case 0x1: // start
                        assembling[key] = [TESysEx.start] + bytes
                    case 0x2: // continue
                        assembling[key]?.append(contentsOf: bytes)
                    case 0x3: // end
                        if var msg = assembling.removeValue(forKey: key) {
                            msg.append(contentsOf: bytes)
                            msg.append(TESysEx.end)
                            completed.append(msg)
                        }
                    default:
                        break
                    }
                }
            }
        }
        for msg in completed {
            incomingContinuation.yield(IncomingSysEx(source: source, bytes: msg))
        }
    }

    private static func umpWordCount(_ type: Int) -> Int {
        switch type {
        case 0x0, 0x1, 0x2, 0x6, 0x7: 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: 2
        case 0xB, 0xC: 3
        default: 4
        }
    }

    // MARK: Send

    func send(_ bytes: [UInt8], to destination: EndpointID) async throws {
        guard isConnected(destination: destination) else { throw TransportError.destinationGone }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let request = SysExSendRequest(bytes: bytes, destination: destination, continuation: cont)
            request.start()
        }
    }
}

/// Owns the buffer and request struct for one MIDISendSysex call until CoreMIDI finishes with them.
private final class SysExSendRequest {
    private let buffer: UnsafeMutableBufferPointer<UInt8>
    private let request: UnsafeMutablePointer<MIDISysexSendRequest>
    private let continuation: CheckedContinuation<Void, Error>

    init(bytes: [UInt8], destination: MIDIEndpointRef, continuation: CheckedContinuation<Void, Error>) {
        buffer = .allocate(capacity: bytes.count)
        _ = buffer.initialize(from: bytes)
        request = .allocate(capacity: 1)
        self.continuation = continuation
        request.initialize(to: MIDISysexSendRequest(
            destination: destination,
            data: UnsafePointer(buffer.baseAddress!),
            bytesToSend: UInt32(bytes.count),
            complete: false,
            reserved: (0, 0, 0),
            completionProc: { req in
                let box = Unmanaged<SysExSendRequest>.fromOpaque(req.pointee.completionRefCon!)
                box.takeRetainedValue().finish()
            },
            completionRefCon: nil
        ))
    }

    func start() {
        request.pointee.completionRefCon = Unmanaged.passRetained(self).toOpaque()
        let status = MIDISendSysex(request)
        if status != noErr {
            Unmanaged<SysExSendRequest>.fromOpaque(request.pointee.completionRefCon!).release()
            continuation.resume(throwing: TransportError.sendFailed(status))
            cleanup()
        }
    }

    private func finish() {
        let sentAll = request.pointee.bytesToSend == 0
        cleanup()
        if sentAll {
            continuation.resume()
        } else {
            continuation.resume(throwing: TransportError.destinationGone)
        }
    }

    private func cleanup() {
        request.deinitialize(count: 1)
        request.deallocate()
        buffer.deallocate()
    }
}
