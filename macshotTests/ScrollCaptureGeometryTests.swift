import CoreGraphics
import XCTest

/// ScreenCaptureKit takes a display-local, top-left rect. AppKit selections are
/// global, bottom-left. A mistake here captures the wrong band on secondary
/// displays or when the selection touches a screen edge.
final class ScrollCaptureGeometryTests: XCTestCase {

    func testPrimaryDisplaySelectionBecomesTopLeft() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let selection = CGRect(x: 100, y: 200, width: 400, height: 300)
        XCTAssertEqual(
            ScrollCaptureGeometry.displayLocalTopLeftRect(
                captureRect: selection, screenFrame: screen),
            CGRect(x: 100, y: 482, width: 400, height: 300))
    }

    func testSecondaryDisplayUsesItsOwnOriginAndHeight() {
        let screen = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let selection = CGRect(x: 1600, y: 100, width: 400, height: 300)
        XCTAssertEqual(
            ScrollCaptureGeometry.displayLocalTopLeftRect(
                captureRect: selection, screenFrame: screen),
            CGRect(x: 88, y: 680, width: 400, height: 300))
    }

    func testDisplayAboveThePrimaryUsesItsOwnOrigin() {
        let screen = CGRect(x: 0, y: 982, width: 1512, height: 982)
        let selection = CGRect(x: 100, y: 1100, width: 400, height: 300)
        XCTAssertEqual(
            ScrollCaptureGeometry.displayLocalTopLeftRect(
                captureRect: selection, screenFrame: screen),
            CGRect(x: 100, y: 564, width: 400, height: 300))
    }

    func testSelectionIsClampedToTheDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let selection = CGRect(x: 900, y: 700, width: 300, height: 300)
        XCTAssertEqual(
            ScrollCaptureGeometry.displayLocalTopLeftRect(
                captureRect: selection, screenFrame: screen),
            CGRect(x: 900, y: 0, width: 100, height: 100))
    }

    func testSelectionPartlyBelowTheDisplayIsClamped() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let selection = CGRect(x: 100, y: -100, width: 200, height: 300)
        XCTAssertEqual(
            ScrollCaptureGeometry.displayLocalTopLeftRect(
                captureRect: selection, screenFrame: screen),
            CGRect(x: 100, y: 600, width: 200, height: 200))
    }

    func testOffscreenAndDegenerateSelectionsReturnZero() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(
            ScrollCaptureGeometry.displayLocalTopLeftRect(
                captureRect: CGRect(x: 2000, y: 2000, width: 100, height: 100),
                screenFrame: screen),
            .zero)
        XCTAssertEqual(
            ScrollCaptureGeometry.displayLocalTopLeftRect(
                captureRect: CGRect(x: 10, y: 10, width: 0, height: 100),
                screenFrame: screen),
            .zero)
        XCTAssertEqual(
            ScrollCaptureGeometry.displayLocalTopLeftRect(
                captureRect: CGRect(x: 10, y: 10, width: 100, height: 100),
                screenFrame: .zero),
            .zero)
    }
}