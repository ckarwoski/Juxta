import XCTest
@testable import JuxtaCore

final class HorizontalRevealTests: XCTestCase {
    func testColumnsOfPlainLineAreOffsets() {
        XCTAssertEqual(HorizontalReveal.columns(ofOffsets: [0, 3, 11], in: "10.0.0.0/24"), [0, 3, 11])
        XCTAssertEqual(HorizontalReveal.columns(ofOffsets: [], in: "abc"), [])
    }

    func testColumnsCountTabsAndBadges() {
        // The tab runs to column 4; U+200B is drawn as a six-column badge.
        XCTAssertEqual(HorizontalReveal.columns(ofOffsets: [1, 2, 3], in: "a\tb"), [1, 4, 5])
        XCTAssertEqual(HorizontalReveal.columns(ofOffsets: [2, 3], in: "ab\u{200B}c"), [2, 8])
    }

    func testChangeOnScreenDoesNotScroll() {
        XCTAssertNil(HorizontalReveal.scrollX(toShow: 100..<107, visible: 0..<500, charWidth: 7))
        XCTAssertNil(HorizontalReveal.scrollX(toShow: 1000..<1007, visible: 900..<1400, charWidth: 7))
    }

    func testChangeOffScreenScrollsWithMargin() {
        // Sixteen columns of context, unless that is more than a third of the width.
        XCTAssertEqual(HorizontalReveal.scrollX(toShow: 300_000..<300_007, visible: 0..<600, charWidth: 7),
                       300_000 - 16 * 7)
        XCTAssertEqual(HorizontalReveal.scrollX(toShow: 50..<57, visible: 900..<1500, charWidth: 7), 0)
        XCTAssertEqual(HorizontalReveal.scrollX(toShow: 1000..<1007, visible: 0..<150, charWidth: 7), 950)
        // Partly visible counts as off screen.
        XCTAssertEqual(HorizontalReveal.scrollX(toShow: 495..<502, visible: 0..<500, charWidth: 7), 495 - 112)
    }
}
