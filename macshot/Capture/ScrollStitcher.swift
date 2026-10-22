import CoreGraphics
import Foundation

/// Accumulates scroll-capture frames into one long image.
///
/// The previous implementation redrew the whole accumulated image after every
/// strip. That is quadratic in the number of strips: a 30,000 px capture with
/// 100 strips copies gigabytes of pixels, stalls the capture loop, and makes it
/// drop frames exactly when the page is moving. Here each strip is copied once
/// into a small image, and the final result is composited once when the session
/// ends. Peak memory is the result plus the strips, not the result squared.
final class ScrollStitcher {

    private struct Strip {
        let image: CGImage
        let rows: Int
        /// Rows at the top of this strip that repeat the bottom of the previous
        /// one. They are drawn over the seam so a one-row alignment error
        /// cannot leave a duplicated or missing line.
        let overlap: Int
    }

    private(set) var width: Int
    private(set) var height: Int
    /// True when an append was refused because the configured maximum height
    /// was reached.
    private(set) var reachedLimit = false
    var stripCount: Int { strips.count }

    private let colorSpace: CGColorSpace
    private let maximumHeight: Int
    private var strips: [Strip] = []

    init?(firstFrame: CGImage, maximumHeight: Int) {
        guard firstFrame.width > 0, firstFrame.height > 0 else { return nil }
        width = firstFrame.width
        height = firstFrame.height
        colorSpace = firstFrame.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        // 0 means "no user limit"; still keep the arithmetic bounded.
        self.maximumHeight = maximumHeight > 0
            ? max(maximumHeight, firstFrame.height)
            : Int.max - 1
        strips = [Strip(image: firstFrame, rows: firstFrame.height, overlap: 0)]
    }

    /// Appends `newRows` content rows taken from the bottom of `frame`.
    ///
    /// `sourceStartRow` is the first row in `frame` that is new. `overlapRows`
    /// extra rows above it are included and drawn over the existing tail.
    @discardableResult
    func append(_ frame: CGImage, newRows: Int, sourceStartRow: Int, overlapRows: Int = 1) -> Bool {
        guard newRows > 0, frame.width == width, frame.height > 0 else { return false }
        guard height <= maximumHeight - newRows else {
            reachedLimit = true
            return false
        }

        let overlap = min(max(0, overlapRows), height, max(0, sourceStartRow), newRows)
        let rows = newRows + overlap
        let start = sourceStartRow - overlap
        guard start >= 0, rows > 0, start <= frame.height - rows else { return false }

        guard let crop = frame.cropping(to: CGRect(x: 0, y: start, width: width, height: rows)),
              let copy = Self.copy(crop, colorSpace: colorSpace) else { return false }

        strips.append(Strip(image: copy, rows: rows, overlap: overlap))
        height += newRows
        return true
    }

    /// Composites the accumulated strips into one image of exactly `height`
    /// rows. Called once when the session finishes.
    func snapshot() -> CGImage? {
        guard height > 0, !strips.isEmpty else { return nil }
        guard let context = makeContext(width: width, height: height) else { return nil }

        var row = 0
        for strip in strips {
            let top = row - strip.overlap
            guard top >= 0, top + strip.rows <= height else { continue }
            context.draw(strip.image, in: CGRect(x: 0, y: height - (top + strip.rows),
                                                 width: width, height: strip.rows))
            row += strip.rows - strip.overlap
        }
        return context.makeImage()
    }

    /// A small composite for the live preview. Drawing the strips at preview
    /// scale avoids copying the full-resolution result on every update.
    func preview(maxWidth: Int, maxHeight: Int) -> CGImage? {
        guard height > 0, !strips.isEmpty, maxWidth > 0, maxHeight > 0 else { return nil }
        let scale = min(1, min(Double(maxWidth) / Double(width), Double(maxHeight) / Double(height)))
        let previewWidth = max(1, Int((Double(width) * scale).rounded()))
        let previewHeight = max(1, Int((Double(height) * scale).rounded()))
        guard let context = makeContext(width: previewWidth, height: previewHeight) else { return nil }
        context.interpolationQuality = .medium

        var row = 0
        for strip in strips {
            let top = row - strip.overlap
            let bottom = top + strip.rows
            let y = Double(previewHeight) - Double(bottom) * scale
            let stripHeight = max(0.5, Double(strip.rows) * scale)
            context.draw(strip.image, in: CGRect(x: 0, y: y,
                                                 width: Double(previewWidth), height: stripHeight))
            row = bottom - strip.overlap
        }
        return context.makeImage()
    }

    // MARK: - Private

    private func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// Cropping a CGImage keeps its backing buffer alive. Copy the new rows so
    /// a one-strip capture does not retain the entire frame it came from.
    private static func copy(_ image: CGImage, colorSpace: CGColorSpace) -> CGImage? {
        guard image.width > 0, image.height > 0,
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}