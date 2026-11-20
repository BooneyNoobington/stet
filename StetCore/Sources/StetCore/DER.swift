import Foundation

/// Just enough ASN.1 DER for RFC 3161 timestamp requests and responses. Reading also accepts
/// BER's indefinite lengths, which some timestamp services use for their CMS envelopes.
enum DER {
    struct Node {
        let tag: UInt8
        /// The content octets (for an indefinite length: the children, without end-of-contents).
        let content: [UInt8]
        /// The whole element, tag and length included.
        let encoded: [UInt8]

        func children() throws -> [Node] { try DER.parseAll(content) }
    }

    enum Failure: Error { case truncated, unsupported }

    static func parse(_ bytes: [UInt8]) throws -> Node {
        var index = 0
        return try read(bytes, &index)
    }

    static func parseAll(_ bytes: [UInt8]) throws -> [Node] {
        var index = 0
        var nodes: [Node] = []
        while index < bytes.count {
            if bytes[index] == 0, index + 1 < bytes.count, bytes[index + 1] == 0 { break }
            nodes.append(try read(bytes, &index))
        }
        return nodes
    }

    private static func read(_ b: [UInt8], _ i: inout Int) throws -> Node {
        let start = i
        guard i + 2 <= b.count else { throw Failure.truncated }
        let tag = b[i]
        i += 1
        guard tag & 0x1f != 0x1f else { throw Failure.unsupported }
        var length = Int(b[i])
        i += 1
        if length == 0x80 {
            let contentStart = i
            while true {
                guard i + 2 <= b.count else { throw Failure.truncated }
                if b[i] == 0, b[i + 1] == 0 { break }
                _ = try read(b, &i)
            }
            let content = Array(b[contentStart..<i])
            i += 2
            return Node(tag: tag, content: content, encoded: Array(b[start..<i]))
        }
        if length & 0x80 != 0 {
            let count = length & 0x7f
            guard count > 0, count <= 4, i + count <= b.count else { throw Failure.truncated }
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(b[i])
                i += 1
            }
        }
        guard i + length <= b.count else { throw Failure.truncated }
        let content = Array(b[i..<(i + length)])
        i += length
        return Node(tag: tag, content: content, encoded: Array(b[start..<i]))
    }

    // MARK: Writing

    static func encode(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [tag]
        if content.count < 0x80 {
            out.append(UInt8(content.count))
        } else {
            var length = content.count
            var bytes: [UInt8] = []
            while length > 0 {
                bytes.insert(UInt8(length & 0xff), at: 0)
                length >>= 8
            }
            out.append(0x80 | UInt8(bytes.count))
            out += bytes
        }
        return out + content
    }

    static func sequence(_ items: [[UInt8]]) -> [UInt8] { encode(0x30, items.flatMap { $0 }) }

    static func integer(_ value: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = value
        repeat {
            bytes.insert(UInt8(v & 0xff), at: 0)
            v >>= 8
        } while v > 0
        return integer(bytes)
    }

    /// A non-negative integer from big-endian bytes.
    static func integer(_ bytes: [UInt8]) -> [UInt8] {
        var v = Array(bytes.drop { $0 == 0 })
        if v.isEmpty { v = [0] }
        if v[0] & 0x80 != 0 { v.insert(0, at: 0) }
        return encode(0x02, v)
    }

    static func octetString(_ bytes: [UInt8]) -> [UInt8] { encode(0x04, bytes) }
    static func boolean(_ value: Bool) -> [UInt8] { [0x01, 0x01, value ? 0xff : 0x00] }
    static let null: [UInt8] = [0x05, 0x00]

    static func oid(_ dotted: String) -> [UInt8] {
        let parts = dotted.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return encode(0x06, []) }
        var content: [UInt8] = [UInt8(parts[0] * 40 + parts[1])]
        for var part in parts.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(part & 0x7f)]
            part >>= 7
            while part > 0 {
                chunk.insert(UInt8(part & 0x7f) | 0x80, at: 0)
                part >>= 7
            }
            content += chunk
        }
        return encode(0x06, content)
    }

    // MARK: Reading values

    static func oidString(_ content: [UInt8]) -> String {
        guard let first = content.first else { return "" }
        var parts = [Int(first) / 40, Int(first) % 40]
        var value = 0
        for byte in content.dropFirst() {
            value = value << 7 | Int(byte & 0x7f)
            if byte & 0x80 == 0 {
                parts.append(value)
                value = 0
            }
        }
        return parts.map(String.init).joined(separator: ".")
    }

    static func integerValue(_ content: [UInt8]) -> Int {
        content.reduce(0) { $0 << 8 | Int($1) }
    }

    /// GeneralizedTime as used by RFC 3161: `YYYYMMDDhhmmss[.fff]Z`.
    static func generalizedTime(_ content: [UInt8]) -> Date? {
        let text = String(decoding: content, as: UTF8.self)
        guard text.hasSuffix("Z"), text.count >= 15 else { return nil }
        let digits = Array(text.dropLast())
        func number(_ range: Range<Int>) -> Int? { Int(String(digits[range])) }
        guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8),
              let hour = number(8..<10), let minute = number(10..<12), let second = number(12..<14)
        else { return nil }
        var fraction = 0.0
        if digits.count > 15, digits[14] == "." { fraction = Double("0" + String(digits[14...])) ?? 0 }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)?.addingTimeInterval(fraction)
    }
}
