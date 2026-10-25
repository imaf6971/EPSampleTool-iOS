import XCTest
@testable import EPSampleTool

/// Checks the Swift port against vectors produced by the original web app's JavaScript
/// (see tools/vectors.mjs).
final class ProtocolVectorTests: XCTestCase {
    struct Vectors: Decodable {
        struct Pack: Decodable { let data: [UInt8]; let packed: [UInt8] }
        struct Frame: Decodable { let deviceId: UInt8; let requestId: UInt16; let cmd: UInt8; let payload: [UInt8]; let bytes: [UInt8] }
        struct MaxPayload: Decodable { let chunkSize: Int; let value: Int }
        struct Name: Decodable { let input: String; let output: String }
        struct Requests: Decodable {
            let putInit, putInitNoMeta, setMeta, getMeta, fileInit, playStart, playStop: [UInt8]
        }
        let pack: [Pack]
        let frames: [Frame]
        let maxPayload: [MaxPayload]
        let names: [Name]
        let requests: Requests
    }

    var v: Vectors!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "vectors", withExtension: "json"))
        v = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func testPackAndUnpackMatchJavaScript() {
        for c in v.pack {
            XCTAssertEqual(TESysEx.pack(c.data), c.packed, "pack n=\(c.data.count)")
            XCTAssertEqual(TESysEx.unpack(c.packed[...]), c.data, "unpack n=\(c.data.count)")
        }
    }

    func testRequestFramingMatchesJavaScript() {
        for f in v.frames {
            XCTAssertEqual(TESysEx.frameRequest(deviceID: f.deviceId, requestID: f.requestId, command: f.cmd, payload: f.payload), f.bytes)
            let parsed = TESysEx.parse(f.bytes)
            XCTAssertEqual(parsed?.isRequest, true)
            XCTAssertEqual(parsed?.requestID, f.requestId)
            XCTAssertEqual(parsed?.command, f.cmd)
            XCTAssertEqual(parsed?.data, f.payload)
        }
    }

    func testMaxPayloadMatchesJavaScript() {
        for m in v.maxPayload {
            XCTAssertEqual(TEFile.maxPutPayload(chunkSize: m.chunkSize), m.value, "chunk \(m.chunkSize)")
        }
    }

    func testNameNormalizationMatchesJavaScript() {
        for n in v.names {
            XCTAssertEqual(SampleName.normalize(n.input), n.output, n.input)
        }
    }

    func testFileRequestsMatchJavaScript() {
        let r = v.requests
        XCTAssertEqual(FileRequest.putInit(fileID: 12, parentID: 1000, flags: 5, fileSize: 93750, filename: "kick 01",
                                           metadataJSON: #"{"channels":1,"samplerate":46875}"#), r.putInit)
        XCTAssertEqual(FileRequest.putInit(fileID: 999, parentID: 2, flags: 5, fileSize: 1, filename: String(repeating: "x", count: 60),
                                           metadataJSON: nil), r.putInitNoMeta)
        XCTAssertEqual(FileRequest.setMetadata(fileID: 12, json: #"{"name":"kick"}"#), r.setMeta)
        XCTAssertEqual(FileRequest.getMetadata(fileID: 12, page: 3), r.getMeta)
        XCTAssertEqual(FileRequest.initialize(maxResponseLength: 4 * 1024 * 1024, flags: 1), r.fileInit)
        XCTAssertEqual(FileRequest.playback(fileID: 12, action: 1, offset: 0, length: 0), r.playStart)
        XCTAssertEqual(FileRequest.playback(fileID: 12, action: 2, offset: 0, length: 0), r.playStop)
    }

    func testIdentityReply() {
        let reply: [UInt8] = [0xF0, 0x7E, 0x05, 0x06, 0x02, 0x00, 0x20, 0x76, 32, 0, 5, 0, 1, 2, 3, 4, 0xF7]
        XCTAssertEqual(TESysEx.parseIdentityReply(reply), TESysEx.Identity(deviceID: 5, sku: "TE032AS005"))
        XCTAssertNil(TESysEx.parseIdentityReply(Array(reply.dropLast())))
    }

    func testGreetingParsing() {
        let m = DeviceMetadata(greeting: "chip_id:abc;mode:normal;os_version:2.0.5;serial:XYZ;sku:TE032AS001;base_sku:TE032AS001;junk")
        XCTAssertEqual(m.osVersion, "2.0.5")
        XCTAssertEqual(m.serial, "XYZ")
        XCTAssertEqual(m.effectiveSKU, "TE032AS001")
    }

    func testFirmwareCheck() {
        XCTAssertTrue(EPModel.isFirmwareTooOld(sku: "TE032AS001", version: "1.9.0"))
        XCTAssertFalse(EPModel.isFirmwareTooOld(sku: "TE032AS001", version: "2.0.5"))
        XCTAssertFalse(EPModel.isFirmwareTooOld(sku: "TE032AS001", version: "2.10.0"))
        XCTAssertFalse(EPModel.isFirmwareTooOld(sku: "TE032AS001", version: "0.100.1"))
    }
}
