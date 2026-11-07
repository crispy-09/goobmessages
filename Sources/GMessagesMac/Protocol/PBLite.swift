import Foundation
import SwiftProtobuf

/// "pblite" is Google's JSON-array protobuf encoding: field N lives at array index N-1,
/// bytes are base64, nested messages are nested arrays. This codec converts between the
/// protobuf wire format (handled by SwiftProtobuf) and pblite using the generated schema.
enum PBLiteError: Error, LocalizedError {
    case malformed(String)
    case unknownMessage(String)
    var errorDescription: String? {
        switch self {
        case .malformed(let s): return "Malformed pblite: \(s)"
        case .unknownMessage(let s): return "No pblite schema for \(s)"
        }
    }
}

enum PBLite {
    // MARK: Public API

    static func marshal<M: SwiftProtobuf.Message>(_ message: M) throws -> Data {
        let wire = [UInt8](try message.serializedData())
        let slice = try toSlice(wire: wire, message: M.protoMessageName)
        return try JSONSerialization.data(withJSONObject: slice, options: [])
    }

    static func unmarshal<M: SwiftProtobuf.Message>(_ data: Data, as type: M.Type = M.self) throws -> M {
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let arr = obj as? [Any] else { throw PBLiteError.malformed("expected top-level array") }
        return try unmarshal(slice: arr, as: type)
    }

    static func unmarshal<M: SwiftProtobuf.Message>(slice: [Any], as type: M.Type = M.self) throws -> M {
        let wire = try fromSlice(slice, message: M.protoMessageName)
        return try M(serializedData: Data(wire))
    }

    // MARK: Wire -> pblite

    private struct WireField {
        var number: Int
        var wireType: Int
        var varint: UInt64 = 0
        var bytes: [UInt8] = []
    }

    private static func readVarint(_ b: [UInt8], _ i: inout Int) throws -> UInt64 {
        var result: UInt64 = 0, shift: UInt64 = 0
        while i < b.count {
            let byte = b[i]; i += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { break }
        }
        throw PBLiteError.malformed("bad varint")
    }

    private static func parseWire(_ b: [UInt8]) throws -> [WireField] {
        var i = 0
        var out: [WireField] = []
        while i < b.count {
            let tag = try readVarint(b, &i)
            var f = WireField(number: Int(tag >> 3), wireType: Int(tag & 7))
            switch f.wireType {
            case 0: f.varint = try readVarint(b, &i)
            case 1:
                guard i + 8 <= b.count else { throw PBLiteError.malformed("short fixed64") }
                f.bytes = Array(b[i..<i + 8]); i += 8
            case 2:
                let rawLen = try readVarint(b, &i)
                guard rawLen <= UInt64(b.count - i) else { throw PBLiteError.malformed("short bytes") }   // overflow-safe
                let len = Int(rawLen)
                f.bytes = Array(b[i..<i + len]); i += len
            case 5:
                guard i + 4 <= b.count else { throw PBLiteError.malformed("short fixed32") }
                f.bytes = Array(b[i..<i + 4]); i += 4
            default: throw PBLiteError.malformed("unsupported wire type \(f.wireType)")
            }
            out.append(f)
        }
        return out
    }

    private static func le(_ bytes: [UInt8]) -> UInt64 {
        var v: UInt64 = 0
        for (i, b) in bytes.enumerated() { v |= UInt64(b) << (8 * UInt64(i)) }
        return v
    }

    private static func scalar(_ f: WireField, _ fd: PBField) -> Any? {
        switch fd.kind {
        case .int: return NSNumber(value: Int64(bitPattern: f.varint))
        case .uint: return NSNumber(value: f.varint)
        case .sint: return NSNumber(value: Int64(bitPattern: f.varint >> 1) ^ -Int64(bitPattern: f.varint & 1))
        case .bool: return NSNumber(value: f.varint != 0)
        case .enumeration: return NSNumber(value: Int32(truncatingIfNeeded: f.varint))
        case .float: return NSNumber(value: Double(Float(bitPattern: UInt32(truncatingIfNeeded: le(f.bytes)))))
        case .double: return NSNumber(value: Double(bitPattern: le(f.bytes)))
        case .fixed32: return NSNumber(value: UInt32(truncatingIfNeeded: le(f.bytes)))
        case .fixed64: return NSNumber(value: le(f.bytes))
        default: return nil
        }
    }

    private static let maxDepth = 64

    static func toSlice(wire: [UInt8], message: String, depth: Int = 0) throws -> [Any] {
        guard depth < maxDepth else { throw PBLiteError.malformed("nesting too deep") }
        guard let schema = PBLiteSchema.messages[message] else { throw PBLiteError.unknownMessage(message) }
        let maxN = schema.keys.max() ?? 0
        var out = [Any](repeating: NSNull(), count: maxN)
        for f in try parseWire(wire) {
            guard let fd = schema[f.number] else { continue }
            var values: [Any] = []
            switch fd.kind {
            case .message:
                if fd.binary { values.append(Data(f.bytes).base64EncodedString()) }
                else {
                    guard let name = fd.message else { continue }
                    values.append(try toSlice(wire: f.bytes, message: name, depth: depth + 1))
                }
            case .bytes:
                values.append(Data(f.bytes).base64EncodedString())
            case .string:
                values.append(fd.binary ? Data(f.bytes).base64EncodedString() : String(decoding: f.bytes, as: UTF8.self))
            default:
                if f.wireType == 2 { // packed repeated scalar
                    var j = 0
                    while j < f.bytes.count {
                        var sub = WireField(number: f.number, wireType: 0)
                        if fd.kind == .fixed32 || fd.kind == .float {
                            sub.bytes = Array(f.bytes[j..<min(j + 4, f.bytes.count)]); j += 4
                        } else if fd.kind == .fixed64 || fd.kind == .double {
                            sub.bytes = Array(f.bytes[j..<min(j + 8, f.bytes.count)]); j += 8
                        } else { sub.varint = try readVarint(f.bytes, &j) }
                        if let v = scalar(sub, fd) { values.append(v) }
                    }
                } else if let v = scalar(f, fd) { values.append(v) }
            }
            if fd.repeated {
                var arr = (out[f.number - 1] as? [Any]) ?? []
                arr.append(contentsOf: values)
                out[f.number - 1] = arr
            } else if let last = values.last {
                out[f.number - 1] = last
            }
        }
        return out
    }

