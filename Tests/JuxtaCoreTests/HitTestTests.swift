import XCTest
@testable import JuxtaCore

final class HitTestTests: XCTestCase {
    func testASCIIOffsetRoundsToTheNearerEdge() {
        let offset = { (x: CGFloat) in HitTest.offset(atX: x, charWidth: 8, length: 10, rounding: .nearestEdge) }
        XCTAssertEqual(offset(0), 0)
        XCTAssertEqual(offset(3.9), 0)
        XCTAssertEqual(offset(4), 1) // halfway goes right
        XCTAssertEqual(offset(19), 2)
        XCTAssertEqual(offset(21), 3)
        // Left of the text, and past its end.
        XCTAssertEqual(offset(-30), 0)
        XCTAssertEqual(offset(79), 10)
        XCTAssertEqual(offset(500), 10)
    }

    func testASCIIOffsetOfTheCharacterUnder() {
        let offset = { (x: CGFloat) in HitTest.offset(atX: x, charWidth: 8, length: 10, rounding: .characterUnder) }
        XCTAssertEqual(offset(0), 0)
        XCTAssertEqual(offset(7.9), 0)
        XCTAssertEqual(offset(8), 1)
        XCTAssertEqual(offset(21), 2)
        XCTAssertEqual(offset(-1), 0)
        // Past the end is the end, which `Words` takes as the last character.
        XCTAssertEqual(offset(500), 10)
        XCTAssertEqual(HitTest.offset(atX: 5, charWidth: 0, length: 10, rounding: .nearestEdge), 0)
    }

    func testSourceOffsetInsideABadge() throws {
        // U+200B at line offset 6 is drawn as a six-column badge at 6..<12.
        let layout = try XCTUnwrap(Invisibles.layout("65001:\u{200B}100"))
        let edge = { HitTest.sourceOffset($0, in: layout, rounding: .nearestEdge) }
        let under = { HitTest.sourceOffset($0, in: layout, rounding: .characterUnder) }
        XCTAssertEqual([5, 6, 8, 10, 11, 12, 13].map(edge), [5, 6, 6, 7, 7, 7, 8])
        // Anywhere over the badge is the badged character, and after it the next one.
        XCTAssertEqual([5, 6, 8, 10, 11, 12, 13].map(under), [5, 6, 6, 6, 6, 7, 8])
    }

    func testSourceOffsetUnderWithSeveralBadges() throws {
        // a NUL b BEL c: three-column badges at 1..<4 and 5..<8.
        let layout = try XCTUnwrap(Invisibles.layout("a\u{0}b\u{7}c"))
        XCTAssertEqual((0...9).map { HitTest.sourceOffset($0, in: layout, rounding: .characterUnder) },
                       [0, 1, 1, 1, 2, 3, 3, 3, 4, 5])
    }
}
