import Foundation
import os

enum TEClientError: LocalizedError {
    case timeout(command: UInt8)
    case device(status: UInt8, message: String)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .timeout: "The device didn't answer in time."
        case .device(let status, let message):
            message.isEmpty ? "The device reported: \(TESysEx.Status.describe(status))." : "The device reported: \(message)"
        case .disconnected: "The device was disconnected."
        }
    }
}

/// Sends TE SysEx requests to one device and matches replies by request ID.
actor TEClient {
    let transport: SysExTransport
    let destination: EndpointID
    let source: EndpointID
    let deviceID: UInt8

    private var nextRequestID = UInt16.random(in: 0..<4096)
    private var pending: [UInt16: Pending] = [:]
    private let eventsContinuation: AsyncStream<TESysEx.Message>.Continuation
    /// Device-initiated messages (no request ID), e.g. file change events.
    nonisolated let events: AsyncStream<TESysEx.Message>
    private let log = Logger(subsystem: "EPSampleTool", category: "sysex")

    private struct Pending {
        var continuation: CheckedContinuation<TESysEx.Message, Error>
        var command: UInt8
        var timeout: Duration
        var timer: Task<Void, Never>?
    }

    init(transport: SysExTransport, destination: EndpointID, source: EndpointID, deviceID: UInt8) {
        self.transport = transport
        self.destination = destination
        self.source = source
        self.deviceID = deviceID
        (events, eventsContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    /// Called by the device manager for every message from this device's source.
    func handle(_ bytes: [UInt8]) {
        guard let msg = TESysEx.parse(bytes) else { return }
        guard let id = msg.requestID, !msg.isRequest else {
            eventsContinuation.yield(msg)
            return
        }
        guard var entry = pending[id] else {
            log.debug("ignoring reply for unknown request \(id)")
            return
        }
        let status = msg.status ?? TESysEx.Status.error
        if status == TESysEx.Status.specificSuccessStart {
            // Device is still working on it: keep waiting and restart the timer.
            entry.timer?.cancel()
            entry.timer = makeTimer(id: id, after: entry.timeout)
            pending[id] = entry
            return
        }
        pending[id] = nil
        entry.timer?.cancel()
        if status == TESysEx.Status.ok {
            entry.continuation.resume(returning: msg)
        } else {
            let text = String(decoding: msg.data, as: UTF8.self)
            entry.continuation.resume(throwing: TEClientError.device(status: status, message: text))
        }
    }

    func request(_ command: TESysEx.Command, _ payload: [UInt8] = [], timeout: Duration = .seconds(3)) async throws -> TESysEx.Message {
        try await request(rawCommand: command.rawValue, payload, timeout: timeout)
    }

    func request(rawCommand command: UInt8, _ payload: [UInt8], timeout: Duration) async throws -> TESysEx.Message {
        nextRequestID = (nextRequestID + 1) % 4096
        let id = nextRequestID
        let bytes = TESysEx.frameRequest(deviceID: deviceID, requestID: id, command: command, payload: payload)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = Pending(continuation: cont, command: command, timeout: timeout, timer: makeTimer(id: id, after: timeout))
            Task {
                do {
                    try await transport.send(bytes, to: destination)
                } catch {
                    self.fail(id: id, error: error)
                }
            }
        }
    }

    /// Fails every outstanding request, e.g. when the device is unplugged.
    func cancelAll() {
        for (_, entry) in pending {
            entry.timer?.cancel()
            entry.continuation.resume(throwing: TEClientError.disconnected)
        }
        pending.removeAll()
        eventsContinuation.finish()
    }

    private func makeTimer(id: UInt16, after timeout: Duration) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.timedOut(id: id)
        }
    }

    private func timedOut(id: UInt16) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.continuation.resume(throwing: TEClientError.timeout(command: entry.command))
    }

    private func fail(id: UInt16, error: Error) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timer?.cancel()
        entry.continuation.resume(throwing: error)
    }
}
