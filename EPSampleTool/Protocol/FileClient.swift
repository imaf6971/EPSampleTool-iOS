import Foundation

enum FileClientError: LocalizedError {
    case notInitialized
    case unexpectedPage(got: UInt16, expected: UInt16)
    case badMetadata(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized: "The device's file system isn't ready."
        case .unexpectedPage(let got, let expected): "Out-of-order reply from device (page \(got), expected \(expected))."
        case .badMetadata(let s): "The device sent metadata that couldn't be read: \(s)"
        }
    }
}

/// The device file system over TE SysEx command 5.
///
/// Each public operation holds an exclusive lock for its whole duration, like the web app's
/// "operation" mutex, so a multi-page upload is never interleaved with other requests.
actor FileClient {
    let client: TEClient
    private(set) var chunkSize: Int?
    private let maxResponseLength: UInt32 = 4 * 1024 * 1024

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(client: TEClient) {
        self.client = client
    }

    // MARK: Locking

    private func exclusive<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        defer {
            if waiters.isEmpty {
                busy = false
            } else {
                // Hand the lock straight to the next waiter.
                waiters.removeFirst().resume()
            }
        }
        return try await body()
    }

    private func send(_ payload: [UInt8], timeout: Duration = .seconds(3)) async throws -> [UInt8] {
        try await client.request(.file, payload, timeout: timeout).data
    }

    // MARK: Operations

    /// Must be called before put/metadata calls; also subscribes to file change events.
    func initialize() async throws {
        let size = try await exclusive {
            FileResponse.chunkSize(fromInit: try await send(FileRequest.initialize(maxResponseLength: maxResponseLength, flags: TEFile.initSubscribe)))
        }
        chunkSize = size
    }

    func list(_ nodeID: UInt16) async throws -> [FSNode] {
        try await exclusive {
            var page: UInt16 = 0
            var nodes: [FSNode] = []
            while true {
                let d = try await send(FileRequest.list(page: page, nodeID: nodeID))
                guard let result = FileResponse.listEntries(d, parentID: nodeID) else { break }
                guard result.page == page else { throw FileClientError.unexpectedPage(got: result.page, expected: page) }
                nodes += result.nodes
                page &+= 1
            }
            return nodes
        }
    }

    func info(_ fileID: UInt16) async throws -> FSNode {
        try await exclusive { FileResponse.info(try await send(FileRequest.info(fileID: fileID))) }
    }

    /// Uploads `data` as a file. Returns the node ID the device assigned.
    @discardableResult
    func put(
        data: [UInt8],
        name: String,
        parentID: UInt16,
        fileID: UInt16,
        metadata: JSONObject?,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> UInt16 {
        guard let chunkSize else { throw FileClientError.notInitialized }
        let json = try metadata.map { try JSONCoding.encode($0) }
        return try await exclusive {
            let initReply = try await send(FileRequest.putInit(
                fileID: fileID, parentID: parentID, flags: TEFile.capRead | TEFile.typeFile,
                fileSize: UInt32(data.count), filename: name, metadataJSON: json
            ))
            let assignedID = FileResponse.putInitFileID(initReply)
            progress?(0, data.count)

            let pageSize = TEFile.maxPutPayload(chunkSize: chunkSize)
            var offset = 0
            var page: UInt16 = 0
            while offset < data.count {
                let end = min(offset + pageSize, data.count)
                _ = try await send(FileRequest.putData(page: page, data: data[offset..<end]))
                offset = end
                page &+= 1
                progress?(offset, data.count)
            }
            // An empty page marks the end of the file.
            _ = try await send(FileRequest.putData(page: page, data: []))
            return assignedID
        }
    }

    func download(_ fileID: UInt16) async throws -> (name: String, data: [UInt8]) {
        try await exclusive {
            let head = FileResponse.getInit(try await send(FileRequest.getInit(fileID: fileID, offset: 0)))
            var data: [UInt8] = []
            data.reserveCapacity(Int(head.size))
            var page: UInt16 = 0
            while data.count < Int(head.size) {
                let d = try await send(FileRequest.getData(page: page))
                let got = d.u16(at: 0)
                guard got == page else { throw FileClientError.unexpectedPage(got: got, expected: page) }
                let chunk = d.dropFirst(2)
                if chunk.isEmpty { break }
                data += chunk
                page &+= 1
            }
            return (head.name, data)
        }
    }

    func delete(_ fileID: UInt16) async throws {
        try await exclusive { _ = try await send(FileRequest.delete(fileID: fileID)) }
    }

    func metadata(_ fileID: UInt16) async throws -> JSONObject {
        let text: String = try await exclusive {
            var text = ""
            var page: UInt16 = 0
            while true {
                let d = try await send(FileRequest.getMetadata(fileID: fileID, page: page))
                guard d.count > 2 else { break }
                let got = d.u16(at: 0)
                guard got == page else { throw FileClientError.unexpectedPage(got: got, expected: page) }
                text += d.cString(at: 2).0
                page &+= 1
                if d.last == 0 { break }
            }
            return text
        }
        guard !text.isEmpty else { return [:] }
        guard let obj = JSONCoding.decode(text) else { throw FileClientError.badMetadata(text) }
        return obj
    }

    func setMetadata(_ fileID: UInt16, _ values: JSONObject) async throws {
        guard let chunkSize else { throw FileClientError.notInitialized }
        let json = try JSONCoding.encode(values)
        let overhead = 8
        try await exclusive {
            if json.utf16.count <= chunkSize - overhead {
                _ = try await send(FileRequest.setMetadata(fileID: fileID, json: json))
                return
            }
            let bytes = Array(json.utf8)
            _ = try await send(FileRequest.setMetadataPagedInit(fileID: fileID, size: UInt32(bytes.count)))
            // Same page size rule as uploads, with an 8-byte overhead instead of 6.
            let pageSize = TEFile.maxPutPayload(chunkSize: chunkSize - overhead + 6)
            var offset = 0
            var page: UInt16 = 0
            while offset < bytes.count {
                let end = min(offset + pageSize, bytes.count)
                _ = try await send(FileRequest.setMetadataPagedData(page: page, data: bytes[offset..<end]))
                offset = end
                page &+= 1
            }
            _ = try await send(FileRequest.setMetadataPagedData(page: page, data: []))
        }
    }

    func startPlayback(_ fileID: UInt16) async throws {
        try await exclusive {
            _ = try await send(FileRequest.playback(fileID: fileID, action: TEFile.playbackStart, offset: 0, length: 0))
        }
    }

    func stopPlayback(_ fileID: UInt16) async throws {
        try await exclusive {
            _ = try await send(FileRequest.playback(fileID: fileID, action: TEFile.playbackStop, offset: 0, length: 0))
        }
    }
}
