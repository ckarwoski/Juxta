import XCTest
@testable import JuxtaCore

final class InvisiblesTests: XCTestCase {
    func testPlainLineHasNothingToMark() {
        XCTAssertNil(Invisibles.layout("interface Gi0/0/1"))
        XCTAssertNil(Invisibles.layout(" description core"))
        XCTAssertNil(Invisibles.layout(""))
    }

    func testBadgeLabels() {
        XCTAssertEqual(Invisibles.badgeLabel("\u{0}"), "NUL")
        XCTAssertEqual(Invisibles.badgeLabel("\u{1B}"), "ESC")
        XCTAssertEqual(Invisibles.badgeLabel("\u{7F}"), "DEL")
        XCTAssertEqual(Invisibles.badgeLabel("\u{85}"), "U+0085")
        XCTAssertEqual(Invisibles.badgeLabel("\u{200B}"), "U+200B")
        XCTAssertEqual(Invisibles.badgeLabel("\u{2060}"), "U+2060")
        XCTAssertEqual(Invisibles.badgeLabel("\u{FEFF}"), "U+FEFF")
        XCTAssertEqual(Invisibles.badgeLabel("\u{AD}"), "U+00AD")
        for scalar: Unicode.Scalar in ["\t", " ", "a", "\u{A0}", "é", "\u{301}"] {
            XCTAssertNil(Invisibles.badgeLabel(scalar), "\(scalar.value)")
        }
    }

    func testUnusualSpaces() {
        for scalar: Unicode.Scalar in ["\u{A0}", "\u{2000}", "\u{200A}", "\u{202F}", "\u{3000}"] {
            XCTAssertTrue(Invisibles.isUnusualSpace(scalar))
        }
        XCTAssertFalse(Invisibles.isUnusualSpace(" "))
        XCTAssertFalse(Invisibles.isUnusualSpace("\u{200B}"))
    }

    func testBadgeReplacesCharacterWithLabelWidthAndShiftsOffsets() throws {
        let line = "65001:\u{200B}100"
        let layout = try XCTUnwrap(Invisibles.layout(line))
        XCTAssertEqual(layout.display, "65001:      100")
        XCTAssertEqual(layout.markers, [.init(kind: .badge("U+200B"), range: 6..<12, trailing: false)])
        XCTAssertNil(layout.trailingStart)
        XCTAssertEqual(layout.displayOffset(6), 6) // before the badge
        XCTAssertEqual(layout.displayOffset(7), 12) // after it
        XCTAssertEqual(layout.displayOffset(10), 15) // end of line
    }

    func testOffsetsAfterSeveralBadges() throws {
        let layout = try XCTUnwrap(Invisibles.layout("a\u{0}b\u{7}c"))
        XCTAssertEqual(layout.display, "a   b   c")
        XCTAssertEqual(layout.displayOffset(1), 1)
        XCTAssertEqual(layout.displayOffset(2), 4)
        XCTAssertEqual(layout.displayOffset(3), 5)
        XCTAssertEqual(layout.displayOffset(4), 8)
        XCTAssertEqual(layout.displayOffset(5), 9)
    }

    func testTabsAndUnusualSpacesKeepTheirOffsets() throws {
        let layout = try XCTUnwrap(Invisibles.layout("\tHello\u{A0}world"))
        XCTAssertEqual(layout.display, "\tHello\u{A0}world")
        XCTAssertEqual(layout.markers, [
            .init(kind: .tab, range: 0..<1, trailing: false),
            .init(kind: .unusualSpace, range: 6..<7, trailing: false),
        ])
        XCTAssertEqual(layout.displayOffset(12), 12)
    }

    func testBadgesAtStartAndEndAndAfterSurrogatePairs() throws {
        // 📍 is two UTF-16 units; offsets on either side of it are unaffected by badges.
        let layout = try XCTUnwrap(Invisibles.layout("\u{200B}📍x\u{7}"))
        XCTAssertEqual(layout.display, "      📍x   ")
        XCTAssertEqual(layout.markers.map(\.range), [0..<6, 9..<12])
        XCTAssertEqual(layout.displayOffset(0), 0)
        XCTAssertEqual(layout.displayOffset(1), 6)
        XCTAssertEqual(layout.displayOffset(3), 8)
        XCTAssertEqual(layout.displayOffset(4), 9)
        XCTAssertEqual(layout.displayOffset(5), 12)
        XCTAssertEqual(layout.display.utf16.count, 12)
    }

    func testTrailingWhitespaceIsMarked() throws {
        let layout = try XCTUnwrap(Invisibles.layout("mtu 9000 \t "))
        XCTAssertEqual(layout.trailingStart, 8)
        XCTAssertEqual(layout.markers, [
            .init(kind: .space, range: 8..<9, trailing: true),
            .init(kind: .tab, range: 9..<10, trailing: true),
            .init(kind: .space, range: 10..<11, trailing: true),
        ])
    }

    func testTrailingRunStopsAtBadge() throws {
        let layout = try XCTUnwrap(Invisibles.layout("x \u{200B} "))
        XCTAssertEqual(layout.display, "x        ")
        XCTAssertEqual(layout.trailingStart, 8)
        XCTAssertEqual(layout.markers.map(\.kind), [.badge("U+200B"), .space])
        XCTAssertEqual(layout.markers.map(\.trailing), [false, true])
    }

    func testSliceFromMiddleOfLineMarksNoTrailingSpaces() {
        XCTAssertNil(Invisibles.layout("abc   "[...], atLineEnd: false))
        XCTAssertNotNil(Invisibles.layout("abc   "[...], atLineEnd: true))
    }

    func testMaxColumnsMakesRoomForBadges() {
        let plain = TextDocument(text: "abcdef", name: "a")
        XCTAssertEqual(plain.maxColumns, 6)
        // Three bytes for U+200B, plus six columns for its badge.
        let badged = TextDocument(text: "abc\u{200B}def", name: "b")
        XCTAssertEqual(badged.maxColumns, 15)
        XCTAssertEqual(Invisibles.extraColumns("a\u{0}b"), 3)
    }
}
