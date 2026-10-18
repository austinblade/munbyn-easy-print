import Foundation
import XCTest
@testable import PrintCore

/// Full LZO1X decompressor (port of lzo1x_d.ch) — test-only, to prove the
/// compressor emits streams any stock decoder accepts.
enum LZO1XDecoder {
    struct Corrupt: Error {}

    static func decompress(_ src: [UInt8]) throws -> [UInt8] {
        var out = [UInt8]()
        var ip = 0
        func next() throws -> Int {
            guard ip < src.count else { throw Corrupt() }
            defer { ip += 1 }
            return Int(src[ip])
        }
        func literals(_ n: Int) throws {
            guard ip + n <= src.count else { throw Corrupt() }
            out.append(contentsOf: src[ip..<(ip + n)])
            ip += n
        }
        func copyMatch(distance: Int, length: Int) throws {
            guard distance > 0, distance <= out.count else { throw Corrupt() }
            let start = out.count - distance
            for i in 0..<length { out.append(out[start + i]) }
        }
        func extended(_ base: Int) throws -> Int {
            var t = 0
            while src[ip] == 0 { t += 255; ip += 1 }
            return t + base + (try next())
        }

        enum State { case instruction, firstLiteralRun, match(Int), matchNext(Int) }
        var state: State = .instruction

        if src[0] > 17 {
            ip = 1
            let t = Int(src[0]) - 17
            if t < 4 {
                state = .matchNext(t)
            } else {
                try literals(t)
                state = .firstLiteralRun
            }
        }

        while true {
            switch state {
            case .instruction:
                var t = try next()
                if t >= 16 { state = .match(t); continue }
                if t == 0 { t = try extended(15) }
                try literals(t + 3)
                state = .firstLiteralRun

            case .firstLiteralRun:
                let t = try next()
                if t >= 16 { state = .match(t); continue }
                let d = 1 + 0x0800 + (t >> 2) + (try next() << 2)
                try copyMatch(distance: d, length: 3)
                state = .matchNext(Int(src[ip - 2] & 3))

            case .match(var t):
                let distance: Int
                let length: Int
                if t >= 64 {
                    distance = 1 + ((t >> 2) & 7) + (try next() << 3)
                    length = (t >> 5) + 1
                } else if t >= 32 {
                    t &= 31
                    if t == 0 { t = try extended(31) }
                    let lo = try next(), hi = try next()
                    distance = 1 + (lo >> 2) + (hi << 6)
                    length = t + 2
                } else if t >= 16 {
                    var d = (t & 8) << 11
                    t &= 7
                    if t == 0 { t = try extended(7) }
                    let lo = try next(), hi = try next()
                    d += (lo >> 2) + (hi << 6)
                    if d == 0 {
                        guard ip == src.count else { throw Corrupt() }
                        return out
                    }
                    distance = d + 0x4000
                    length = t + 2
                } else {
                    distance = 1 + (t >> 2) + (try next() << 2)
                    length = 2
                }
                try copyMatch(distance: distance, length: length)
                state = .matchNext(Int(src[ip - 2] & 3))

            case .matchNext(let t):
                if t == 0 { state = .instruction; continue }
                try literals(t)
                // Inside the match loop a byte < 16 is an M1 match, not a literal run.
                state = .match(try next())
            }
        }
    }
}

final class LZOTests: XCTestCase {
    private func roundTrip(_ input: [UInt8], file: StaticString = #filePath, line: UInt = #line) throws {
        let compressed = LZO1X.compress(input)
        let back = try LZO1XDecoder.decompress(compressed)
        XCTAssertEqual(back, input, "round trip failed for \(input.count) bytes", file: file, line: line)
    }

    func testEmptyAndTiny() throws {
        XCTAssertEqual(LZO1X.compress([]), [0x11, 0, 0])
        for n in [1, 3, 4, 17, 18, 19, 20, 21, 238, 239, 500] {
            try roundTrip((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 37) })
        }
    }

    func testCompressesWhiteSpace() throws {
        let blank = [UInt8](repeating: 0, count: 160 * 1800) // 4x6" @ 300 dpi
        let compressed = LZO1X.compress(blank)
        XCTAssertLessThan(compressed.count, 2000)
        try roundTrip(blank)
    }

    func testRandomAndStructuredData() throws {
        var rng = SystemRandomNumberGenerator()
        for size in [100, 4096, 49152, 49153, 120_000, 300_000] {
            try roundTrip((0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) })
            // Label-like: mostly white with repeated bar patterns and noise.
            var label = [UInt8](repeating: 0, count: size)
            for i in stride(from: 0, to: size, by: 97) { label[i] = 0xFF; if i + 1 < size { label[i + 1] = UInt8.random(in: 0...255, using: &rng) } }
            try roundTrip(label)
        }
    }

    func testChunkedFrame() throws {
        let raw = (0..<10000).map { UInt8(truncatingIfNeeded: $0 / 50) }
        let framed = LZO1X.chunkedFrame(raw)
        var pos = 0
        var rebuilt = [UInt8]()
        while true {
            let len = Int(framed[pos]) | Int(framed[pos + 1]) << 8 | Int(framed[pos + 2]) << 16 | Int(framed[pos + 3]) << 24
            pos += 4
            if len == 0 { break }
            let chunk = try LZO1XDecoder.decompress(Array(framed[pos..<(pos + len)]))
            XCTAssertLessThanOrEqual(chunk.count, 4096)
            rebuilt += chunk
            pos += len
        }
        XCTAssertEqual(pos, framed.count)
        XCTAssertEqual(rebuilt, raw)
    }

    /// Writes fixtures for cross-checking against liblzo2 (see scripts/verify-lzo.c).
    func testDumpFixturesForLiblzo() throws {
        guard let dir = ProcessInfo.processInfo.environment["LZO_FIXTURE_DIR"] else { throw XCTSkip("LZO_FIXTURE_DIR not set") }
        var rng = SystemRandomNumberGenerator()
        for (i, size) in [1, 19, 239, 4096, 49152, 49153, 270_000].enumerated() {
            var input = [UInt8](repeating: 0, count: size)
            for j in 0..<size where j % 13 == 0 { input[j] = UInt8.random(in: 0...255, using: &rng) }
            try Data(input).write(to: URL(fileURLWithPath: "\(dir)/case\(i).raw"))
            try Data(LZO1X.compress(input)).write(to: URL(fileURLWithPath: "\(dir)/case\(i).lzo"))
        }
    }
}
