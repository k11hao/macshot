import CoreGraphics

/// Coordinate conversions for scroll capture.
///
/// AppKit selection rects are global, bottom-left origin. ScreenCaptureKit's
/// `SCStreamConfiguration.sourceRect` is display-local, top-left origin. On a
/// secondary display the two differ by both the screen origin and the screen
/// height, so doing this inline is easy to get subtly wrong.
enum ScrollCaptureGeometry {

    /// Converts a global AppKit rect to the display-local, top-left rect that
    /// ScreenCaptureKit expects. The result is clamped to the display.
    static func displayLocalTopLeftRect(captureRect: CGRect,
                                        screenFrame: CGRect) -> CGRect {
        guard captureRect.width > 0, captureRect.height > 0,
              screenFrame.width > 0, screenFrame.height > 0 else { return .zero }

        let local = CGRect(
            x: captureRect.minX - screenFrame.minX,
            y: captureRect.minY - screenFrame.minY,
            width: captureRect.width,
            height: captureRect.height
        )
        let clamped = local.intersection(
            CGRect(origin: .zero, size: screenFrame.size))
        guard !clamped.isEmpty else { return .zero }

        return CGRect(
            x: clamped.minX,
            y: screenFrame.height - clamped.maxY,
            width: clamped.width,
            height: clamped.height
        )
    }
}