import Cocoa
import XCTest

/// End-to-end checks for the scroll-capture stitcher: alignment of small and
/// large steps, fixed header/footer handling, and the final composited image.
final class ScrollStitcherTests: XCTestCase {

    // MARK: - Fixtures

    /// A deterministic, non-repeating page. Each text row has its own
    /// horizontal offset, so a one-row shift changes the row fingerprint and
    /// the matcher cannot lock onto a line period.
    private func contentPixel(_ contentRow: Int, _ x: Int) -> (UInt8, UInt8, UInt8) {
        var seed = UInt64(bitPattern: Int64(contentRow &* 2_654_435_761 &+ 12_345))
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let band = Int((seed >> 33) % 50)
        let inked = (x + band) % 46 < 26
        if inked {
            let shade = UInt8(25 + Int((seed >> 20) % 50))
            return (shade, shade, min(255, shade + 20))
        }
        return (248, 248, 250)
    }

    private func headerPixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let button = (x / 14) % 5 == 0 && y > 8 && y < 24
        return button ? (210, 220, 235) : (42, 56, 78)
    }

    private func footerPixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let button = (x / 18) % 4 == 0 && y > 4 && y < 15
        return button ? (250, 210, 120) : (190, 120, 55)
    }

    /// One viewport-sized frame of a page scrolled to `scroll`.
    private func makeFrame(width: Int = 160, height: Int = 240,
                           header: Int = 30, footer: Int = 20,
                           scroll: Int, rowPadding: Int = 0) throws -> CGImage {
        let bytesPerRow = width * 4 + rowPadding
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)

        for y in 0..<height {
            for x in 0..<width {
                let rgb: (UInt8, UInt8, UInt8)
                if y < header {
                    rgb = headerPixel(x, y)
                } else if y >= height - footer {
                    rgb = footerPixel(x, y - (height - footer))
                } else {
                    rgb = contentPixel(scroll + y - header, x)
                }
                let offset = y * bytesPerRow + x * 4
                bytes[offset] = rgb.2
                bytes[offset + 1] = rgb.1
                bytes[offset + 2] = rgb.0
                bytes[offset + 3] = 255
            }
            for pad in 0..<rowPadding {
                bytes[y * bytesPerRow + width * 4 + pad] = UInt8((y * 31 + pad * 17) % 256)
            }
        }

        let data = try XCTUnwrap(CFDataCreate(nil, bytes, bytes.count))
        let provider = try XCTUnwrap(CGDataProvider(data: data))
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                     | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// The whole page as it should look when stitched: header, content rows
    /// 0..<pageHeight, then the fixed footer.
    private func makeExpectedPage(width: Int = 160, header: Int = 30, footer: Int = 20,
                                  pageHeight: Int) throws -> CGImage {
        let height = header + pageHeight + footer
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let rgb: (UInt8, UInt8, UInt8)
                if y < header {
                    rgb = headerPixel(x, y)
                } else if y >= header + pageHeight {
                    rgb = footerPixel(x, y - (header + pageHeight))
                } else {
                    rgb = contentPixel(y - header, x)
                }
                let offset = y * bytesPerRow + x * 4
                bytes[offset] = rgb.2
                bytes[offset + 1] = rgb.1
                bytes[offset + 2] = rgb.0
                bytes[offset + 3] = 255
            }
        }
        let data = try XCTUnwrap(CFDataCreate(nil, bytes, bytes.count))
        let provider = try XCTUnwrap(CGDataProvider(data: data))
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                     | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (Int, Int, Int) {
        let rep = NSBitmapImageRep(cgImage: image)
        let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        return (Int((color.redComponent * 255).rounded()),
                Int((color.greenComponent * 255).rounded()),
                Int((color.blueComponent * 255).rounded()))
    }

    // MARK: - Alignment

    func testAlignmentMeasuresSmallAndLargeShifts() throws {
        let header = 30
        let footer = 20
        let previous = try makeFrame(header: header, footer: footer, scroll: 0)

        for shift in [1, 2, 3, 5, 12, 40, 100, 150] {
            let current = try makeFrame(header: header, footer: footer, scroll: shift)
            let alignment = try XCTUnwrap(ScrollFrameAnalyzer.verticalAlignment(
                current: current, previous: previous,
                headerRows: header, footerRows: footer),
                "shift \(shift) should register")
            XCTAssertEqual(alignment.offset, Double(shift), accuracy: 1.0,
                           "measured \(alignment.offset) for a \(shift)-row scroll")
            XCTAssertGreaterThan(alignment.confidence, 0.4)
            XCTAssertLessThan(alignment.cost, 0.02)
        }
    }

    func testAlignmentUsesExpectedOffsetToResolveRepetition() throws {
        // Every 20 rows are identical, so 20 and 40 match equally well.
        let width = 120, height = 200, header = 10, footer = 10
        let repeated = try makeRepeatedFrame(width: width, height: height,
                                             header: header, footer: footer, scroll: 0)
        let moved = try makeRepeatedFrame(width: width, height: height,
                                          header: header, footer: footer, scroll: 40)
        let alignment = try XCTUnwrap(ScrollFrameAnalyzer.verticalAlignment(
            current: moved, previous: repeated,
            headerRows: header, footerRows: footer, expectedOffset: 40))
        XCTAssertEqual(alignment.offset, 40, accuracy: 1.0,
                       "the previous step should pick the matching period")
    }

    func testAlignmentRejectsShiftsWithoutEnoughOverlap() throws {
        let previous = try makeFrame(header: 30, footer: 20, scroll: 0)
        // The content area is 190 rows; a 180-row shift leaves 10 rows.
        let current = try makeFrame(header: 30, footer: 20, scroll: 180)
        XCTAssertNil(ScrollFrameAnalyzer.verticalAlignment(
            current: current, previous: previous, headerRows: 30, footerRows: 20))
    }

    func testAlignmentHandlesPaddedRows() throws {
        let previous = try makeFrame(scroll: 0, rowPadding: 44)
        let current = try makeFrame(scroll: 57, rowPadding: 44)
        let alignment = try XCTUnwrap(ScrollFrameAnalyzer.verticalAlignment(
            current: current, previous: previous, headerRows: 30, footerRows: 20))
        XCTAssertEqual(alignment.offset, 57, accuracy: 1.0)
    }

    func testIdenticalFramesReportNoMovement() throws {
        let frame = try makeFrame(scroll: 0)
        let alignment = try XCTUnwrap(ScrollFrameAnalyzer.verticalAlignment(
            current: frame, previous: frame, headerRows: 30, footerRows: 20))
        XCTAssertEqual(alignment.offset, 0, accuracy: 0.01)
    }

    func testBlankContentCannotBeRegistered() throws {
        let width = 80, height = 120
        let blank = try makeSolidFrame(width: width, height: height, color: (255, 255, 255))
        XCTAssertNil(ScrollFrameAnalyzer.verticalAlignment(
            current: blank, previous: blank, headerRows: 0, footerRows: 0),
            "a solid page has no features to align")
    }

    func testAlignmentHandlesAVerticalGradient() throws {
        let previous = try makeGradientFrame(scroll: 0)
        for shift in [1, 5, 37] {
            let current = try makeGradientFrame(scroll: shift)
            let alignment = try XCTUnwrap(ScrollFrameAnalyzer.verticalAlignment(
                current: current, previous: previous, headerRows: 0, footerRows: 0),
                "gradient shift \(shift) should register")
            XCTAssertEqual(alignment.offset, Double(shift), accuracy: 1.0)
        }
    }

    func testFrozenBottomRowsFindsAFixedFooter() throws {
        let previous = try makeFrame(scroll: 0)
        let current = try makeFrame(scroll: 37)
        XCTAssertEqual(ScrollFrameAnalyzer.frozenTopRows(
            current: current, previous: previous, rightMarginPx: 0), 30)
        XCTAssertEqual(ScrollFrameAnalyzer.frozenBottomRows(
            current: current, previous: previous, rightMarginPx: 0), 20)
    }

    func testFramesAreStableForIdenticalFramesButNotScrolling() throws {
        let base = try makeFrame(scroll: 0)
        let scrolled = try makeFrame(scroll: 4)
        XCTAssertFalse(ScrollFrameAnalyzer.framesAreStable(
            current: scrolled, previous: base, tolerance: 0.002))
        XCTAssertTrue(ScrollFrameAnalyzer.framesAreStable(
            current: base, previous: base, tolerance: 0.002))
    }

    // MARK: - Stitcher

    func testStitcherReconstructsTheWholePage() throws {
        let width = 160, height = 240, header = 30, footer = 20
        let pageHeight = 600
        let steps = [0, 40, 90, 150, 220, 290, 350, 390, 410]

        var frames: [CGImage] = []
        for step in steps {
            frames.append(try makeFrame(width: width, height: height,
                                        header: header, footer: footer, scroll: step))
        }

        // The first viewport's fixed footer is removed before stitching.
        let firstRows = height - footer
        let croppedFirst = try XCTUnwrap(frames[0].cropping(
            to: CGRect(x: 0, y: 0, width: width, height: firstRows)))
        let stitcher = try XCTUnwrap(ScrollStitcher(firstFrame: croppedFirst, maximumHeight: 10000))

        var contentTop = 0.0
        for index in 1..<frames.count {
            let alignment = try XCTUnwrap(ScrollFrameAnalyzer.verticalAlignment(
                current: frames[index], previous: frames[index - 1],
                headerRows: header, footerRows: footer,
                expectedOffset: index > 1 ? Double(steps[index] - steps[index - 1]) : nil))
            contentTop += alignment.offset

            let targetBottom = contentTop + Double(height - footer)
            let newRows = Int(targetBottom.rounded()) - stitcher.height
            XCTAssertGreaterThan(newRows, 0, "step \(steps[index]) should add content")
            let sourceStart = height - footer - newRows
            XCTAssertTrue(stitcher.append(frames[index], newRows: newRows,
                                          sourceStartRow: sourceStart, overlapRows: 1))
        }

        // The controller draws the fixed footer once, after the content.
        XCTAssertTrue(stitcher.append(frames.last!, newRows: footer,
                                      sourceStartRow: height - footer, overlapRows: 0))
        XCTAssertEqual(stitcher.height, header + pageHeight + footer)

        let stitched = try XCTUnwrap(stitcher.snapshot())
        let expected = try makeExpectedPage(width: width, header: header,
                                            footer: footer, pageHeight: pageHeight)
        XCTAssertEqual(stitched.width, expected.width)
        XCTAssertEqual(stitched.height, expected.height)

        // Sample the whole image; comparing every pixel of a 650-row fixture
        // is slower than the behaviour under test needs.
        for y in stride(from: 0, to: expected.height, by: 7) {
            for x in stride(from: 0, to: expected.width, by: 11) {
                let actual = try pixel(stitched, x: x, y: y)
                let wanted = try pixel(expected, x: x, y: y)
                XCTAssertLessThanOrEqual(abs(actual.0 - wanted.0), 2, "red at (\(x),\(y))")
                XCTAssertLessThanOrEqual(abs(actual.1 - wanted.1), 2, "green at (\(x),\(y))")
                XCTAssertLessThanOrEqual(abs(actual.2 - wanted.2), 2, "blue at (\(x),\(y))")
            }
        }
    }

    func testStitcherPreviewKeepsTheAspectRatio() throws {
        let first = try makeFrame(scroll: 0)
        let stitcher = try XCTUnwrap(ScrollStitcher(firstFrame: first, maximumHeight: 10000))
        XCTAssertTrue(stitcher.append(try makeFrame(scroll: 120), newRows: 120,
                                      sourceStartRow: first.height - 120))
        let preview = try XCTUnwrap(stitcher.preview(maxWidth: 200, maxHeight: 800))
        XCTAssertLessThanOrEqual(preview.width, 200)
        XCTAssertLessThanOrEqual(preview.height, 800)
        let expectedRatio = Double(stitcher.width) / Double(stitcher.height)
        let actualRatio = Double(preview.width) / Double(preview.height)
        XCTAssertEqual(actualRatio, expectedRatio, accuracy: 0.02)
    }

    func testStitcherRefusesToGrowPastTheLimit() throws {
        let first = try makeFrame(scroll: 0)
        let stitcher = try XCTUnwrap(ScrollStitcher(firstFrame: first, maximumHeight: first.height))
        XCTAssertFalse(stitcher.append(try makeFrame(scroll: 30), newRows: 30,
                                       sourceStartRow: first.height - 30))
        XCTAssertTrue(stitcher.reachedLimit)
        XCTAssertEqual(stitcher.height, first.height)
    }

    // MARK: - Repetitive fixture

    /// Rows repeat every 20 pixels so several scroll offsets match exactly.
    private func makeRepeatedFrame(width: Int, height: Int, header: Int, footer: Int,
                                   scroll: Int) throws -> CGImage {
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let rgb: (UInt8, UInt8, UInt8)
                if y < header {
                    rgb = headerPixel(x, y)
                } else if y >= height - footer {
                    rgb = footerPixel(x, y - (height - footer))
                } else {
                    let row = (scroll + y - header) % 20
                    rgb = (x + row * 3) % 30 < 12 ? (20, 20, 20) : (240, 240, 240)
                }
                let offset = y * bytesPerRow + x * 4
                bytes[offset] = rgb.2
                bytes[offset + 1] = rgb.1
                bytes[offset + 2] = rgb.0
                bytes[offset + 3] = 255
            }
        }
        let data = try XCTUnwrap(CFDataCreate(nil, bytes, bytes.count))
        let provider = try XCTUnwrap(CGDataProvider(data: data))
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                     | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// A vertical gradient: no horizontal detail, but every row differs from the
    /// one above it.
    private func makeGradientFrame(width: Int = 80, height: Int = 200,
                                   scroll: Int) throws -> CGImage {
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            let value = UInt8((scroll + y) % 256)
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                bytes[offset] = value
                bytes[offset + 1] = value
                bytes[offset + 2] = value
                bytes[offset + 3] = 255
            }
        }
        let data = try XCTUnwrap(CFDataCreate(nil, bytes, bytes.count))
        let provider = try XCTUnwrap(CGDataProvider(data: data))
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                     | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func makeSolidFrame(width: Int, height: Int,
                                color: (UInt8, UInt8, UInt8)) throws -> CGImage {
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            bytes[offset] = color.2
            bytes[offset + 1] = color.1
            bytes[offset + 2] = color.0
            bytes[offset + 3] = 255
        }
        let data = try XCTUnwrap(CFDataCreate(nil, bytes, bytes.count))
        let provider = try XCTUnwrap(CGDataProvider(data: data))
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                     | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}
