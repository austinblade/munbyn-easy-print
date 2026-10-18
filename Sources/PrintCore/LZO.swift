// LZO1X-1 compressor, ported from miniLZO 2.10 (lzo1x_c.ch, D_BITS = 14).
// miniLZO is Copyright (C) 1996-2017 Markus Franz Xaver Johannes Oberhumer,
// licensed GPL-2.0-or-later. See THIRD_PARTY_NOTICES.md.
//
// The LabeLife TypeScript driver ships a literal-only encoder (valid
// LZO1X, no compression). That's fine for 50x30 mm labels at 203 dpi,
// but a 4x6" label at 300 dpi is ~270 KB raw — slow over Bluetooth.
// Shipping labels are mostly white, so a real match-finder shrinks them
// 10-30x. The output is bit-compatible with lzo1x_decompress[_safe].

public enum LZO1X {
    private static let dBits = 14
    private static let dMask = (1 << dBits) - 1
    private static let blockMax = 49152

    private static let m2MaxLen = 8
    private static let m3MaxLen = 33
    private static let m4MaxLen = 9
    private static let m2MaxOffset = 0x0800
    private static let m3MaxOffset = 0x4000
    private static let m3Marker: UInt8 = 32
    private static let m4Marker: UInt8 = 16

    public static func compress(_ input: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(input.count / 8 + 64)

        input.withUnsafeBufferPointer { p in
            var dict = [UInt16](repeating: 0, count: 1 << dBits)
            var blockStart = 0
            var remaining = p.count
            var t = 0

            while remaining > 20 {
                let ll = min(remaining, blockMax)
                for i in dict.indices { dict[i] = 0 }
                t = compressBlock(p, start: blockStart, length: ll, out: &out, ti: t, dict: &dict)
                blockStart += ll
                remaining -= ll
            }
            t += remaining

            if t > 0 {
                let ii = p.count - t
                if out.isEmpty && t <= 238 {
                    out.append(UInt8(17 + t))
                } else if t <= 3 {
                    out[out.count - 2] |= UInt8(t)
                } else if t <= 18 {
                    out.append(UInt8(t - 3))
                } else {
                    appendLongLength(t - 18, into: &out)
                }
                out.append(contentsOf: p[ii..<(ii + t)])
            }
        }

        out.append(contentsOf: [m4Marker | 1, 0, 0])
        return out
    }

    /// `0, 0..., n` run-length extension used by long literal runs.
    private static func appendLongLength(_ length: Int, into out: inout [UInt8]) {
        var tt = length
        out.append(0)
        while tt > 255 {
            tt -= 255
            out.append(0)
        }
        out.append(UInt8(tt))
    }

    @inline(__always)
    private static func le32(_ p: UnsafeBufferPointer<UInt8>, _ i: Int) -> UInt32 {
        UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16 | UInt32(p[i + 3]) << 24
    }

    /// One `do_compress` pass over `p[start ..< start+length]`. Returns the
    /// number of trailing bytes still owed as literals (`ti` for the next block).
    private static func compressBlock(
        _ p: UnsafeBufferPointer<UInt8>,
        start: Int,
        length: Int,
        out: inout [UInt8],
        ti tiIn: Int,
        dict: inout [UInt16]
    ) -> Int {
        var ti = tiIn
        let inEnd = start + length
        let ipEnd = start + length - 20
        var ip = start
        var ii = ip

        ip += ti < 4 ? 4 - ti : 0
        ip += 1 + ((ip - ii) >> 5)

        while ip < ipEnd {
            let dv = le32(p, ip)
            let dindex = Int((dv &* 0x1824_429D) >> UInt32(32 - dBits)) & dMask
            let mPos = start + Int(dict[dindex])
            dict[dindex] = UInt16(ip - start)
            if dv != le32(p, mPos) {
                ip += 1 + ((ip - ii) >> 5)
                continue
            }

            // Flush pending literals.
            ii -= ti
            ti = 0
            var t = ip - ii
            if t != 0 {
                if t <= 3 {
                    out[out.count - 2] |= UInt8(t)
                } else if t <= 18 {
                    out.append(UInt8(t - 3))
                } else {
                    appendLongLength(t - 18, into: &out)
                }
                out.append(contentsOf: p[ii..<(ii + t)])
                t = 0
            }

            // Extend the match.
            var mLen = 4
            if p[ip + mLen] == p[mPos + mLen] {
                repeat {
                    mLen += 1
                    if ip + mLen >= ipEnd { break }
                } while p[ip + mLen] == p[mPos + mLen]
            }

            var mOff = ip - mPos
            ip += mLen
            ii = ip

            if mLen <= m2MaxLen && mOff <= m2MaxOffset {
                mOff -= 1
                out.append(UInt8(((mLen - 1) << 5) | ((mOff & 7) << 2)))
                out.append(UInt8(mOff >> 3))
            } else if mOff <= m3MaxOffset {
                mOff -= 1
                if mLen <= m3MaxLen {
                    out.append(m3Marker | UInt8(mLen - 2))
                } else {
                    mLen -= m3MaxLen
                    out.append(m3Marker)
                    while mLen > 255 {
                        mLen -= 255
                        out.append(0)
                    }
                    out.append(UInt8(mLen))
                }
                out.append(UInt8((mOff << 2) & 0xFF))
                out.append(UInt8((mOff >> 6) & 0xFF))
            } else {
                mOff -= 0x4000
                let hi = UInt8((mOff >> 11) & 8)
                if mLen <= m4MaxLen {
                    out.append(m4Marker | hi | UInt8(mLen - 2))
                } else {
                    mLen -= m4MaxLen
                    out.append(m4Marker | hi)
                    while mLen > 255 {
                        mLen -= 255
                        out.append(0)
                    }
                    out.append(UInt8(mLen))
                }
                out.append(UInt8((mOff << 2) & 0xFF))
                out.append(UInt8((mOff >> 6) & 0xFF))
            }
        }

        return inEnd - (ii - ti)
    }

    /// TSPL `BITMAP …,4,` payload: each 4 KiB slice compressed independently,
    /// prefixed with its u32-LE compressed length, terminated by `00 00 00 00`.
    public static func chunkedFrame(_ raw: [UInt8], chunkSize: Int = 4096) -> [UInt8] {
        var out = [UInt8]()
        var offset = 0
        while offset < raw.count {
            let end = min(offset + chunkSize, raw.count)
            let compressed = compress(Array(raw[offset..<end]))
            appendUInt32LE(UInt32(compressed.count), to: &out)
            out.append(contentsOf: compressed)
            offset = end
        }
        appendUInt32LE(0, to: &out)
        return out
    }

    private static func appendUInt32LE(_ v: UInt32, to out: inout [UInt8]) {
        out.append(UInt8(v & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 24) & 0xFF))
    }
}
