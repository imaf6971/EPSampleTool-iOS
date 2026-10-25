import Foundation

typealias EndpointID = UInt32

struct MIDIEndpointInfo: Sendable, Hashable {
    var id: EndpointID
    var name: String
}

struct IncomingSysEx: Sendable {
    var source: EndpointID
    var bytes: [UInt8]
}

/// Moves complete SysEx messages (F0…F7) to and from MIDI endpoints.
protocol SysExTransport: AnyObject, Sendable {
    /// Every complete SysEx message received from any source, in order.
    var incoming: AsyncStream<IncomingSysEx> { get }
    /// Fires when MIDI devices are added or removed.
    var setupChanged: AsyncStream<Void> { get }

    func destinations() -> [MIDIEndpointInfo]
    /// The destination on the same physical device as `source`, if any.
    func destination(pairedWith source: EndpointID) -> EndpointID?
    func isConnected(destination: EndpointID) -> Bool
    func send(_ bytes: [UInt8], to destination: EndpointID) async throws
}

enum TransportError: LocalizedError {
    case clientCreationFailed(Int32)
    case sendFailed(Int32)
    case destinationGone

    var errorDescription: String? {
        switch self {
        case .clientCreationFailed(let s): "Couldn't start MIDI (error \(s))."
        case .sendFailed(let s): "Couldn't send to the device (error \(s))."
        case .destinationGone: "The device was disconnected."
        }
    }
}
