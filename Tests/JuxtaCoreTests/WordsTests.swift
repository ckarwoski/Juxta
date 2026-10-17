import XCTest
@testable import JuxtaCore

final class WordsTests: XCTestCase {
    /// The word double-clicking at `offset` selects.
    private func word(at offset: Int, in line: String) -> String {
        let range = Words.range(at: offset, in: line)
        let utf16 = line.utf16
        return String(utf16[utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
                            ..< utf16.index(utf16.startIndex, offsetBy: range.upperBound)])!
    }

    func testAddressesAndInterfacesAreOneWord() {
        let line = " ip address 10.1.1.1/24 secondary"
        XCTAssertEqual(Words.range(at: 12, in: line), 12..<23)
        XCTAssertEqual(Words.range(at: 22, in: line), 12..<23)
        XCTAssertEqual(word(at: 17, in: line), "10.1.1.1/24")
        XCTAssertEqual(word(at: 5, in: "ipv6 2001:db8::1/64"), "2001:db8::1/64")
        XCTAssertEqual(word(at: 0, in: "GigabitEthernet0/0/1"), "GigabitEthernet0/0/1")
        XCTAssertEqual(word(at: 13, in: "neighbor x route-map IN in"), "route-map")
        XCTAssertEqual(word(at: 3, in: "vrf_core-1"), "vrf_core-1")
    }

    func testOtherCharactersAreWordsOfOne() {
        let line = "a  (b),c"
        XCTAssertEqual(Words.range(at: 1, in: line), 1..<2) // each space alone
        XCTAssertEqual(Words.range(at: 2, in: line), 2..<3)
        XCTAssertEqual(Words.range(at: 3, in: line), 3..<4) // (
        XCTAssertEqual(Words.range(at: 4, in: line), 4..<5) // b
        XCTAssertEqual(Words.range(at: 5, in: line), 5..<6) // )
        XCTAssertEqual(Words.range(at: 6, in: line), 6..<7) // ,
        XCTAssertEqual(word(at: 1, in: "x\ty"), "\t")
        XCTAssertEqual(word(at: 4, in: "key=value"), "value")
        XCTAssertEqual(word(at: 3, in: "key=value"), "=")
    }

    func testLineEdges() {
        XCTAssertEqual(Words.range(at: 0, in: ""), 0..<0)
        XCTAssertEqual(Words.range(at: 3, in: ""), 0..<0)
        // At or past the end of the line, the last character's word.
        XCTAssertEqual(Words.range(at: 9, in: "mtu 9000"), 4..<8)
        XCTAssertEqual(Words.range(at: 8, in: "mtu 9000"), 4..<8)
        XCTAssertEqual(Words.range(at: 4, in: "mtu "), 3..<4)
        XCTAssertEqual(Words.range(at: 0, in: "mtu 9000"), 0..<3)
        XCTAssertEqual(Words.range(at: 0, in: " x"), 0..<1)
    }

    func testNonASCII() {
        // Letters beyond ASCII join words; a decomposed é stays with its accent.
        XCTAssertEqual(word(at: 2, in: "description Zürich-1"), "description")
        XCTAssertEqual(word(at: 14, in: "description Zürich-1"), "Zürich-1")
        XCTAssertEqual(word(at: 1, in: "cafe\u{301} x"), "cafe\u{301}")
        XCTAssertEqual(Words.range(at: 4, in: "cafe\u{301} x"), 0..<5)
        XCTAssertEqual(word(at: 1, in: "東京 x"), "東京")
        // 📍 is a surrogate pair and a word of one; either half selects both.
        XCTAssertEqual(Words.range(at: 2, in: "a 📍b"), 2..<4)
        XCTAssertEqual(Words.range(at: 3, in: "a 📍b"), 2..<4)
        XCTAssertEqual(Words.range(at: 4, in: "a 📍b"), 4..<5)
        XCTAssertEqual(Words.range(at: 5, in: "a 📍"), 2..<4)
    }
}
