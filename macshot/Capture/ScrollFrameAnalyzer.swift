import CoreGraphics
import Foundation

/// Pixel comparisons used by scroll capture to work out what is scrolling and
/// what isn't: the scrollbar strip down the right edge, and any frozen header
/// pinned to the top of the window.
///
/// Kept free of capture state so it can be reasoned about — and tested — on
/// plain images. `ScrollCaptureController` owns the decisions; this owns the
/// arithmetic.
///
/// Row addressing goes through each image's own `bytesPerRow`. Deriving the
/// stride as `width * 4` is wrong whenever the window server pads rows for
/// alignment, and the error compounds row by row, so every sample after the
/// first row lands in the wrong place.
enum ScrollFrameAnalyzer {

    /// SAD (sum of absolute differences) above which two samples count as
    /// different content rather than compression or antialiasing noise.
    static let differenceThreshold: UInt64 = 8

    /// Registration needs some overlap with the previous frame. Reject invalid
    /// or out-of-frame shifts before callers round them into pixel integers.
    static func validatedVerticalShift(_ shift: CGFloat, frameHeight: Int) -> CGFloat? {
        guard frameHeight > 0, shift.isFinite, abs(shift) < CGFloat(frameHeight) else { return nil }
        return shift
    }

    /// A frame ready for comparison: raw bytes plus the geometry needed to
    /// address them. `data` keeps the pixel buffer alive for the scan.
    struct Frame {
        let data: CFData
        let bytes: UnsafePointer<UInt8>
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let redOffset: Int
        let greenOffset: Int
        let blueOffset: Int

        /// Byte offset of a pixel, or nil when it falls outside the buffer.
        func offset(x: Int, y: Int) -> Int? {
            guard x >= 0, y >= 0, x < width, y < height else { return nil }
            let offset = y * bytesPerRow + x * 4
            guard offset + 3 < CFDataGetLength(data) else { return nil }
            return offset
        }
    }

