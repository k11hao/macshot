import Cocoa
import ScreenCaptureKit

// MARK: - ScrollCaptureController

/// Scroll capture engine.
///
/// - **ScreenCaptureKit snapshots** (`SCScreenshotManager`) on macOS 14+ for
///   complete, cursor-free frames that exclude macshot's own overlay, HUD and
///   preview windows. The legacy window-list API remains as a fallback.
/// - **Row-signature alignment** (`ScrollFrameAnalyzer.verticalAlignment`)
///   measures the scroll offset. Whole-image Vision registration was accurate
///   for large jumps but returned garbage for the one- and two-pixel shifts a
///   slow trackpad produces, which is how captures ended up with missing or
///   duplicated lines.
/// - **Cumulative fractional offsets** — every step is added to a `Double`
///   position instead of being rounded and discarded, so a long capture does
///   not drift and a final sub-pixel step is still captured.
/// - **Incremental strips** (`ScrollStitcher`) — each frame contributes one
///   small strip; the result is composited once at the end instead of copying
///   the whole image after every scroll.
/// - **Frozen header and footer detection** — sticky chrome is excluded from
///   matching, and a fixed footer is removed from the first viewport and drawn
///   once at the bottom instead of being embedded mid-image.
/// - **Timed polling in manual mode** — captures continue even when no
///   scroll-wheel event arrives (keyboard paging, remote sessions).
/// - **Programmatic scrolling** via `CGEventCreateScrollWheelEvent2`.
/// - **Max height: 30,000 pixels** by default (configurable in Settings).
@MainActor
final class ScrollCaptureController {

    // MARK: - Public state

    private(set) var stripCount: Int = 0
    private(set) var stitchedImage: CGImage?
    private(set) var stitchedPixelSize: CGSize = .zero
    private(set) var isActive: Bool = false
    private(set) var frozenTopHeight: CGFloat = 0
    private var isCancelled: Bool = false

    /// Current estimated total height of the final image (points).
    var estimatedTotalHeight: CGFloat {
        guard let stitcher else { return 0 }
        return CGFloat(stitcher.height) / backingScale
    }

    // MARK: - Callbacks

    var onStripAdded:  ((Int) -> Void)?
    var onSessionDone: ((NSImage?) -> Void)?
    var onAutoScrollStarted: (() -> Void)?
    var onPreviewUpdated: ((NSImage) -> Void)?

    // MARK: - Config

    var excludedWindowIDs: [CGWindowID] = []

    // MARK: - Settings

    private var autoScrollEnabled: Bool = false
    private var autoScrollSpeed: Int = 3
    private var maxScrollHeight: Int = 30000
    private var frozenDetectionEnabled: Bool = true

    // MARK: - Private

    private let captureRect: NSRect
    private let screen: NSScreen
    private let backingScale: CGFloat

    // Frame state
    private var firstFrame: CGImage?
    private var lastFrame: CGImage?
    private var stitcher: ScrollStitcher?
    private var firstFrameHadFooter = false

    /// Absolute content row shown at the top of the current frame. Fractional,
    /// so slow scrolling accumulates instead of being rounded away.
    private var contentTop: Double = 0
    private var lastDelta: Double = 0
    private var didScroll = false
    private var alignmentFailures = 0
    private var didDeliver = false
    private var isFinalizing = false

    // Frozen chrome
    private var headerHeight: Int = 0
    private var footerHeight: Int = 0
    private var headerSamples: [Int] = []
    private var footerSamples: [Int] = []
    private var detectedPairs: Int = 0

    // Scrollbar exclusion
    private var rightMarginPx: Int = 0
    private var rightMarginDetected: Bool = false
    private var rightMarginAttempts: Int = 0

    // Match tracking
    private var matchNotFoundCount: Int = 0
    private let maxMatchNotFound: Int = 8  // stop after 8 consecutive empty scrolls

    // Scroll monitors (for manual scroll)
    private var scrollMonitorGlobal: Any?
    private var scrollMonitorLocal:  Any?

