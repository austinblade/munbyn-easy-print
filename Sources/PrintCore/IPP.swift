import Foundation

// RFC 8010 binary encoding — just enough IPP/2.0 for an IPP Everywhere printer.

public enum IPPTag {
    // Delimiters
    public static let operationAttributes: UInt8 = 0x01
    public static let jobAttributes: UInt8 = 0x02
    public static let endOfAttributes: UInt8 = 0x03
    public static let printerAttributes: UInt8 = 0x04
    public static let unsupportedAttributes: UInt8 = 0x05

    // Out-of-band
    public static let unsupported: UInt8 = 0x10
    public static let unknown: UInt8 = 0x12
    public static let noValue: UInt8 = 0x13

    public static let integer: UInt8 = 0x21
    public static let boolean: UInt8 = 0x22
    public static let enumeration: UInt8 = 0x23
    public static let octetString: UInt8 = 0x30
    public static let dateTime: UInt8 = 0x31
    public static let resolution: UInt8 = 0x32
    public static let rangeOfInteger: UInt8 = 0x33
    public static let begCollection: UInt8 = 0x34
    public static let endCollection: UInt8 = 0x37
    public static let text: UInt8 = 0x41
    public static let name: UInt8 = 0x42
    public static let keyword: UInt8 = 0x44
    public static let uri: UInt8 = 0x45
    public static let uriScheme: UInt8 = 0x46
    public static let charset: UInt8 = 0x47
    public static let naturalLanguage: UInt8 = 0x48
    public static let mimeMediaType: UInt8 = 0x49
    public static let memberAttrName: UInt8 = 0x4A

    static let stringTags: Set<UInt8> = [text, name, keyword, uri, uriScheme, charset, naturalLanguage, mimeMediaType, memberAttrName]
}

public enum IPPOperation {
    public static let printJob: UInt16 = 0x0002
    public static let validateJob: UInt16 = 0x0004
    public static let createJob: UInt16 = 0x0005
    public static let sendDocument: UInt16 = 0x0006
    public static let cancelJob: UInt16 = 0x0008
    public static let getJobAttributes: UInt16 = 0x0009
    public static let getJobs: UInt16 = 0x000A
    public static let getPrinterAttributes: UInt16 = 0x000B
    public static let closeJob: UInt16 = 0x003B
    public static let identifyPrinter: UInt16 = 0x003C
}

public enum IPPStatus {
    public static let ok: UInt16 = 0x0000
    public static let okIgnoredOrSubstituted: UInt16 = 0x0001
    public static let clientBadRequest: UInt16 = 0x0400
    public static let clientNotPossible: UInt16 = 0x0404
    public static let clientNotFound: UInt16 = 0x0406
    public static let clientDocumentFormatNotSupported: UInt16 = 0x040A
    public static let clientDocumentFormatError: UInt16 = 0x0418
    public static let serverInternalError: UInt16 = 0x0500
    public static let serverOperationNotSupported: UInt16 = 0x0501
    public static let serverVersionNotSupported: UInt16 = 0x0503
}