    // MARK: pblite -> wire

    private static func putVarint(_ v: UInt64, _ out: inout [UInt8]) {
        var v = v
        while v >= 0x80 { out.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
        out.append(UInt8(v))
    }
    private static func putTag(_ n: Int, _ wt: Int, _ out: inout [UInt8]) { putVarint(UInt64(n << 3 | wt), &out) }
    private static func putLen(_ n: Int, _ bytes: [UInt8], _ out: inout [UInt8]) {
        putTag(n, 2, &out); putVarint(UInt64(bytes.count), &out); out.append(contentsOf: bytes)
    }

    private static func int64(_ v: Any) -> Int64? {
        if let s = v as? String { return Int64(s) }
        return (v as? NSNumber)?.int64Value
    }
    private static func uint64(_ v: Any) -> UInt64? {
        if let s = v as? String { return UInt64(s) }
        return (v as? NSNumber)?.uint64Value
    }

    static func fromSlice(_ input: [Any], message: String, depth: Int = 0) throws -> [UInt8] {
        guard depth < maxDepth else { throw PBLiteError.malformed("nesting too deep") }
        guard let schema = PBLiteSchema.messages[message] else { throw PBLiteError.unknownMessage(message) }
        var data = input
        var extra: [String: Any]?
        if let last = data.last as? [String: Any] { extra = last; data.removeLast() }
        var out: [UInt8] = []

        func appendOne(_ val: Any, _ fd: PBField) throws {
            let n = fd.number
            switch fd.kind {
            case .message:
                if fd.binary {
                    guard let s = val as? String, let d = Data(base64Encoded: s) else { throw PBLiteError.malformed("binary msg \(n)") }
                    putLen(n, [UInt8](d), &out)
                } else {
                    guard let arr = val as? [Any], let name = fd.message else { throw PBLiteError.malformed("msg \(n) in \(message)") }
                    putLen(n, try fromSlice(arr, message: name, depth: depth + 1), &out)
                }
            case .bytes:
                guard let s = val as? String, let d = Data(base64Encoded: s) else { throw PBLiteError.malformed("bytes \(n)") }
                putLen(n, [UInt8](d), &out)
            case .string:
                guard let s = val as? String else { throw PBLiteError.malformed("string \(n)") }
                if fd.binary {
                    guard let d = Data(base64Encoded: s) else { throw PBLiteError.malformed("b64 string \(n)") }
                    putLen(n, [UInt8](d), &out)
                } else { putLen(n, [UInt8](s.utf8), &out) }
            case .int, .enumeration:
                guard let v = int64(val) else { throw PBLiteError.malformed("int \(n)") }
                putTag(n, 0, &out); putVarint(UInt64(bitPattern: v), &out)
            case .uint:
                guard let v = uint64(val) else { throw PBLiteError.malformed("uint \(n)") }
                putTag(n, 0, &out); putVarint(v, &out)
            case .sint:
                guard let v = int64(val) else { throw PBLiteError.malformed("sint \(n)") }
                putTag(n, 0, &out); putVarint(UInt64(bitPattern: (v << 1) ^ (v >> 63)), &out)
            case .bool:
                let b = (val as? NSNumber)?.boolValue ?? false
                putTag(n, 0, &out); putVarint(b ? 1 : 0, &out)
            case .float:
                guard let d = (val as? NSNumber)?.doubleValue else { throw PBLiteError.malformed("float \(n)") }
                putTag(n, 5, &out); var bits = Float(d).bitPattern
                for _ in 0..<4 { out.append(UInt8(bits & 0xff)); bits >>= 8 }
            case .double:
                guard let d = (val as? NSNumber)?.doubleValue else { throw PBLiteError.malformed("double \(n)") }
                putTag(n, 1, &out); var bits = d.bitPattern
                for _ in 0..<8 { out.append(UInt8(bits & 0xff)); bits >>= 8 }
            case .fixed32:
                guard let v = uint64(val) else { throw PBLiteError.malformed("fixed32 \(n)") }
                putTag(n, 5, &out); var b = UInt32(truncatingIfNeeded: v)
                for _ in 0..<4 { out.append(UInt8(b & 0xff)); b >>= 8 }
            case .fixed64:
                guard let v = uint64(val) else { throw PBLiteError.malformed("fixed64 \(n)") }
                putTag(n, 1, &out); var b = v
                for _ in 0..<8 { out.append(UInt8(b & 0xff)); b >>= 8 }
            }
        }

        for number in schema.keys.sorted() {
            let fd = schema[number]!
            let index = number - 1
            var val: Any? = extra?[String(number)]
            if val == nil || val is NSNull { val = index < data.count ? data[index] : nil }
            guard let v = val, !(v is NSNull) else { continue }
            if fd.repeated {
                guard let list = v as? [Any] else { throw PBLiteError.malformed("expected list at \(number) in \(message)") }
                for el in list where !(el is NSNull) { try appendOne(el, fd) }
            } else {
                try appendOne(v, fd)
            }
        }
        return out
    }
}
