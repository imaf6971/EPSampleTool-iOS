import Foundation

/// Minimal Sendable JSON value for device metadata.
enum JSONValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n):
            // Keep integers integral so the device sees `46875`, not `46875.0`.
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    var intValue: Int? { if case .number(let n) = self { Int(n) } else { nil } }
    var doubleValue: Double? { if case .number(let n) = self { n } else { nil } }
    var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
}

typealias JSONObject = [String: JSONValue]

extension JSONValue: ExpressibleByIntegerLiteral, ExpressibleByStringLiteral {
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(stringLiteral value: String) { self = .string(value) }
}

enum JSONCoding {
    static func encode(_ obj: JSONObject) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try enc.encode(obj), as: UTF8.self)
    }

    static func decode(_ text: String) -> JSONObject? {
        try? JSONDecoder().decode(JSONObject.self, from: Data(text.utf8))
    }
}