    // Auto-scroll
    private(set) var autoScrollActive: Bool = false
    private var autoScrollTask: Task<Void, Never>?

    // Manual scroll throttle
    private let manualCaptureInterval: TimeInterval = 0.10
    private var lastCaptureTime: TimeInterval = 0
    private var settlementTimer: Timer?
    private let settlementInterval: TimeInterval = 0.20

    /// Fallback polling while manual scroll capture is active. Scroll-wheel
    /// monitors miss keyboard paging and some remote/secure input, so a timer
    /// samples the screen at a fixed cadence the way Capso does.
    private var manualPollTimer: Timer?
    private let manualPollInterval: TimeInterval = 0.15

    // ScreenCaptureKit capture (macOS 14+). The legacy window-list API is kept
    // as a fallback for older systems and for transient SCK failures.
    private var sckFilter: SCContentFilter?
    private var sckConfiguration: SCStreamConfiguration?
    private var sckFailureCount = 0
    private var sckUnavailable = false
    private var sckSourceRect: CGRect = .zero
    private var sckDisplayID: CGDirectDisplayID = 0

    /// Magnitude of the scroll events seen since the last processed frame.
    /// It is only a tie-breaker for repetitive pages, where the pixel matcher
    /// sees several equally good offsets (identical table rows, code lines).
    private var scrollHintPixels: Double = 0

    // Guard: only one capture at a time
    private var isCapturing: Bool = false
    private var needsAnotherCapture = false

    // Preview throttle
    private var lastPreviewUpdate: TimeInterval = 0

    // Target app for scroll events
    private var targetAppPID: pid_t = 0

    // CGWindowList capture config
    private var targetWindowID: CGWindowID = kCGNullWindowID
    private var captureRectCG: CGRect = .zero  // CG coordinates (top-left origin)

    // MARK: - Init

    init(captureRect: NSRect, screen: NSScreen) {
        self.captureRect = captureRect
        self.screen      = screen
        self.backingScale = screen.backingScaleFactor
    }

    // MARK: - Session

    func startSession() async {
        guard !isActive, !isCancelled else { return }

        let ud = UserDefaults.standard
        autoScrollEnabled = ud.object(forKey: "scrollAutoScrollEnabled") as? Bool ?? false
        autoScrollSpeed = ud.object(forKey: "scrollAutoScrollSpeed") as? Int ?? 3
        maxScrollHeight = ud.object(forKey: "scrollMaxHeight") as? Int ?? 30000
        frozenDetectionEnabled = ud.object(forKey: "scrollFrozenDetection") as? Bool ?? true

        // Convert AppKit coords to CG coords (top-left origin) for CGWindowListCreateImage
        let primaryScreenH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        captureRectCG = CGRect(
            x: captureRect.origin.x,
            y: primaryScreenH - captureRect.maxY,
            width: captureRect.width,
            height: captureRect.height
        )

        // ScreenCaptureKit wants a display-local, top-left source rect. The
        // selection is global AppKit space, so move it into this screen first.
        sckDisplayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? CGDirectDisplayID ?? 0
        sckSourceRect = ScrollCaptureGeometry.displayLocalTopLeftRect(
            captureRect: captureRect, screenFrame: screen.frame)

        // Find the target window under the capture region
        resolveTargetWindow()
        resolveTargetApp()

        // Capture first settled frame
        guard let first = await captureSettledFrame() else {
            isActive = false
            if !isCancelled {
                didDeliver = true
                onSessionDone?(nil)
            }
            return
        }
        guard !isCancelled else { return }

        isActive = true
        firstFrame = first
        lastFrame = first
        contentTop = 0
        lastDelta = 0
        didScroll = false
        alignmentFailures = 0
        headerHeight = 0
        footerHeight = 0
        headerSamples = []
        footerSamples = []
        detectedPairs = 0
        rightMarginPx = 0
        rightMarginDetected = false
        rightMarginAttempts = 0
        matchNotFoundCount = 0
        firstFrameHadFooter = false
        frozenTopHeight = 0
        stripCount = 1

        guard let stitcher = ScrollStitcher(firstFrame: first, maximumHeight: maxScrollHeight) else {
            isActive = false
            didDeliver = true
            onSessionDone?(nil)
            return
        }
        self.stitcher = stitcher

        stitchedImage = first
        stitchedPixelSize = CGSize(width: CGFloat(first.width), height: CGFloat(first.height))
        emitPreview(force: true)
        onStripAdded?(stripCount)

        if autoScrollEnabled {
            startAutoScroll()
        } else {
            startManualScrollMonitors()
        }
    }

