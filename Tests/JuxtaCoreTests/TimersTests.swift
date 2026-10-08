import XCTest
@testable import JuxtaCore

final class TimersTests: XCTestCase {
    /// The timers found in a line, for readable assertions.
    private func found(_ line: String) -> [String] {
        let units = Array(line.utf16)
        return Timers.ranges(in: units).map { String(decoding: units[$0], as: UTF16.self) }
    }

    func testClocks() {
        XCTAssertEqual(found("O 10.0.0.1/32 [110/2] via 10.0.0.1, 00:12:44, Gi0/0"), ["00:12:44"])
        XCTAssertEqual(found("via 10.0.0.1, 0:04:12, Gi0/0"), ["0:04:12"])
        XCTAssertEqual(found("*10:15:32.123 UTC Mon Oct 7 2026"), ["10:15:32.123"])
        XCTAssertEqual(found("10.255.0.2  1  FULL/DR  00:00:34  10.0.12.2  Gi0/0"), ["00:00:34"])
        XCTAssertEqual(found("Uptime=00:12:44 state up"), ["00:12:44"])
    }

    func testUnits() {
        for timer in ["1w2d", "3d04h", "2y15w", "1d02h03m", "01w2d03h"] {
            XCTAssertEqual(found("age \(timer), x"), [timer])
        }
        XCTAssertEqual(found("*via 10.0.0.1, Eth1/1, [110/41], 1d02h, ospf-1, intra"), ["1d02h"])
        XCTAssertEqual(found("10.0.0.2  4 65002  1200  1300  41  0  0 1w2d 5"), ["1w2d"])
    }

    func testJunosUnitsAndClock() {
        XCTAssertEqual(found("*[OSPF/10] 3w2d 04:11:22, metric 2"), ["3w2d 04:11:22"])
        XCTAssertEqual(found("*[BGP/170] 5d 3:04:11, localpref 100"), ["5d 3:04:11"])
        XCTAssertEqual(found("Last flap (5w1d 02:03 ago)"), ["5w1d 02:03"])
        XCTAssertEqual(found("10.0.0.2  65002  1200  1300  0  0  1w2d 3:04:05 Establ"), ["1w2d 3:04:05"])
    }

    func testSpelledOutUptimes() {
        XCTAssertEqual(found("r1 uptime is 2 weeks, 3 days, 4 hours, 5 minutes"),
                       ["2 weeks, 3 days, 4 hours, 5 minutes"])
        XCTAssertEqual(found("Kernel uptime is 12 day(s), 3 hour(s), 4 minute(s), 5 second(s)"),
                       ["12 day(s), 3 hour(s), 4 minute(s), 5 second(s)"])
        XCTAssertEqual(found("Uptime: 2 weeks, 3 days, 4 hours and 5 minutes"),
                       ["2 weeks, 3 days, 4 hours and 5 minutes"])
        XCTAssertEqual(found("uptime is 1 year, 1 week, and 1 day."), ["1 year, 1 week, and 1 day"])
        // A trailing term out of order isn't part of it.
        XCTAssertEqual(found("up 3 days, 4 hours, 2 days"), ["3 days, 4 hours"])
    }

    func testNever() {
        XCTAssertEqual(found("  Last input 00:00:01, output 00:00:00, output hang never"),
                       ["00:00:01", "00:00:00", "never"])
        XCTAssertEqual(found("  Last input never, output never, output hang never"), ["never", "never", "never"])
        XCTAssertEqual(found("  Last clearing of \"show interface\" counters never"), ["never"])
        XCTAssertEqual(found("  Last reset never"), [])
        XCTAssertEqual(found("  Last input nevermore"), [])
    }

    func testThingsThatAreNotTimers() {
        for line in ["ipv6 address fe80::1:22:33", "Gi0/0  FE80::1:22:33", "mac 00:11:22:33:44:55",
                     "10.0.0.5  0  aabb.1d00.0100  ARPA", "aabb.cc00.0100", "00a3.d14f.2c00",
                     "set community 65000:100", "set large-community 65000:10:20", "rt RT:1:10",
                     "periodic weekdays 08:00 to 17:00", "version 17.09.04a", "Version 15.2(4)M3",
                     "Gi0/0/1 xe-0/0/0", "police 10m", "timeout 5s", "delay 10ms", "x 1d1d", "123:45:67",
                     "12:60:00", "1:2:3", "12:34", "5 minute input rate 41000 bits/sec, 52 packets/sec",
                     "age 1W2D", "1d00.", "1w2d/24", "10:15:32.", "id_00:12:44", "x.00:12:44"] {
            XCTAssertEqual(found(line), [], line)
        }
    }

    /// Accepted gaps and false matches, pinned so a change to them is deliberate.
    func testKnownGaps() {
        XCTAssertEqual(found("Uptime:00:12:44"), [])
        XCTAssertEqual(found("10:15:32.123: %LINK-3-UPDOWN"), [])
        XCTAssertEqual(found("set large-community 1:10:20"), ["1:10:20"])
    }

    func testMaskedReplacesEachTimer() {
        XCTAssertEqual(Timers.masked("via 10.0.0.1, 00:12:44, Gi0/0"), "via 10.0.0.1, \u{E000}, Gi0/0")
        XCTAssertEqual(Timers.masked("3w2d 04:11:22, 5d"), "\u{E000}, 5d")
        XCTAssertEqual(Timers.masked("interface Gi0/1"), "interface Gi0/1")
        XCTAssertEqual(Timers.masked(""), "")
    }

    /// UTF-16 ranges mark the same timers that masking the UTF-8 replaces.
    func testEncodingsAgree() {
        for line in ["Café 00:12:44 📍 1w2d", "Zürich–00:12:44", "é1w2d", "📍 2 weeks, 3 days",
                     "input\u{A0}never", "Last input never 🕐", "via 10.0.0.1, 00:12:44, Gi0/0"] {
            let units = Array(line.utf16)
            var spliced: [UInt16] = [], copied = 0
            for range in Timers.ranges(in: units) {
                spliced += units[copied..<range.lowerBound]
                spliced += Timers.sentinel.utf16
                copied = range.upperBound
            }
            spliced += units[copied...]
            XCTAssertEqual(String(decoding: spliced, as: UTF16.self), Timers.masked(line), line)
        }
    }
}
