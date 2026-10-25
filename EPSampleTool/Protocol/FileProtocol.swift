import Foundation

/// Sub-commands of TE SysEx command 5 (file system), ported from the web app.
enum TEFile {
    enum Op: UInt8 {
        case initialize = 1
        case put = 2
        case get = 3
        case list = 4
        case playback = 5
        case delete = 6
        case metadata = 7
        case info = 11
        case move = 12
    }

    enum Event: UInt8 {
        case metadataUpdated = 3
        case fileAdded = 8
        case fileUpdated = 9
        case fileDeleted = 10
        case fileMoved = 13
    }

    static let initSubscribe: UInt8 = 1
    static let putTypeInit: UInt8 = 0
    static let putTypeData: UInt8 = 1
    static let getTypeInit: UInt8 = 0
    static let getTypeData: UInt8 = 1
    static let metadataSet: UInt8 = 1
    static let metadataGet: UInt8 = 2
    static let metadataSetPaged: UInt8 = 4

    static let typeFile: UInt8 = 1
    static let typeDir: UInt8 = 2
    static let capRead: UInt8 = 4
    static let capWrite: UInt8 = 8
    static let capDelete: UInt8 = 16
    static let capMove: UInt8 = 32
    static let capPlayback: UInt8 = 64

    static let playbackStart: UInt8 = 1
    static let playbackStop: UInt8 = 2

    /// Bytes of file data that fit in one PUT page for a device chunk size.
    static func maxPutPayload(chunkSize: Int) -> Int {
        let a = chunkSize - 6
        let overhead = 8 + 2 + 1
        guard a > overhead else { return 0 }
        let usable = a - 1 - overhead
        return usable - usable / 8
    }
}

struct FSNode: Sendable, Equatable, Identifiable {
    var id: UInt16
    var parentID: UInt16
    var name: String
    var flags: UInt8
    var size: UInt32

    var isFile: Bool { flags & TEFile.typeFile != 0 }
    var isDirectory: Bool { !isFile }
    var isWritable: Bool { flags & TEFile.capWrite != 0 }
    var isDeletable: Bool { flags & TEFile.capDelete != 0 }
    var isPlayable: Bool { flags & TEFile.capPlayback != 0 }
}

// MARK: - Byte helpers

