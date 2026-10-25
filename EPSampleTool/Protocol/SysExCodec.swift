import Foundation

/// Teenage Engineering SysEx framing, ported from the EP Sample Tool web app.
///
/// Request:  F0 00 20 76 <dev> 40 <flags|idHi> <idLo> <cmd> <packed payload…> F7
/// Response: F0 00 20 76 <dev> 40 <flags|idHi> <idLo> <cmd> <status> <packed payload…> F7
enum TESysEx {
    static let start: UInt8 = 0xF0
    static let end: UInt8 = 0xF7
    static let manufacturer: [UInt8] = [0x00, 0x20, 0x76]
    static let teMarker: UInt8 = 0x40

    static let bitIsRequest: UInt8 = 0x40
    static let bitRequestIDAvailable: UInt8 = 0x20

    enum Command: UInt8 {
        case greet = 1
        case echo = 2
        case dfu = 3
        case file = 5
        case productSpecific = 127
    }

    enum Status {
        static let ok: UInt8 = 0
        static let error: UInt8 = 1
        static let commandNotFound: UInt8 = 2
        static let badRequest: UInt8 = 3
        static let specificErrorStart: UInt8 = 16
        static let specificSuccessStart: UInt8 = 64

        static func describe(_ s: UInt8) -> String {
            switch s {
            case ok: "ok"
            case error: "error"
            case commandNotFound: "command not found"
            case badRequest: "bad request"
            case specificErrorStart..<specificSuccessStart: "command error \(s)"
            default: s >= specificSuccessStart ? "in progress" : "unknown status \(s)"
            }
        }
    }

    /// Universal "identity request" broadcast.
    static let identityRequest: [UInt8] = [0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7]

    // MARK: 7-bit packing

    /// Size of `count` bytes after packing (one MSB byte per group of 7).
    static func packedSize(_ count: Int) -> Int {
        count > 0 ? count + (count + 6) / 7 : 0
    }

    /// Each group of up to 7 bytes becomes one byte holding their high bits
    /// (bit n = high bit of byte n) followed by the 7 low-bit bytes.
    static func pack(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: packedSize(data.count))
        var msbIndex = 0
        var o = 1
        for (i, byte) in data.enumerated() {
            let bit = i % 7
            out[msbIndex] |= (byte >> 7) << UInt8(bit)
            out[o] = byte & 0x7F
            o += 1
            if bit == 6 && i < data.count - 1 {
                msbIndex += 8
                o += 1
            }
        }
        return out
    }

    static func unpack(_ data: ArraySlice<UInt8>) -> [UInt8] {
        let a = Array(data)
        guard !a.isEmpty else { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(a.count)
        var msbIndex = 0
        var bit = 0
        var c = 1
        var msb = a[0]
        while c < a.count {
            let high: UInt8 = (msb & (1 << UInt8(bit))) != 0 ? 0x80 : 0
            out.append(high | (a[c] & 0x7F))
            bit += 1
            c += 1
            if bit > 6 {
                c += 1
                bit = 0
                msbIndex += 8
                msb = msbIndex < a.count ? a[msbIndex] : 0
            }
        }
        return out
    }

    // MARK: Framing

    static func frameRequest(deviceID: UInt8, requestID: UInt16, command: UInt8, payload: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [start] + manufacturer
        bytes.append(deviceID)
        bytes.append(teMarker)
        bytes.append(bitIsRequest | bitRequestIDAvailable | UInt8((requestID >> 7) & 0x1F))
        bytes.append(UInt8(requestID & 0x7F))
        bytes.append(command)
        bytes += pack(payload)
        bytes.append(end)
        return bytes
    }

    struct Message: Sendable, Equatable {
        var deviceID: UInt8
        var isRequest: Bool
        var requestID: UInt16?
        var command: UInt8
        /// Only present on responses.
        var status: UInt8?
        var data: [UInt8]
    }

    /// Parses a full TE SysEx message (including F0/F7). Returns nil for anything else.
    static func parse(_ a: [UInt8]) -> Message? {
        guard a.count >= 10,
              a[0] == start, Array(a[1...3]) == manufacturer,
              a[5] == teMarker, a.last == end else { return nil }
        let isRequest = a[6] & bitIsRequest != 0
        var requestID: UInt16?
        if a[6] & bitRequestIDAvailable != 0 {
            requestID = UInt16(a[6] & 0x1F) << 7 | UInt16(a[7] & 0x7F)
        }
        var o = 9
        var status: UInt8?
        if !isRequest {
            status = a[o]
            o += 1
        }
        return Message(
            deviceID: a[4],
            isRequest: isRequest,
            requestID: requestID,
            command: a[8],
            status: status,
            data: unpack(a[o..<(a.count - 1)])
        )
    }

    struct Identity: Sendable, Equatable {
        var deviceID: UInt8
        var sku: String
    }

    /// Universal identity reply: F0 7E <id> 06 02 00 20 76 <fam lo/hi> <model lo/hi> … F7 (17 bytes).
    static func parseIdentityReply(_ s: [UInt8]) -> Identity? {
        guard s.count == 17, s[0] == 0xF0, s[1] == 0x7E,
              Array(s[5...7]) == manufacturer else { return nil }
        let family = Int(s[8]) ^ (Int(s[9]) << 7)
        let model = Int(s[10]) ^ (Int(s[11]) << 7)
        return Identity(deviceID: s[2], sku: formatSKU(family, model))
    }

    static func formatSKU(_ a: Int, _ b: Int) -> String {
        String(format: "TE%03dAS%03d", a, b)
    }
}

/// Device info returned by the GREET command as `key:value;key:value`.
struct DeviceMetadata: Sendable, Equatable {
    var chipID = ""
    var mode = ""
    var osVersion = ""
    var product = ""
    var serial = ""
    var sku = ""
    var swVersion = ""
    var baseSKU = ""

    init() {}

    init(greeting: String) {
        for pair in greeting.split(separator: ";") {
            let parts = pair.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let value = parts[1]
            switch parts[0] {
            case "chip_id": chipID = value
            case "mode": mode = value
            case "os_version": osVersion = value
            case "product": product = value
            case "serial": serial = value
            case "sku": sku = value
            case "sw_version": swVersion = value
            case "base_sku": baseSKU = value
            default: break
            }
        }
    }

    var effectiveSKU: String { baseSKU.isEmpty ? sku : baseSKU }
}