    /// Wraps a `CGImage` for scanning. Returns nil for anything that isn't
    /// 8-bit, 32-bits-per-pixel — the byte offsets below only make sense there.
    static func frame(for image: CGImage) -> Frame? {
        let (minimumStride, strideOverflow) = image.width.multipliedReportingOverflow(by: 4)
        let (minimumBytes, sizeOverflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              image.colorSpace?.model == .rgb, !image.bitmapInfo.contains(.floatComponents),
              image.width > 0, image.height > 0,
              !strideOverflow, !sizeOverflow, image.bytesPerRow >= minimumStride,
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        // A buffer shorter than the geometry claims would read past the end.
        guard CFDataGetLength(data) >= minimumBytes else { return nil }
        let first: Bool
        switch image.alphaInfo {
        case .first, .premultipliedFirst, .noneSkipFirst: first = true
        case .last, .premultipliedLast, .noneSkipLast: first = false
        default: return nil
        }
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        guard order == .byteOrderDefault || order == .byteOrder32Big || order == .byteOrder32Little else { return nil }
        // AlphaFirst describes significance, not the first byte in memory.
        // Match R/G/B by channel even when the two frames use different layouts.
        let little = order == .byteOrder32Little
        let rgb = first ? (little ? (2, 1, 0) : (1, 2, 3)) : (little ? (3, 2, 1) : (0, 1, 2))
        return Frame(data: data, bytes: bytes, width: image.width,
                     height: image.height, bytesPerRow: image.bytesPerRow,
                     redOffset: rgb.0, greenOffset: rgb.1, blueOffset: rgb.2)
    }

    /// Absolute difference of the three colour channels at one pixel.
    private static func pixelDifference(_ a: Frame, _ b: Frame, x: Int, y: Int) -> UInt64? {
        pixelDifference(a, b, ax: x, ay: y, bx: x, by: y)
    }

    /// Difference at two independent positions — the current frame's row and
    /// the previous frame's row one scroll offset below it.
    private static func pixelDifference(_ a: Frame, _ b: Frame,
                                        ax: Int, ay: Int, bx: Int, by: Int) -> UInt64? {
        guard let aOffset = a.offset(x: ax, y: ay), let bOffset = b.offset(x: bx, y: by) else { return nil }
        let diff = abs(Int(a.bytes[aOffset + a.redOffset]) - Int(b.bytes[bOffset + b.redOffset]))
            + abs(Int(a.bytes[aOffset + a.greenOffset]) - Int(b.bytes[bOffset + b.greenOffset]))
            + abs(Int(a.bytes[aOffset + a.blueOffset]) - Int(b.bytes[bOffset + b.blueOffset]))
        return UInt64(diff)
    }

    /// Width in pixels of the changing strip at the right edge — the scrollbar,
    /// which must be excluded from matching or it drags the alignment with it.
    ///
    /// Returns 0 when the right edge is static, or nil when the two frames
    /// can't be compared at all (different sizes, unsupported pixel format).
    static func scrollbarWidth(current: CGImage, previous: CGImage) -> Int? {
        guard current.width == previous.width, current.height == previous.height,
              let a = frame(for: current), let b = frame(for: previous) else { return nil }

        let rowStart = a.height * 2 / 10
        let rowEnd = a.height * 8 / 10
        guard rowEnd > rowStart else { return 0 }
        let rowStep = max(1, (rowEnd - rowStart) / 40)

        var width = 0
        let maxScanCols = min(50, a.width / 8)
        for columnOffset in 0..<max(0, maxScanCols) {
            let column = a.width - 1 - columnOffset
            var sad: UInt64 = 0
            var samples = 0
            for row in stride(from: rowStart, to: rowEnd, by: rowStep) {
                guard let difference = pixelDifference(a, b, x: column, y: row) else { continue }
                sad += difference
                samples += 1
            }
            guard samples > 0 else { continue }

            if sad / UInt64(samples) > differenceThreshold {
                width = columnOffset + 1
            } else if width > 0 {
                break  // found the inner edge of the changing strip
            }
        }
        return width
    }

    /// How many rows at the top of the frame are unchanged — a pinned header
    /// that must not be stitched in again with every strip.
    ///
    /// Returns the row index of the first changed row; `height` when the whole
    /// frame is unchanged, and nil when the frames can't be compared.
    static func frozenTopRows(current: CGImage, previous: CGImage, rightMarginPx: Int) -> Int? {
        guard current.width == previous.width, current.height == previous.height,
              let a = frame(for: current), let b = frame(for: previous) else { return nil }

        let lastColumn = max(1, a.width - max(0, rightMarginPx))
        let columnStep = 4

        for row in 0..<a.height {
            var sad: UInt64 = 0
            var samples = 0
            for column in stride(from: 0, to: lastColumn, by: columnStep) {
                guard let difference = pixelDifference(a, b, x: column, y: row) else { continue }
                sad += difference
                samples += 1
            }
            // A row we couldn't sample counts as changed, so detection stops
            // rather than silently treating the whole frame as frozen.
            let average = samples > 0 ? sad / UInt64(samples) : UInt64.max
            if average > differenceThreshold { return row }
        }
        return a.height
    }

    /// How many rows at the bottom of the frame are unchanged — a pinned footer,
    /// floating toolbar or video bar that must not be stitched in with every
    /// strip. Unlike the header, blank rows are not enough: a white page margin
    /// is static too, but excluding it would throw away real layout. Only rows
    /// the band as a whole must contain visible detail.
    ///
    /// Returns 0 when there is no fixed footer and nil when the frames can't be
    /// compared.
    static func frozenBottomRows(current: CGImage, previous: CGImage,
                                 rightMarginPx: Int,
                                 minimumDetail: Int = 4) -> Int? {
        guard current.width == previous.width, current.height == previous.height,
              let a = frame(for: current), let b = frame(for: previous) else { return nil }

        let lastColumn = max(1, a.width - max(0, rightMarginPx))
        let columnStep = 4
        var frozen = 0
        var bandDarkest = 255
        var bandLightest = 0

        for row in stride(from: a.height - 1, through: 0, by: -1) {
            var sad: UInt64 = 0
            var samples = 0
            for column in stride(from: 0, to: lastColumn, by: columnStep) {
                guard let difference = pixelDifference(a, b, x: column, y: row) else { continue }
                sad += difference
                samples += 1
                let offset = row * a.bytesPerRow + column * 4
                let luminance = (Int(a.bytes[offset + a.redOffset]) * 77
                                 + Int(a.bytes[offset + a.greenOffset]) * 150
                                 + Int(a.bytes[offset + a.blueOffset]) * 29) >> 8
                bandDarkest = min(bandDarkest, luminance)
                bandLightest = max(bandLightest, luminance)
            }
            let average = samples > 0 ? sad / UInt64(samples) : UInt64.max
            guard average <= differenceThreshold else { break }
            frozen += 1
        }

        // A fixed footer often ends in one or more solid rows. Requiring detail
        // on every row stopped the scan at the first one; require it across the
        // whole band instead, so a white page margin still doesn't qualify.
        guard frozen > 0, bandLightest - bandDarkest >= minimumDetail else { return 0 }
        return frozen
    }

    /// True when two frames show the same pixels closely enough that waiting
    /// for the screen to settle can stop. The comparison is deliberately
    /// coarse: a blinking caret or a ticking clock must not keep a page
    /// "unsettled", while a video or an animated banner still does.
    static func framesAreStable(current: CGImage, previous: CGImage,
                                rightMarginPx: Int = 0,
                                tolerance: Double = 0.012) -> Bool {
        guard current.width == previous.width, current.height == previous.height,
              let a = frame(for: current), let b = frame(for: previous) else { return false }

        let columns = 24
        let rows = 24
        let usableWidth = max(1, a.width - max(0, rightMarginPx))
        var sad: UInt64 = 0
        var samples = 0

        for rowIndex in 0..<rows {
            let y = min(a.height - 1, (a.height * (2 * rowIndex + 1)) / (2 * rows))
            for columnIndex in 0..<columns {
                let x = min(usableWidth - 1, (usableWidth * (2 * columnIndex + 1)) / (2 * columns))
                guard let difference = pixelDifference(a, b, x: x, y: y) else { continue }
                sad += difference
                samples += 1
            }
        }
        guard samples > 0 else { return false }
        // Three channels per sample, 0...255 each.
        return Double(sad) / Double(samples * 3 * 255) <= tolerance
    }

    // MARK: - Vertical alignment

    /// A coarse per-row colour fingerprint: the mean luminance of a handful of
    /// evenly spaced columns in each horizontal band. Content scrolled by N rows
    /// produces the same fingerprint shifted by N rows, which is cheap to scan
    /// and — unlike whole-image registration — remains accurate for the small
    /// one- and two-pixel shifts produced by a slow trackpad scroll.
    struct RowSignature {
        let height: Int
        let bandCount: Int
        let values: [UInt8]

        func band(_ row: Int, _ band: Int) -> Int {
            Int(values[row * bandCount + band])
        }
    }

    struct VerticalAlignment {
        /// Rows the content moved up between the two frames. Fractional values
        /// are meaningful: callers accumulate them instead of rounding each
        /// step, which is what keeps a long capture from drifting by a row.
        let offset: Double
        /// Mean absolute luminance difference over the overlap, 0...1.
        let cost: Double
        let overlapRows: Int
        /// 0...1. Low confidence means repetitive content produced several
        /// equally good matches.
        let confidence: Double
    }

    /// Builds the row fingerprint used by `verticalAlignment`.
    static func signature(for image: CGImage, rightMarginPx: Int = 0) -> RowSignature? {
        guard let frame = frame(for: image) else { return nil }
        let usableWidth = max(1, frame.width - max(0, rightMarginPx))
        guard usableWidth >= 8, frame.height > 0 else { return nil }

        let bandCount = max(1, min(12, usableWidth / 8))
        let samplesPerBand = 4
        var values = [UInt8](repeating: 0, count: frame.height * bandCount)

        for row in 0..<frame.height {
            let rowBase = row * frame.bytesPerRow
            for band in 0..<bandCount {
                let start = band * usableWidth / bandCount
                let end = (band + 1) * usableWidth / bandCount
                let span = max(1, end - start)
                var total = 0
                for sample in 0..<samplesPerBand {
                    let x = min(usableWidth - 1, start + (span * (2 * sample + 1)) / (2 * samplesPerBand))
                    let offset = rowBase + x * 4
                    let luminance = (Int(frame.bytes[offset + frame.redOffset]) * 77
                                     + Int(frame.bytes[offset + frame.greenOffset]) * 150
                                     + Int(frame.bytes[offset + frame.blueOffset]) * 29) >> 8
                    total += luminance
                }
                values[row * bandCount + band] = UInt8(total / samplesPerBand)
            }
        }
        return RowSignature(height: frame.height, bandCount: bandCount, values: values)
    }

    /// Finds how far the content in `current` has scrolled relative to
    /// `previous`. Positive means the content moved up (the page scrolled down).
    ///
    /// `headerRows` and `footerRows` are fixed chrome and are excluded from both
    /// the search and the overlap check. `expectedOffset` is the previous
    /// accepted step: it breaks ties on repetitive pages (identical table rows,
    /// code lines) without forcing the result when the user changes speed.
    static func verticalAlignment(current: CGImage, previous: CGImage,
                                  headerRows: Int = 0, footerRows: Int = 0,
                                  rightMarginPx: Int = 0,
                                  expectedOffset: Double? = nil) -> VerticalAlignment? {
        guard current.width == previous.width, current.height == previous.height,
              let currentSignature = signature(for: current, rightMarginPx: rightMarginPx),
              let previousSignature = signature(for: previous, rightMarginPx: rightMarginPx) else {
            return nil
        }
        return verticalAlignment(current: currentSignature, previous: previousSignature,
                                 currentImage: current, previousImage: previous,
                                 headerRows: headerRows, footerRows: footerRows,
                                 rightMarginPx: rightMarginPx, expectedOffset: expectedOffset)
    }

    private static func verticalAlignment(current: RowSignature, previous: RowSignature,
                                          currentImage: CGImage, previousImage: CGImage,
                                          headerRows: Int, footerRows: Int,
                                          rightMarginPx: Int,
                                          expectedOffset: Double?) -> VerticalAlignment? {
        let height = current.height
        guard height == previous.height, current.bandCount == previous.bandCount else { return nil }

        let header = max(0, min(headerRows, height / 3))
        let footer = max(0, min(footerRows, height / 4))
        let contentHeight = height - header - footer
        guard contentHeight >= 24 else { return nil }

        // A match needs a meaningful slice of shared content. One eighth of the
        // viewport is enough for text; less than that is mostly noise.
        let minimumOverlap = max(24, contentHeight / 8)
        let maximumOffset = contentHeight - minimumOverlap
        guard maximumOffset >= 1 else { return nil }

        // Repetitive content cannot be registered from an empty page. Requiring
        // detail in the previous content area also stops a blank frame from
        // matching every possible offset at zero cost. A vertical gradient has
        // no horizontal detail but plenty of vertical structure, so accept
        // either kind.
        guard hasVerticalDetail(previous, rows: header..<(height - footer)) else { return nil }

        let rowStep = max(1, contentHeight / 120)

        func rawCost(_ offset: Int) -> Double? {
            guard offset >= 0, offset <= maximumOffset else { return nil }
            let overlap = contentHeight - offset
            guard overlap >= minimumOverlap else { return nil }

            var total = 0
            var count = 0
            var row = header
            let end = height - footer - offset
            while row < end {
                let currentBase = row * current.bandCount
                let previousBase = (row + offset) * previous.bandCount
                for band in 0..<current.bandCount {
                    total += abs(Int(current.values[currentBase + band]) - Int(previous.values[previousBase + band]))
                }
                count += current.bandCount
                row += rowStep
            }
            guard count > 0 else { return nil }
            return Double(total) / Double(count * 255)
        }

        // The minimum is one row wide: a 3-pixel coarse stride can step right
        // over it. The fingerprint is small enough to evaluate every offset.
        // Ranking penalises candidates that leave only a sliver of overlap,
        // which can otherwise match by chance.
        var rawCosts = [Double](repeating: .infinity, count: maximumOffset + 1)
        var rankCosts = [Double](repeating: .infinity, count: maximumOffset + 1)
        for candidate in 0...maximumOffset {
            guard let raw = rawCost(candidate) else { continue }
            rawCosts[candidate] = raw
            let missing = Double(candidate) / Double(contentHeight)
            rankCosts[candidate] = raw + 0.03 * missing * missing
        }

        var refinedOffset = 0
        var refinedRank = Double.infinity
        for candidate in 0...maximumOffset where rankCosts[candidate] < refinedRank {
            refinedRank = rankCosts[candidate]
            refinedOffset = candidate
        }
        guard refinedRank.isFinite else { return nil }

        // A sudden change of speed must not be overridden by the prior, so it
        // only wins when it explains the pixels nearly as well.
        if let expected = expectedOffset, expected.isFinite, expected > 0.25 {
            let candidate = Int(expected.rounded())
            if candidate >= 0, candidate <= maximumOffset, abs(candidate - refinedOffset) >= 2,
               rawCosts[candidate] <= rawCosts[refinedOffset] + 0.004 {
                refinedOffset = candidate
            }
        }

        var offset = Double(refinedOffset)

        // The band fingerprint can be flat on smooth gradients or large
        // images. A full-resolution spot check around the winner keeps a
        // one-pixel error from becoming a visible seam.
        var spotCost = verificationCost(current: currentImage, previous: previousImage,
                                        offset: refinedOffset, header: header, footer: footer,
                                        rightMarginPx: rightMarginPx)
        var spotOffset = refinedOffset
        for delta in -2...2 where delta != 0 {
            let candidate = refinedOffset + delta
            guard candidate >= 0, candidate <= maximumOffset else { continue }
            let cost = verificationCost(current: currentImage, previous: previousImage,
                                        offset: candidate, header: header, footer: footer,
                                        rightMarginPx: rightMarginPx)
            if cost < spotCost {
                spotCost = cost
                spotOffset = candidate
            }
        }
        refinedOffset = spotOffset

        if refinedOffset > 0, refinedOffset < maximumOffset {
            let below = rawCosts[refinedOffset - 1]
            let centre = rawCosts[refinedOffset]
            let above = rawCosts[refinedOffset + 1]
            if below.isFinite, centre.isFinite, above.isFinite {
                let denominator = below - 2 * centre + above
                if denominator > 1e-9 {
                    let delta = 0.5 * (below - above) / denominator
                    if delta.isFinite, abs(delta) <= 1 { offset += delta }
                }
            }
        }

        let refinedCost = rawCosts[refinedOffset]
        guard refinedCost.isFinite, refinedCost <= 0.045 else { return nil }

        let overlapRows = contentHeight - refinedOffset
        guard overlapRows >= minimumOverlap else { return nil }
        guard hasVerticalDetail(current, rows: header..<(height - footer - refinedOffset)) else { return nil }
        guard spotCost <= 0.08 else { return nil }

        // How much better the winner is than the best different offset. Equal
        // candidates mean the page repeats (or is blank) and the caller should
        // not trust the result blindly.
        var secondBest = Double.infinity
        for candidate in 0...maximumOffset where abs(candidate - refinedOffset) >= 4 {
            secondBest = min(secondBest, rawCosts[candidate])
        }
        let separation = secondBest.isFinite ? min(1, max(0, (secondBest - refinedCost) / 0.01)) : 1
        let quality = min(1, max(0, 1 - refinedCost / 0.045))
        let confidence = quality * (0.5 + 0.5 * separation)

        return VerticalAlignment(offset: offset, cost: refinedCost,
                                 overlapRows: overlapRows, confidence: confidence)
    }

    /// Average spread between bands in the given rows. Text and UI have
    /// structure; a solid fill does not.
    private static func signatureDetail(_ signature: RowSignature, rows: Range<Int>) -> Double {
        guard !rows.isEmpty, signature.bandCount > 1 else { return 0 }
        var total = 0
        var count = 0
        for row in rows where row >= 0 && row < signature.height {
            var darkest = 255
            var lightest = 0
            for band in 0..<signature.bandCount {
                let value = signature.band(row, band)
                darkest = min(darkest, value)
                lightest = max(lightest, value)
            }
            total += lightest - darkest
            count += 1
        }
        return count > 0 ? Double(total) / Double(count) : 0
    }

    /// Whether the rows contain anything a vertical matcher can lock onto:
    /// horizontal structure inside a row, or enough change down the rows. A
    /// solid fill has neither; a vertical gradient has only the latter.
    private static func hasVerticalDetail(_ signature: RowSignature, rows: Range<Int>) -> Bool {
        guard signature.bandCount > 0 else { return false }
        let lower = max(0, rows.lowerBound)
        let upper = min(signature.height, rows.upperBound)
        guard upper > lower else { return false }

        if signatureDetail(signature, rows: lower..<upper) >= 0.75 { return true }

        var total = 0
        var count = 0
        if upper - lower > 1 {
            for row in (lower + 1)..<upper {
                for band in 0..<signature.bandCount {
                    total += abs(signature.band(row, band) - signature.band(row - 1, band))
                }
                count += signature.bandCount
            }
        }
        guard count > 0 else { return false }
        return Double(total) / Double(count) * Double(upper - lower) >= 8
    }

    /// Full-resolution spot check over the overlap. The band fingerprint is
    /// deliberately small; this catches a fingerprint collision between two
    /// different rows that happen to have the same average colours.
    private static func verificationCost(current: CGImage, previous: CGImage,
                                         offset: Int, header: Int, footer: Int,
                                         rightMarginPx: Int) -> Double {
        guard let a = frame(for: current), let b = frame(for: previous) else { return 1 }
        let usableWidth = max(1, a.width - max(0, rightMarginPx))
        let rows = max(1, min(32, a.height - footer - offset - header))
        let columns = max(1, min(32, usableWidth))
        var sad: UInt64 = 0
        var samples = 0

        for rowIndex in 0..<rows {
            let span = a.height - footer - offset - header
            let y = header + (span * (2 * rowIndex + 1)) / (2 * rows)
            for columnIndex in 0..<columns {
                let x = (usableWidth * (2 * columnIndex + 1)) / (2 * columns)
                guard let difference = pixelDifference(a, b, ax: x, ay: y, bx: x, by: y + offset) else { continue }
                sad += difference
                samples += 1
            }
        }
        guard samples > 0 else { return 1 }
        return Double(sad) / Double(samples * 3 * 255)
    }
}