    func stopSession() {
        // The HUD (and its Stop button) is on screen before `isActive` becomes
        // true — startSession first awaits a settled frame. A stop in that
        // window used to do nothing at all, and the session then installed its
        // scroll monitors anyway.
        guard !didDeliver, !isFinalizing else { return }
        guard isActive || !isCancelled else { return }
        guard isActive else {
            isCancelled = true
            didDeliver = true
            onSessionDone?(nil)
            return
        }

        isActive = false
        stopAutoScroll()
        settlementTimer?.invalidate(); settlementTimer = nil
        removeScrollMonitors()
        isFinalizing = true

        // One last settled frame catches the final partial scroll that arrived
        // after the previous capture. Delivery happens after it.
        Task { await finalizeSession() }
    }

    func cancelSession() {
        // Cancellation is also valid while the initial settled frame is being
        // captured, before `isActive` becomes true. The cancelled flag keeps
        // that asynchronous startup from installing monitors after the UI has
        // already been dismissed.
        isCancelled = true
        isActive = false
        didDeliver = true

        stopAutoScroll()
        settlementTimer?.invalidate(); settlementTimer = nil
        removeScrollMonitors()
    }

    private func removeScrollMonitors() {
        manualPollTimer?.invalidate(); manualPollTimer = nil
        if let monitor = scrollMonitorGlobal { NSEvent.removeMonitor(monitor); scrollMonitorGlobal = nil }
        if let monitor = scrollMonitorLocal  { NSEvent.removeMonitor(monitor); scrollMonitorLocal  = nil }
    }

    private func finalizeSession() async {
        defer { isFinalizing = false }

        if !isCancelled {
            if let frame = await captureSettledFrame() {
                _ = processFrame(frame, allowInactive: true)
            }
            appendFixedFooter()
        }

        guard !isCancelled, !didDeliver else { return }
        didDeliver = true

        let finalImage: NSImage?
        if let stitcher, let cg = stitcher.snapshot() {
            stitchedImage = cg
            stitchedPixelSize = CGSize(width: CGFloat(cg.width), height: CGFloat(cg.height))
            finalImage = NSImage(cgImage: cg, size: CGSize(width: CGFloat(cg.width) / backingScale,
                                                          height: CGFloat(cg.height) / backingScale))
        } else {
            finalImage = nil
        }
        onSessionDone?(finalImage)
    }

    /// A fixed footer belongs once at the bottom, not in the middle of the
    /// long image. It was removed from the first viewport before stitching, so
    /// add the last frame's copy now.
    private func appendFixedFooter() {
        guard didScroll, footerHeight > 0, let frame = lastFrame, let stitcher else { return }
        let start = frame.height - footerHeight
        guard start >= 0 else { return }
        _ = stitcher.append(frame, newRows: footerHeight, sourceStartRow: start, overlapRows: 0)
        stitchedPixelSize = CGSize(width: CGFloat(stitcher.width), height: CGFloat(stitcher.height))
    }

    // MARK: - Target window/app management

