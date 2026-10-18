import CoreGraphics
import Foundation
import XCTest
@testable import PrintCore

final class TSPLTests: XCTestCase {
    private func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    /// Mirrors the worked example in labelife docs/protocol/tspl.md (50x30 mm, 203 dpi).
    func testWorkedExampleWholeFrame() {
        var o = TSPLOptions()
        o.dialect = .aimoWholeFrame
        o.dpi = 203
        o.density = 8
        o.speed = 4
        o.gapMM = 2
        let job = TSPLEncoder.encode(MonoBitmap(width: 400, height: 240), options: o)
        let s = text(job)
        XCTAssertTrue(s.hasPrefix("\r\nDENSITY 8\r\nSPEED 4\r\nREFERENCE 0,0\r\nOFFSET 0 mm\r\nSIZE 50 mm,30 mm\r\nGAP 2.00 mm,0.00 mm\r\nDIRECTION 0,0\r\nCLS\r\nBITMAP 0,0,50,240,3,"))
        XCTAssertTrue(s.hasSuffix("\r\nPRINT 1,1\r\n"))

        // The decimal length must match the LZO payload that follows it.
        let header = "BITMAP 0,0,50,240,3,"
        let afterHeader = s.range(of: header)!.upperBound
        let lenStr = s[afterHeader...].prefix { $0 != "," }
        let len = Int(lenStr)!
        let payloadStart = s.utf8.distance(from: s.utf8.startIndex, to: afterHeader.samePosition(in: s.utf8)!) + lenStr.utf8.count + 1
        let payload = Array(job[payloadStart..<(payloadStart + len)])
        XCTAssertEqual(try LZO1XDecoder.decompress(payload), [UInt8](repeating: 0, count: 50 * 240))
        XCTAssertEqual(payloadStart + len + "\r\nPRINT 1,1\r\n".utf8.count, job.count)
    }

    func testChunkedDialect() {
        var o = TSPLOptions()
        o.dialect = .aimoChunked
        o.copies = 3
        let s = text(TSPLEncoder.encode(MonoBitmap(width: 1200, height: 1800), options: o))
        XCTAssertTrue(s.contains("SIZE 102 mm,152 mm\r\n"))
        XCTAssertTrue(s.contains("BITMAP 0,0,150,1800,4,"))
        XCTAssertTrue(s.hasSuffix("\u{0}\u{0}\u{0}\u{0}\r\nPRINT 1,3\n\r"))
        XCTAssertFalse(s.contains("DENSITY"))
    }

    func testStandardDialectInvertsBits() {
        var o = TSPLOptions()
        o.dialect = .standard
        o.paper = .blackMark
        o.flip = true
        var bmp = MonoBitmap(width: 16, height: 1)
        bmp.setDark(x: 0, y: 0)
        let job = TSPLEncoder.encode(bmp, options: o)
        let s = text(job)
        XCTAssertTrue(s.contains("BLINE 3.00 mm,0.00 mm\r\n"))
        XCTAssertTrue(s.contains("DIRECTION 1,0\r\n"))
        XCTAssertTrue(s.contains("SIZE 1.4 mm,0.1 mm\r\n"))
        let marker = Array("BITMAP 0,0,1,1,0,".utf8)
        let idx = (0...(job.count - marker.count)).first { Array(job[$0..<($0 + marker.count)]) == marker }!
        XCTAssertEqual(Array(job[(idx + marker.count)..<(idx + marker.count + 3)]), [0x7F, 0x0D, 0x0A])
    }

    func testStandardDialectSkipsBlankAreas() {
        // 4x6" at 300 dpi with a border and one block of text-like ink.
        var bmp = MonoBitmap(width: 1200, height: 1800)
        for x in 0..<1200 { bmp.setDark(x: x, y: 0); bmp.setDark(x: x, y: 1799) }
        for y in 0..<1800 { bmp.setDark(x: 0, y: y); bmp.setDark(x: 1199, y: y) }
        for y in 400..<460 { for x in stride(from: 300, to: 900, by: 3) { bmp.setDark(x: x, y: y) } }
        let blankBlock = MonoBitmap(width: 1200, height: 1800)

        let regions = TSPLEncoder.inkedRegions(bmp)
        let payload = regions.reduce(0) { $0 + $1.bytes * $1.rows }
        XCTAssertLessThan(payload, bmp.data.count / 10)
        XCTAssertTrue(TSPLEncoder.inkedRegions(blankBlock).isEmpty)

        // Painting the regions back reproduces every dark pixel, and nothing overlaps.
        var rebuilt = MonoBitmap(width: 1200, height: 1800)
        var covered = Set<Int>()
        for r in regions {
            for row in r.y..<(r.y + r.rows) {
                for bx in r.byteX..<(r.byteX + r.bytes) {
                    let i = row * bmp.bytesPerRow + bx
                    XCTAssertTrue(covered.insert(i).inserted)
                    rebuilt.data[i] = bmp.data[i]
                }
            }
        }
        XCTAssertEqual(rebuilt, bmp)
    }
}