struct ByteWriter {
    private(set) var bytes: [UInt8] = []
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes += [UInt8(v >> 8), UInt8(v & 0xFF)] }
    mutating func u32(_ v: UInt32) {
        bytes += [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    /// Writes each UTF-16 code unit truncated to a byte, like the web app's DataView writer.
    mutating func string(_ s: String, nullTerminated: Bool) {
        for unit in s.utf16 { bytes.append(UInt8(truncatingIfNeeded: unit)) }
        if nullTerminated { bytes.append(0) }
    }
    mutating func raw(_ d: some Sequence<UInt8>) { bytes += d }
}

extension Array where Element == UInt8 {
    func u16(at i: Int) -> UInt16 {
        guard i + 1 < count else { return 0 }
        return UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }
    func u32(at i: Int) -> UInt32 {
        guard i + 3 < count else { return 0 }
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
    /// Reads a NUL-terminated UTF-8 string; returns the string and the index of the terminator.
    func cString(at i: Int) -> (String, Int) {
        var end = i
        while end < count && self[end] != 0 { end += 1 }
        let s = i < end ? String(decoding: self[i..<end], as: UTF8.self) : ""
        return (s, end)
    }
}

// MARK: - Requests

enum FileRequest {
    static func initialize(maxResponseLength: UInt32, flags: UInt8) -> [UInt8] {
        var w = ByteWriter()
        w.u8(TEFile.Op.initialize.rawValue); w.u8(flags); w.u32(maxResponseLength)
        return w.bytes
    }

    static func list(page: UInt16, nodeID: UInt16) -> [UInt8] {
        var w = ByteWriter()
        w.u8(TEFile.Op.list.rawValue); w.u16(page); w.u16(nodeID)
        return w.bytes
    }

    static func info(fileID: UInt16) -> [UInt8] {
        var w = ByteWriter()
        w.u8(TEFile.Op.info.rawValue); w.u16(fileID)
        return w.bytes
    }

    /// Filename is cut to 54 characters and NUL-terminated; metadata JSON follows with no terminator.
    static func putInit(fileID: UInt16, parentID: UInt16, flags: UInt8, fileSize: UInt32, filename: String, metadataJSON: String?) -> [UInt8] {
        var w = ByteWriter()
        w.u8(TEFile.Op.put.rawValue); w.u8(TEFile.putTypeInit); w.u8(flags)
        w.u16(fileID); w.u16(parentID); w.u32(fileSize)
        w.string(String(filename.utf16.prefix(54)) ?? filename, nullTerminated: true)
        if let metadataJSON { w.string(metadataJSON, nullTerminated: false) }
        return w.bytes
    }

    static func putData(page: UInt16, data: ArraySlice<UInt8>) -> [UInt8] {
        var w = ByteWriter()
        w.u8(TEFile.Op.put.rawValue); w.u8(TEFile.putTypeData); w.u16(page); w.raw(data)
        return w.bytes
    }

    static func getInit(fileID: UInt16, offset: UInt32) -> [UInt8] {
        var w = ByteWriter()
        w.u8(TEFile.Op.get.rawValue); w.u8(TEFile.getTypeInit); w.u16(fileID); w.u32(offset)
        return w.bytes
    }

    static func getData(page: UInt16) -> [UInt8] {
        var w = ByteWriter()
        w.u8(TEFile.Op.get.rawValue); w.u8(TEFile.getTypeData); w.u16(page)
        return w.bytes
    }

    static func delete(fileID: UInt16) -> [UInt8] {
        var w = ByteWriter()
        w.u8(TEFile.Op.delete.rawValue); w.u16(fileID)
        return w.bytes
    }

    static func setMetadata(fileID: UInt16, json: String) -> [UInt8] {
        var w = ByteWriter()
        w.u8(TEFile.Op.metadata.rawValue); w.u8(TEFile.metadataSet); w.u16(fileID)
        w.string(json, nullTerminated: true)
        return w.bytes
    }

    static func setMetadataPagedInit(fileID: UInt16, size: UInt32) -> [UInt8] {
        var w = ByteWriter()
        w.u8(TEFile.Op.metadata.rawValue); w.u8(TEFile.metadataSetPaged); w.u8(0); w.u16(fileID); w.u32(size)
        return w.bytes
    }

    static func setMetadataPagedData(page: UInt16, data: ArraySlice<UInt8>) -> [UInt8] {
        var w = ByteWriter()
        w.u8(TEFile.Op.metadata.rawValue); w.u8(TEFile.metadataSetPaged); w.u8(1); w.u16(page); w.raw(data)
        return w.bytes
    }

    static func getMetadata(fileID: UInt16, page: UInt16) -> [UInt8] {
        var w = ByteWriter()
        w.u8(TEFile.Op.metadata.rawValue); w.u8(TEFile.metadataGet); w.u16(fileID); w.u16(page)
        return w.bytes
    }

    static func playback(fileID: UInt16, action: UInt8, offset: UInt32, length: UInt32) -> [UInt8] {
        var w = ByteWriter()
        w.u8(TEFile.Op.playback.rawValue); w.u8(action); w.u16(fileID); w.u32(offset); w.u32(length)
        return w.bytes
    }
}

// MARK: - Responses

enum FileResponse {
    static func chunkSize(fromInit d: [UInt8]) -> Int { Int(d.u32(at: 1)) }

    /// LIST reply: page(2) then repeated [id(2) flags(1) size(4) name\0].
    static func listEntries(_ d: [UInt8], parentID: UInt16) -> (page: UInt16, nodes: [FSNode])? {
        guard d.count > 2 else { return nil }
        let page = d.u16(at: 0)
        var nodes: [FSNode] = []
        var o = 2
        while o + 7 <= d.count {
            let (name, end) = d.cString(at: o + 7)
            nodes.append(FSNode(id: d.u16(at: o), parentID: parentID, name: name, flags: d[o + 2], size: d.u32(at: o + 3)))
            o = end + 1
        }
        return (page, nodes)
    }

    static func info(_ d: [UInt8]) -> FSNode {
        FSNode(id: d.u16(at: 0), parentID: d.u16(at: 2), name: d.cString(at: 9).0, flags: d.count > 4 ? d[4] : 0, size: d.u32(at: 5))
    }

    static func putInitFileID(_ d: [UInt8]) -> UInt16 { d.u16(at: 0) }

    static func getInit(_ d: [UInt8]) -> (fileID: UInt16, flags: UInt8, size: UInt32, name: String) {
        (d.u16(at: 0), d.count > 2 ? d[2] : 0, d.u32(at: 3), d.cString(at: 7).0)
    }
}