public indirect enum IPPValue: Equatable, Sendable {
    case integer(Int32)
    case boolean(Bool)
    case enumeration(Int32)
    case string(tag: UInt8, String)
    case octets(tag: UInt8, [UInt8])
    case resolution(x: Int32, y: Int32, units: UInt8)
    case range(Int32, Int32)
    case collection([IPPAttribute])
    case outOfBand(tag: UInt8)

    public static func keyword(_ s: String) -> IPPValue { .string(tag: IPPTag.keyword, s) }
    public static func text(_ s: String) -> IPPValue { .string(tag: IPPTag.text, s) }
    public static func name(_ s: String) -> IPPValue { .string(tag: IPPTag.name, s) }
    public static func uri(_ s: String) -> IPPValue { .string(tag: IPPTag.uri, s) }
    public static func charset(_ s: String) -> IPPValue { .string(tag: IPPTag.charset, s) }
    public static func language(_ s: String) -> IPPValue { .string(tag: IPPTag.naturalLanguage, s) }
    public static func mimeType(_ s: String) -> IPPValue { .string(tag: IPPTag.mimeMediaType, s) }
    public static func int(_ v: Int) -> IPPValue { .integer(Int32(clamping: v)) }
    public static func enumValue(_ v: Int) -> IPPValue { .enumeration(Int32(clamping: v)) }
    /// 300x300 dpi (units 3 = dots per inch).
    public static func dpi(_ x: Int, _ y: Int) -> IPPValue { .resolution(x: Int32(x), y: Int32(y), units: 3) }

    public var stringValue: String? {
        if case .string(_, let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .integer(let v), .enumeration(let v): return Int(v)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .boolean(let b) = self { return b }
        return nil
    }

    public var collectionValue: [IPPAttribute]? {
        if case .collection(let c) = self { return c }
        return nil
    }
}

public struct IPPAttribute: Equatable, Sendable {
    public var name: String
    public var values: [IPPValue]

    public init(_ name: String, _ values: [IPPValue]) {
        self.name = name
        self.values = values
    }

    public init(_ name: String, _ value: IPPValue) {
        self.init(name, [value])
    }
}

public struct IPPAttributeGroup: Equatable, Sendable {
    public var tag: UInt8
    public var attributes: [IPPAttribute]

    public init(tag: UInt8, attributes: [IPPAttribute]) {
        self.tag = tag
        self.attributes = attributes
    }

    public subscript(name: String) -> IPPAttribute? {
        attributes.first { $0.name == name }
    }
}

public struct IPPMessage: Sendable {
    public var versionMajor: UInt8 = 2
    public var versionMinor: UInt8 = 0
    /// Operation id in requests, status code in responses.
    public var code: UInt16
    public var requestID: Int32
    public var groups: [IPPAttributeGroup] = []
    /// Document data trailing the attributes (Print-Job / Send-Document).
    public var data: [UInt8] = []

    public init(code: UInt16, requestID: Int32, groups: [IPPAttributeGroup] = [], data: [UInt8] = []) {
        self.code = code
        self.requestID = requestID
        self.groups = groups
        self.data = data
    }

    public var operationAttributes: IPPAttributeGroup? {
        groups.first { $0.tag == IPPTag.operationAttributes }
    }

    public var jobAttributes: IPPAttributeGroup? {
        groups.first { $0.tag == IPPTag.jobAttributes }
    }

    /// First value of `name`, searched across all groups.
    public func value(_ name: String) -> IPPValue? {
        for g in groups { if let a = g[name], let v = a.values.first { return v } }
        return nil
    }

    public func values(_ name: String) -> [IPPValue] {
        for g in groups { if let a = g[name] { return a.values } }
        return []
    }
}

// MARK: - Decoding

public enum IPPParseError: Error {
    case truncated
    case malformed(String)
}

private struct Cursor {
    let bytes: [UInt8]
    var pos = 0

    mutating func u8() throws -> UInt8 {
        guard pos < bytes.count else { throw IPPParseError.truncated }
        defer { pos += 1 }
        return bytes[pos]
    }

    mutating func u16() throws -> Int {
        Int(try u8()) << 8 | Int(try u8())
    }

    mutating func i32() throws -> Int32 {
        var v: UInt32 = 0
        for _ in 0..<4 { v = v << 8 | UInt32(try u8()) }
        return Int32(bitPattern: v)
    }

    mutating func take(_ n: Int) throws -> [UInt8] {
        guard pos + n <= bytes.count else { throw IPPParseError.truncated }
        defer { pos += n }
        return Array(bytes[pos..<(pos + n)])
    }
}

extension IPPMessage {
    public static func parse(_ bytes: [UInt8]) throws -> IPPMessage {
        var c = Cursor(bytes: bytes)
        let major = try c.u8(), minor = try c.u8()
        let code = UInt16(try c.u16())
        let requestID = try c.i32()

        var groups: [IPPAttributeGroup] = []
        var current: IPPAttributeGroup?

        while true {
            let tag = try c.u8()
            if tag < 0x10 {
                if let g = current { groups.append(g) }
                current = nil
                if tag == IPPTag.endOfAttributes { break }
                current = IPPAttributeGroup(tag: tag, attributes: [])
                continue
            }
            let name = String(decoding: try c.take(try c.u16()), as: UTF8.self)
            let raw = try c.take(try c.u16())
            let value = tag == IPPTag.begCollection ? .collection(try parseCollection(&c)) : decodeValue(tag: tag, raw)

            guard current != nil else { throw IPPParseError.malformed("attribute outside a group") }
            if name.isEmpty {
                guard !current!.attributes.isEmpty else { throw IPPParseError.malformed("additional value without attribute") }
                current!.attributes[current!.attributes.count - 1].values.append(value)
            } else {
                current!.attributes.append(IPPAttribute(name, value))
            }
        }

        var msg = IPPMessage(code: code, requestID: requestID, groups: groups)
        msg.versionMajor = major
        msg.versionMinor = minor
        msg.data = Array(bytes[c.pos...])
        return msg
    }

    private static func parseCollection(_ c: inout Cursor) throws -> [IPPAttribute] {
        var members: [IPPAttribute] = []
        while true {
            let tag = try c.u8()
            _ = try c.take(try c.u16()) // member names live in memberAttrName values
            let raw = try c.take(try c.u16())
            switch tag {
            case IPPTag.endCollection:
                return members
            case IPPTag.memberAttrName:
                members.append(IPPAttribute(String(decoding: raw, as: UTF8.self), []))
            default:
                let value = tag == IPPTag.begCollection ? .collection(try parseCollection(&c)) : decodeValue(tag: tag, raw)
                guard !members.isEmpty else { throw IPPParseError.malformed("collection value without member name") }
                members[members.count - 1].values.append(value)
            }
        }
    }

    private static func decodeValue(tag: UInt8, _ raw: [UInt8]) -> IPPValue {
        func i32(_ o: Int) -> Int32 {
            Int32(bitPattern: UInt32(raw[o]) << 24 | UInt32(raw[o + 1]) << 16 | UInt32(raw[o + 2]) << 8 | UInt32(raw[o + 3]))
        }
        switch tag {
        case 0x10...0x1F:
            return .outOfBand(tag: tag)
        case IPPTag.integer where raw.count == 4:
            return .integer(i32(0))
        case IPPTag.enumeration where raw.count == 4:
            return .enumeration(i32(0))
        case IPPTag.boolean where raw.count == 1:
            return .boolean(raw[0] != 0)
        case IPPTag.resolution where raw.count == 9:
            return .resolution(x: i32(0), y: i32(4), units: raw[8])
        case IPPTag.rangeOfInteger where raw.count == 8:
            return .range(i32(0), i32(4))
        case _ where IPPTag.stringTags.contains(tag):
            return .string(tag: tag, String(decoding: raw, as: UTF8.self))
        default:
            return .octets(tag: tag, raw)
        }
    }
}

// MARK: - Encoding

extension IPPMessage {
    public func serialize() -> [UInt8] {
        var out: [UInt8] = [versionMajor, versionMinor, UInt8(code >> 8), UInt8(code & 0xFF)]
        appendI32(requestID, &out)
        for group in groups {
            out.append(group.tag)
            for attr in group.attributes {
                for (i, value) in attr.values.enumerated() {
                    Self.appendValue(value, name: i == 0 ? attr.name : "", &out)
                }
            }
        }
        out.append(IPPTag.endOfAttributes)
        out.append(contentsOf: data)
        return out
    }

    private static func appendValue(_ value: IPPValue, name: String, _ out: inout [UInt8]) {
        func header(_ tag: UInt8, _ length: Int) {
            out.append(tag)
            appendString(name, &out)
            appendU16(length, &out)
        }
        switch value {
        case .integer(let v):
            header(IPPTag.integer, 4); appendI32(v, &out)
        case .enumeration(let v):
            header(IPPTag.enumeration, 4); appendI32(v, &out)
        case .boolean(let b):
            header(IPPTag.boolean, 1); out.append(b ? 1 : 0)
        case .string(let tag, let s):
            let utf8 = Array(s.utf8)
            header(tag, utf8.count); out.append(contentsOf: utf8)
        case .octets(let tag, let raw):
            header(tag, raw.count); out.append(contentsOf: raw)
        case .resolution(let x, let y, let units):
            header(IPPTag.resolution, 9); appendI32(x, &out); appendI32(y, &out); out.append(units)
        case .range(let lo, let hi):
            header(IPPTag.rangeOfInteger, 8); appendI32(lo, &out); appendI32(hi, &out)
        case .outOfBand(let tag):
            header(tag, 0)
        case .collection(let members):
            header(IPPTag.begCollection, 0)
            for member in members {
                out.append(IPPTag.memberAttrName)
                appendU16(0, &out)
                appendString(member.name, &out)
                for v in member.values { appendValue(v, name: "", &out) }
            }
            out.append(IPPTag.endCollection)
            appendU16(0, &out)
            appendU16(0, &out)
        }
    }
}

private func appendU16(_ v: Int, _ out: inout [UInt8]) {
    out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8(v & 0xFF))
}

private func appendI32(_ v: Int32, _ out: inout [UInt8]) {
    let u = UInt32(bitPattern: v)
    out.append(contentsOf: [UInt8(u >> 24), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)])
}

private func appendString(_ s: String, _ out: inout [UInt8]) {
    let utf8 = Array(s.utf8)
    appendU16(utf8.count, &out)
    out.append(contentsOf: utf8)
}