final class RasterTests: XCTestCase {
    func testRotatesLandscapeLabelsOntoHead() {
        var o = RasterOptions()
        o.maxWidthDots = 1280
        // 6x4" page (landscape) → 1200 wide, 1800 tall after rotation.
        let label = Rasterizer.render(contentSize: CGSize(width: 432, height: 288), options: o, antialias: false) { ctx, rect in
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: rect.height - 30, width: 30, height: 30)) // top-left corner of the page
        }
        XCTAssertTrue(label.rotated)
        XCTAssertEqual(label.bitmap.width, 1200)
        XCTAssertEqual(label.bitmap.height, 1800)
        // Page top-left lands at the canvas top-right.
        XCTAssertTrue(label.bitmap.isDark(x: 1190, y: 5))
        XCTAssertFalse(label.bitmap.isDark(x: 5, y: 5))
    }

    func testPortraitTopLeftStaysTopLeft() {
        let label = Rasterizer.render(contentSize: CGSize(width: 288, height: 432), options: RasterOptions(), antialias: false) { ctx, rect in
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: rect.height - 30, width: 30, height: 30))
        }
        XCTAssertFalse(label.rotated)
        XCTAssertEqual(label.bitmap.width, 1200)
        XCTAssertTrue(label.bitmap.isDark(x: 5, y: 5))
        XCTAssertFalse(label.bitmap.isDark(x: 5, y: 1795))
    }

    func testPWGRasterDecode() throws {
        // One 16x2 sgray_8 page at 300 dpi: line 0 black, line 1 white.
        var header = [UInt8](repeating: 0, count: 1796)
        func put(_ v: Int, _ o: Int) { header[o] = UInt8(v >> 24); header[o + 1] = UInt8((v >> 16) & 0xFF); header[o + 2] = UInt8((v >> 8) & 0xFF); header[o + 3] = UInt8(v & 0xFF) }
        put(300, 276); put(300, 280); put(16, 372); put(2, 376); put(8, 384); put(8, 388); put(16, 392); put(18, 400)
        let lines: [UInt8] = [0x00, 15, 0x00, 0x00, 15, 0xFF]
        let pages = try PWGRaster.decode(Array("RaS2".utf8) + header + lines)
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].image.width, 16)
        XCTAssertEqual(pages[0].sizePoints.width, 16 * 72 / 300, accuracy: 0.001)
    }

    func testFormatSniffing() {
        XCTAssertEqual(DocumentFormat.resolve(mimeType: "application/octet-stream", data: Array("%PDF-1.7".utf8)), .pdf)
        XCTAssertEqual(DocumentFormat.resolve(mimeType: nil, data: Array("UNIRAST\0".utf8)), .urf)
        XCTAssertEqual(DocumentFormat.resolve(mimeType: "image/pwg-raster", data: []), .pwgRaster)
    }

    func testMediaParsing() {
        XCTAssertEqual(LabelMedia.default.keyword, "oe_4x6-label_4x6in")
        XCTAssertEqual(LabelMedia.default.width, 10160)
        XCTAssertEqual(LabelMedia.inches(2.25, 1.25).keyword, "oe_2.25x1.25-label_2.25x1.25in")
        let custom = LabelMedia.parse(keyword: "custom_58x40mm_58x40mm")
        XCTAssertEqual(custom?.width, 5800)
        XCTAssertEqual(custom?.height, 4000)
    }
}

final class IPPTests: XCTestCase {
    func testRoundTripWithCollectionsAndData() throws {
        let mediaCol = IPPValue.collection([
            IPPAttribute("media-size", .collection([
                IPPAttribute("x-dimension", .int(10160)),
                IPPAttribute("y-dimension", .int(15240)),
            ])),
            IPPAttribute("media-top-margin", .int(0)),
        ])
        let msg = IPPMessage(code: IPPOperation.printJob, requestID: 42, groups: [
            IPPAttributeGroup(tag: IPPTag.operationAttributes, attributes: [
                IPPAttribute("attributes-charset", .charset("utf-8")),
                IPPAttribute("attributes-natural-language", .language("en")),
                IPPAttribute("printer-uri", .uri("ipp://127.0.0.1:8631/ipp/print")),
                IPPAttribute("document-format", .mimeType("application/pdf")),
            ]),
            IPPAttributeGroup(tag: IPPTag.jobAttributes, attributes: [
                IPPAttribute("copies", .int(2)),
                IPPAttribute("media-col", mediaCol),
                IPPAttribute("printer-resolution", .dpi(300, 300)),
                IPPAttribute("finishings", [.enumValue(3), .enumValue(4)]),
            ]),
        ], data: Array("%PDF".utf8))

        let parsed = try IPPMessage.parse(msg.serialize())
        XCTAssertEqual(parsed.code, IPPOperation.printJob)
        XCTAssertEqual(parsed.requestID, 42)
        XCTAssertEqual(parsed.groups, msg.groups)
        XCTAssertEqual(parsed.data, Array("%PDF".utf8))
        XCTAssertEqual(parsed.value("copies")?.intValue, 2)
        XCTAssertEqual(LabelMedia.from(mediaCol: parsed.value("media-col")!.collectionValue!), .default)
    }

    func testRejectsTruncated() {
        XCTAssertThrowsError(try IPPMessage.parse([2, 0, 0, 0x0B, 0, 0]))
    }
}