    /// Finds the window ID under the capture region center for targeted capture.
    private func resolveTargetWindow() {
        let centerX = captureRectCG.midX
        let centerY = captureRectCG.midY

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let excluded = Set(excludedWindowIDs)
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let winID = info[kCGWindowNumber as String] as? Int,
                  !excluded.contains(CGWindowID(winID))
            else { continue }

            let x = boundsDict["X"] ?? 0
            let y = boundsDict["Y"] ?? 0
            let w = boundsDict["Width"] ?? 0
            let h = boundsDict["Height"] ?? 0
            let cgRect = CGRect(x: x, y: y, width: w, height: h)

            if cgRect.contains(CGPoint(x: centerX, y: centerY)) {
                targetWindowID = CGWindowID(winID)
                return
            }
        }
    }

    private func resolveTargetApp() {
        let centerX = captureRectCG.midX
        let centerY = captureRectCG.midY

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let excluded = Set(excludedWindowIDs)
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let winID = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  !excluded.contains(CGWindowID(winID))
            else { continue }

            let x = boundsDict["X"] ?? 0
            let y = boundsDict["Y"] ?? 0
            let w = boundsDict["Width"] ?? 0
            let h = boundsDict["Height"] ?? 0
            let cgRect = CGRect(x: x, y: y, width: w, height: h)

            if cgRect.contains(CGPoint(x: centerX, y: centerY)) {
                targetAppPID = pid
                return
            }
        }
    }

    private func activateTargetApp() {
        guard targetAppPID != 0 else { return }
        NSRunningApplication(processIdentifier: targetAppPID)?.activate(options: [])
    }

    // MARK: - Frame capture

    /// One complete frame of the selected region.
    ///
    /// ScreenCaptureKit is the supported path on macOS 14+: it returns a
    /// compositor-finished image, never paints the cursor, and can exclude
    /// macshot's own overlay/HUD/preview windows. The legacy window-list API
    /// remains as a fallback for macOS 12–13 and for transient SCK failures.
    private func captureFrameAsync(allowLegacyFallback: Bool = false) async -> CGImage? {
        if #available(macOS 14.0, *), !sckUnavailable {
            if let image = await captureFrameSCK() { return image }
            // During a session, skip this frame and let the next poll retry
            // SCK instead of mixing capture paths with possibly different
            // pixel rounding. The initial/final reference may fall back.
            if !allowLegacyFallback { return nil }
        }
        return captureFrameLegacy()
    }

    @available(macOS 14.0, *)
    private func captureFrameSCK() async -> CGImage? {
        if sckFilter == nil {
            await rebuildSCKFilter()
        }
        guard let filter = sckFilter, let configuration = sckConfiguration else { return nil }

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)
            sckFailureCount = 0
            return image
        } catch {
            // The window list can change while the session runs. Drop the
            // cached filter and let the next frame rebuild it; after three
            // failures stay on the legacy path for the rest of the session.
            sckFailureCount += 1
            sckFilter = nil
            sckConfiguration = nil
            if sckFailureCount >= 3 { sckUnavailable = true }
            return nil
        }
    }

    @available(macOS 14.0, *)
    private func rebuildSCKFilter() async {
        guard sckDisplayID != 0,
              sckSourceRect.width >= 1, sckSourceRect.height >= 1 else { return }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == sckDisplayID })
        else { return }

        // Exclude every macshot window (selection overlay, HUD, live preview)
        // plus the system chrome that can overlap a full-height selection.
        let excludedBundleIDs: Set<String> = [
            Bundle.main.bundleIdentifier ?? "",
            "com.apple.dock",
            "com.apple.controlcenter",
            "com.apple.notificationcenterui",
            "com.apple.Spotlight",
        ]
        let excludedWindows = content.windows.filter { window in
            guard let bundleID = window.owningApplication?.bundleIdentifier else { return false }
            return excludedBundleIDs.contains(bundleID)
        }

        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sckSourceRect
        // The filter knows the point→pixel scale for this display; on scaled
        // resolutions it can differ from NSScreen.backingScaleFactor.
        let pixelScale = max(1, CGFloat(filter.pointPixelScale))
        configuration.width = max(1, Int((sckSourceRect.width * pixelScale).rounded()))
        configuration.height = max(1, Int((sckSourceRect.height * pixelScale).rounded()))
        configuration.showsCursor = false
        configuration.captureResolution = .best

        sckFilter = filter
        sckConfiguration = configuration
    }

    /// Legacy capture via CGWindowListCreateImage. Still used on macOS 12–13
    /// and as a fallback when SCK cannot produce a frame.
    private func captureFrameLegacy() -> CGImage? {
        let excludeSet = Set(excludedWindowIDs)
        let listOption: CGWindowListOption = excludeSet.isEmpty
            ? [.optionOnScreenOnly]
            : [.optionOnScreenBelowWindow]
        let windowID = excludeSet.first ?? kCGNullWindowID

        let imageOption: CGWindowImageOption = [.boundsIgnoreFraming]

        guard let image = CGWindowListCreateImage(
            captureRectCG, listOption, windowID, imageOption
        ) else { return nil }

        return image
    }

    /// Captures the initial/final reference frame.
    ///
    /// ScreenCaptureKit snapshots are already compositor-finished, so the old
    /// TIFF/sample settle loop is unnecessary there; two frames 20ms apart keep
    /// a scroll animation's first frame from becoming the reference. The legacy
    /// window-list path still polls until two coarse samples agree.
    private func captureSettledFrame() async -> CGImage? {
        if #available(macOS 14.0, *), !sckUnavailable {
            guard let first = await captureFrameAsync(allowLegacyFallback: true) else { return nil }
            try? await Task.sleep(nanoseconds: 20_000_000)
            return await captureFrameAsync(allowLegacyFallback: true) ?? first
        }

        var previous: CGImage?
        var last: CGImage?
        var waitNs: UInt64 = 10_000_000  // 10ms

        for _ in 0..<8 {
            guard !isCancelled else { return nil }
            guard let frame = await captureFrameAsync(allowLegacyFallback: true) else {
                try? await Task.sleep(nanoseconds: 30_000_000)
                continue
            }
            last = frame

            if let previous, ScrollFrameAnalyzer.framesAreStable(
                current: frame, previous: previous, rightMarginPx: rightMarginPx) {
                return frame
            }

            previous = frame
            try? await Task.sleep(nanoseconds: waitNs)
            waitNs = min(waitNs * 3 / 2, 40_000_000)
        }
        return last
    }

    // MARK: - Auto-scroll

    private func startAutoScroll() {
        autoScrollActive = true
        onAutoScrollStarted?()

        let primaryScreenH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cursorX = captureRect.midX
        let cursorY = primaryScreenH - captureRect.midY
        CGWarpMouseCursorPosition(CGPoint(x: cursorX, y: cursorY))

        activateTargetApp()

        let linesPerTick: Int32
        switch autoScrollSpeed {
        case 1: linesPerTick = 1
        case 2: linesPerTick = 1
        case 4: linesPerTick = 2
        default: linesPerTick = 1
        }

        let burstCount: Int
        switch autoScrollSpeed {
        case 1: burstCount = 1
        case 2: burstCount = 2
        case 4: burstCount = 4
        default: burstCount = 3
        }

        autoScrollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self = self, self.isActive, self.autoScrollActive else { return }
            await self.autoScrollLoop(linesPerTick: linesPerTick, burstCount: burstCount)
        }
    }

    /// Core auto-scroll loop: scroll → captureAndCompare → repeat.
    private func autoScrollLoop(linesPerTick: Int32, burstCount: Int) async {
        while isActive && autoScrollActive {
            // Post scroll event(s)
            for _ in 0..<burstCount {
                if let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                       wheel1: -linesPerTick, wheel2: 0, wheel3: 0) {
                    event.post(tap: .cghidEventTap)
                }
            }

            // `isCapturing` serializes this against a manual settledCapture
            // that may still be running — both mutate frame state around their
            // suspension points.
            if isCapturing {
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            // A rough expected step helps on repetitive pages. The pixel match
            // still has to agree before it is used.
            scrollHintPixels = Double(burstCount * Int(linesPerTick)) * 20 * Double(backingScale)
            isCapturing = true
            let appended = await captureAndCompare()
            isCapturing = false

            if appended {
                matchNotFoundCount = 0
            } else {
                matchNotFoundCount += 1
                if matchNotFoundCount >= maxMatchNotFound {
                    stopSession()
                    return
                }
            }

            // Check max height (pixels)
            if maxScrollHeight > 0, let stitcher, stitcher.height >= maxScrollHeight {
                stopSession()
                return
            }

            // Small breathing room
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Captures one frame and merges whatever new content it contains.
    private func captureAndCompare() async -> Bool {
        // Initial delay for the scroll animation to begin.
        try? await Task.sleep(nanoseconds: 40_000_000)
        guard !isCancelled else { return false }
        guard let frame = await captureFrameAsync() else { return false }
        return processFrame(frame)
    }

    // MARK: - Alignment and stitching

    /// Measures how far `frame` has scrolled since the last accepted frame and
    /// appends only the rows that extend the stitched image.
    @discardableResult
    private func processFrame(_ frame: CGImage, allowInactive: Bool = false) -> Bool {
        guard allowInactive || isActive, !isCancelled else { return false }
        guard stitcher != nil else { return false }
        guard let previous = lastFrame else {
            lastFrame = frame
            return false
        }

        // A transient SCK failure falls back to the legacy capture path for
        // one frame. If the two paths round the Retina size differently, start
        // a fresh reference rather than feeding mismatched images to the
        // stitcher.
        if frame.width != previous.width || frame.height != previous.height {
            lastFrame = frame
            return false
        }

        // Manual mode polls on a timer now, so most frames are identical to
        // the previous one. A coarse check keeps idle polling nearly free; a
        // sub-pixel shift stays below the tolerance and accumulates on the
        // next frames instead of being thrown away.
        if ScrollFrameAnalyzer.framesAreStable(current: frame, previous: previous,
                                               rightMarginPx: rightMarginPx,
                                               tolerance: 0.0008) {
            return false
        }

        let expectedStep: Double? = lastDelta > 0.25
            ? lastDelta
            : (scrollHintPixels > 1 ? scrollHintPixels : nil)

        // Measure first, then use a real scroll step to decide whether fixed chrome
        // should be sampled. Detection before any movement would just count
        // idle frames and exhaust its window.
        var alignment = ScrollFrameAnalyzer.verticalAlignment(
            current: frame, previous: previous,
            headerRows: headerHeight, footerRows: footerHeight,
            rightMarginPx: rightMarginPx,
            expectedOffset: expectedStep
        )

        if frozenDetectionEnabled {
            let moved = (alignment?.offset ?? 0) >= 0.5
            let changedButUnregistered = alignment == nil
                && !ScrollFrameAnalyzer.framesAreStable(current: frame, previous: previous,
                                                        rightMarginPx: rightMarginPx,
                                                        tolerance: 0.002)
            if moved || changedButUnregistered,
               detectedPairs < 3 || detectedPairs % 12 == 0 {
                let oldHeader = headerHeight
                let oldFooter = footerHeight
                detectFrozenRegions(current: frame, previous: previous)
                if headerHeight != oldHeader || footerHeight != oldFooter {
                    alignment = ScrollFrameAnalyzer.verticalAlignment(
                        current: frame, previous: previous,
                        headerRows: headerHeight, footerRows: footerHeight,
                        rightMarginPx: rightMarginPx,
                        expectedOffset: expectedStep
                    ) ?? alignment
                }
            }
        }

        guard let alignment else {
            alignmentFailures += 1
            if alignmentFailures >= 3 {
                // No overlap (a very fast flick) or too much animation to
                // register. Resume from this frame so the next scroll can be
                // captured; the skipped band cannot be reconstructed.
                lastFrame = frame
                lastDelta = 0
                scrollHintPixels = 0
                alignmentFailures = 0
            }
            return false
        }

        alignmentFailures = 0

        guard alignment.confidence >= 0.25 else {
            // Repetitive or noisy content produced several equally good
            // matches. Keep the previous reference so the next frame can
            // resolve the ambiguity; resuming from here would silently skip
            // the rows we could not place.
            return false
        }

        if alignment.offset < 0.05 {
            // Keep the reference frame: a sub-pixel step must accumulate
            // across polls, or very slow scrolling is never captured.
            return false
        }

        contentTop = max(0, contentTop + alignment.offset)
        lastDelta = alignment.offset
        scrollHintPixels = 0
        lastFrame = frame
        didScroll = true

        // A fixed footer sits at the bottom of the first viewport. Remove it
        // from the first strip once it is known, before any append.
        if footerHeight > 0, stitcher?.stripCount == 1, !firstFrameHadFooter {
            rebuildFirstStripWithoutFooter()
        }
        guard let stitcher else { return false }

        let contentHeight = Double(frame.height - footerHeight)
        let targetBottom = contentTop + contentHeight
        let newRows = Int(targetBottom.rounded()) - stitcher.height
        guard newRows > 0 else { return false }

        // The new content is the bottom of the scrolling area. Never take the
        // fixed footer with it.
        let available = frame.height - footerHeight - headerHeight
        let rowsToAppend = min(newRows, available)
        guard rowsToAppend > 0 else { return false }
        let sourceStart = frame.height - footerHeight - rowsToAppend
        // Never let the one-row seam overlap reach into the fixed header.
        let overlapRows = sourceStart > headerHeight ? 1 : 0

        guard stitcher.append(frame, newRows: rowsToAppend,
                              sourceStartRow: sourceStart, overlapRows: overlapRows) else {
            if stitcher.reachedLimit { stopSession() }
            return false
        }

        stripCount += 1
        stitchedImage = nil
        stitchedPixelSize = CGSize(width: CGFloat(stitcher.width), height: CGFloat(stitcher.height))
        emitPreview()
        onStripAdded?(stripCount)
        return true
    }

    private func rebuildFirstStripWithoutFooter() {
        guard let first = firstFrame, let old = stitcher, old.stripCount == 1 else { return }
        let rows = first.height - footerHeight
        guard rows > 0,
              let cropped = first.cropping(to: CGRect(x: 0, y: 0, width: first.width, height: rows)),
              let rebuilt = ScrollStitcher(firstFrame: cropped, maximumHeight: maxScrollHeight) else { return }
        stitcher = rebuilt
        firstFrameHadFooter = true
        stitchedPixelSize = CGSize(width: CGFloat(rebuilt.width), height: CGFloat(rebuilt.height))
    }

    // MARK: - Manual scroll

    private func startManualScrollMonitors() {
        scrollMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.onManualScrollEvent(event)
        }
        scrollMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.onManualScrollEvent(event)
            return event
        }
        startManualPollTimer()
    }

    /// Samples the screen even when no scroll-wheel event arrives. Keyboard
    /// paging, remote sessions and apps that consume scroll events still get
    /// captured; identical frames are rejected cheaply by `processFrame`.
    private func startManualPollTimer() {
        manualPollTimer?.invalidate()
        let timer = Timer(timeInterval: manualPollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isActive, !self.isCancelled else { return }
                self.grabAndProcess()
            }
        }
        // .common keeps the timer alive while the user is in a tracking loop.
        RunLoop.main.add(timer, forMode: .common)
        manualPollTimer = timer
    }

    private func onManualScrollEvent(_ event: NSEvent) {
        guard isActive else { return }

        // Track the user's own scroll amount as a hint for ambiguous pages.
        // Precise deltas are in points; a line-based wheel notch is roughly
        // 20 points of content.
        let unit = event.hasPreciseScrollingDeltas ? 1.0 : 20.0
        scrollHintPixels += abs(Double(event.scrollingDeltaY)) * unit * Double(backingScale)

        // After scrolling stops, do a final settled capture. This also picks
        // up the last small step that arrived between throttled grabs.
        settlementTimer?.invalidate()
        settlementTimer = Timer.scheduledTimer(withTimeInterval: settlementInterval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in await self.settledCapture() }
        }

        // During scrolling, grab frames at a fixed interval. No settlement
        // wait here: the content must be sampled before it moves out of view.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastCaptureTime >= manualCaptureInterval else {
            needsAnotherCapture = true
            return
        }
        lastCaptureTime = now
        grabAndProcess()
    }

    /// Immediate frame grab + process during active scrolling.
    ///
    /// The capture itself is async (SCK), so scroll events that arrive while a
    /// frame is in flight set `needsAnotherCapture` and are coalesced into the
    /// next loop turn instead of being dropped.
    private func grabAndProcess() {
        guard isActive, !isCancelled else { return }
        guard !isCapturing else {
            needsAnotherCapture = true
            return
        }
        isCapturing = true

        Task { @MainActor in
            while self.isActive, !self.isCancelled {
                self.needsAnotherCapture = false
                if let frame = await self.captureFrameAsync() {
                    _ = self.processFrame(frame)
                } else {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                if !self.needsAnotherCapture { break }
            }

            self.isCapturing = false
            if self.needsAnotherCapture, self.isActive, !self.isCancelled {
                self.grabAndProcess()
            }
        }
    }

    /// Final settled capture after scrolling stops.
    private func settledCapture() async {
        guard isActive, !isCapturing else { return }
        isCapturing = true
        let _ = await captureAndCompare()
        isCapturing = false

        if needsAnotherCapture, isActive {
            needsAnotherCapture = false
            grabAndProcess()
        }
    }

    private func stopAutoScroll() {
        autoScrollActive = false
        autoScrollTask?.cancel(); autoScrollTask = nil
    }

    func toggleAutoScroll() {
        if autoScrollActive {
            stopAutoScroll()
            startManualScrollMonitors()
        } else {
            removeScrollMonitors()
            settlementTimer?.invalidate(); settlementTimer = nil
            startAutoScroll()
        }
    }

    // MARK: - Frozen header/footer detection

    /// Samples fixed chrome from the first few scroll pairs, then occasionally
    /// afterwards so a page whose toolbar appears later is still handled.
    private func detectFrozenRegions(current: CGImage, previous: CGImage) {
        let pair = detectedPairs
        detectedPairs += 1
        guard pair < 3 || pair % 12 == 0 else { return }

        // Scrollbar first: a moving thumb otherwise looks like a changed row
        // and makes the header detection stop at row zero.
        if !rightMarginDetected || rightMarginPx == 0 {
            rightMarginAttempts += 1
            if let width = ScrollFrameAnalyzer.scrollbarWidth(current: current, previous: previous) {
                if width >= 3 && width <= 40 {
                    rightMarginPx = width + 4
                    rightMarginDetected = true
                } else if rightMarginAttempts >= 3 {
                    rightMarginDetected = true
                }
            }
        }

        if let rows = ScrollFrameAnalyzer.frozenTopRows(
            current: current, previous: previous, rightMarginPx: rightMarginPx),
           rows < current.height {
            headerSamples.append(min(rows, current.height / 3))
            if headerSamples.count > 5 { headerSamples.removeFirst() }
            if let median = median(headerSamples) {
                headerHeight = median >= 8 ? median : 0
                frozenTopHeight = CGFloat(headerHeight) / backingScale
            }
        }

        if let rows = ScrollFrameAnalyzer.frozenBottomRows(
            current: current, previous: previous, rightMarginPx: rightMarginPx),
           rows < current.height {
            footerSamples.append(min(rows, current.height / 4))
            if footerSamples.count > 5 { footerSamples.removeFirst() }
            if let median = median(footerSamples) {
                let candidate = median >= 8 ? median : 0
                // Freeze the footer once content has been appended. Changing
                // it later would shift the content-bottom mapping of strips
                // that are already in the image.
                if (stitcher?.stripCount ?? 0) <= 1, candidate > 0 {
                    footerHeight = candidate
                }
                // A footer that appears to vanish is kept: dropping rows now
                // would change how the existing strips line up.
            }
        }
    }

    private func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    // MARK: - Preview

    private func emitPreview(force: Bool = false) {
        guard let stitcher, let callback = onPreviewUpdated else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastPreviewUpdate >= 0.25 else { return }
        lastPreviewUpdate = now
        guard let preview = stitcher.preview(maxWidth: 400, maxHeight: 1200) else { return }
        let pointSize = CGSize(width: CGFloat(preview.width) / backingScale,
                               height: CGFloat(preview.height) / backingScale)
        callback(NSImage(cgImage: preview, size: pointSize))
    }
}