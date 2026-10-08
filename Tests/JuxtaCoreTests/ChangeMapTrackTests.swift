import XCTest
@testable import JuxtaCore

/// Where the change map draws its markers and knob, and where it stops short of a rounded corner.
final class ChangeMapTrackTests: XCTestCase {
    func testBottomInsetClearsRoundedCorner() {
        // A 16 pt corner needs 16 - √87 + 1 ≈ 7.67 pt, rounded up to the pixel.
        XCTAssertEqual(ChangeMapTrack.bottomInset(cornerRadius: 16, pixel: 0.5), 8)
        XCTAssertEqual(ChangeMapTrack.bottomInset(cornerRadius: 16, pixel: 1), 8)
        XCTAssertEqual(ChangeMapTrack.bottomInset(cornerRadius: 26, pixel: 0.5), 15)
        // The marker's corner then sits inside the curve.
        let inset = ChangeMapTrack.bottomInset(cornerRadius: 16, pixel: 0.5)
        XCTAssertLessThan(hypot(16 - 3, 16 - inset), 16)
    }

    func testBottomInsetNeverBelowMinimum() {
        XCTAssertEqual(ChangeMapTrack.bottomInset(cornerRadius: 0), 4)
        XCTAssertEqual(ChangeMapTrack.bottomInset(cornerRadius: 3), 4)
        XCTAssertEqual(ChangeMapTrack.bottomInset(cornerRadius: 6, pixel: 0.5), 4)
    }

    func testMarkersFillTrackBetweenInsets() {
        let track = ChangeMapTrack(height: 108, top: 4, bottom: 4)
        XCTAssertEqual(track.length, 100)
        XCTAssertTrue(track.marker(rows: 0..<10, of: 100) == (4, 10))
        XCTAssertTrue(track.marker(rows: 90..<100, of: 100) == (94, 10))
        let rounded = ChangeMapTrack(height: 112, top: 4, bottom: 8)
        XCTAssertTrue(rounded.marker(rows: 90..<100, of: 100) == (94, 10))
    }

    func testShortMarkerAtEndStaysInTrack() {
        // One row of 10 000 would be 0.01 pt; it is drawn 2 pt tall, ending at the track's end.
        let track = ChangeMapTrack(height: 108, top: 4, bottom: 4)
        XCTAssertTrue(track.marker(rows: 9999..<10000, of: 10000) == (102, 2))
        XCTAssertTrue(track.marker(rows: 0..<1, of: 10000) == (4, 2))
    }

    func testKnobSpansTrack() {
        let track = ChangeMapTrack(height: 112, top: 4, bottom: 8)
        XCTAssertTrue(track.knob(top: 0, height: 0.25) == (4, 25))
        XCTAssertTrue(track.knob(top: 0.75, height: 0.25) == (79, 25))
        // At least 16 pt, still ending at the track's end.
        let small = track.knob(top: 0.99, height: 0.01)
        XCTAssertEqual(small.y, 88, accuracy: 1e-9)
        XCTAssertEqual(small.height, 16)
    }

    func testDragFraction() {
        let track = ChangeMapTrack(height: 112, top: 4, bottom: 8)
        XCTAssertEqual(track.fraction(knobY: 4, knobHeight: 25), 0)
        XCTAssertEqual(track.fraction(knobY: 79, knobHeight: 25), 1)
        XCTAssertEqual(track.fraction(knobY: 41.5, knobHeight: 25), 0.5)
        XCTAssertEqual(track.fraction(knobY: -50, knobHeight: 25), 0)
        XCTAssertEqual(track.fraction(knobY: 500, knobHeight: 25), 1)
        XCTAssertNil(track.fraction(knobY: 4, knobHeight: 100))
    }
}
