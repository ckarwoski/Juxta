import XCTest
@testable import JuxtaCore

/// Load + compare timings for the targets in docs/testing-plan.md step 4.
///
/// - `swift test`: the quick checks only, with limits about 10× the measured debug time, so
///   a busy machine doesn't fail them; they still catch an algorithmic regression.
/// - `JUXTA_PERF=1 swift test`: also the multi-second fixtures (62, 63, 66, 67), with debug
///   limits about 3× the measured debug time.
/// - `swift test -c release -Xswiftc -enable-testing`: everything, against the release targets.
final class PerformanceTests: XCTestCase {
    #if DEBUG
    private static let full = ProcessInfo.processInfo.environment["JUXTA_PERF"] != nil
    #else
    private static let full = true
    #endif

    /// Skips a test that takes seconds in a debug build unless the full run was asked for.
    private func requireFullRun() throws {
        try XCTSkipUnless(Self.full, "slow in debug; run with JUXTA_PERF=1 or -c release")
    }

    private struct Timed {
        var left: TextDocument
        var right: TextDocument
        var result: DiffResult
    }

    private static func seconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    private func limit(debug: Double, release: Double) -> Double {
        #if DEBUG
        return Self.full ? debug : debug * 3
        #else
        return release
        #endif
    }

    /// Loads and compares a generated pair, skipping when it hasn't been generated.
    /// `slowInDebug`: the debug build reaches the 5 s no-match limit, so the result may be
    /// approximate there.
    private func timeFixture(_ number: String, debug: Double, release: Double, slowInDebug: Bool = false,
                             file: StaticString = #filePath, line: UInt = #line) throws -> Timed {
        let folder = Fixtures.root.appendingPathComponent("generated")
        let exists = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
            .contains { $0.hasPrefix(number + "-") } ?? false
        try XCTSkipUnless(exists, "run scripts/make-fixtures.py" + (number == "67" ? " --huge" : ""))
        let start = DispatchTime.now().uptimeNanoseconds
        let left = try TextDocument.load(from: Fixtures.file(number, "left", in: "generated"))
        let right = try TextDocument.load(from: Fixtures.file(number, "right", in: "generated"))
        let loaded = Self.seconds(since: start)
        let result = Comparator.compare(left.lines, right.lines)
        let total = Self.seconds(since: start)
        print(String(format: "fixture %@: load %.3fs, compare %.3fs, total %.3fs (limit %gs)",
                     number, loaded, total - loaded, total, limit(debug: debug, release: release)))
        XCTAssertLessThan(total, limit(debug: debug, release: release), file: file, line: line)
        #if DEBUG
        let mayBeApproximate = slowInDebug
        #else
        let mayBeApproximate = false
        #endif
        if !mayBeApproximate { XCTAssertFalse(result.isApproximate, file: file, line: line) }
        assertRebuildsBothFiles(result, leftCount: left.lines.count, rightCount: right.lines.count,
                                file: file, line: line)
        return Timed(left: left, right: right, result: result)
    }

    private func routes(_ count: Int) -> [String] {
        (0..<count).map { i in
            "O    10.\(i / 65536).\((i / 256) % 256).\(i % 256)/32 [110/\(i % 7)] via 192.168.1.\(i % 250), 01:02:03, Gi0/0"
        }
    }

    func test2kLines5PercentChanged() {
        let left = routes(2000)
        var right = left
        for i in stride(from: 0, to: right.count, by: 20) {
            right[i] = right[i].replacingOccurrences(of: "01:02:03", with: "04:05:06")
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let result = Comparator.compare(left, right)
        let elapsed = Self.seconds(since: start)
        print(String(format: "2k lines 5%%: compare %.3fs", elapsed))
        XCTAssertLessThan(elapsed, limit(debug: 0.05, release: 0.05))
        XCTAssertEqual(result.changedLines, 100)
        XCTAssertEqual(result.hunks.count, 100)
    }

    /// Synthetic 200k-line table, so a large compare is timed even without generated fixtures.
    func testSynthetic200kRoutingTable() {
        let left = routes(200_000)
        var right = left
        for i in stride(from: 0, to: right.count, by: 97) {
            right[i] = right[i].replacingOccurrences(of: "01:02:03", with: "04:05:06")
        }
        right.removeSubrange(5000..<5100)
        right.insert(contentsOf: (0..<50).map { "S    172.16.\($0).0/24 [1/0] via 10.0.0.1" }, at: 90_000)
        let start = DispatchTime.now().uptimeNanoseconds
        let result = Comparator.compare(left, right)
        let elapsed = Self.seconds(since: start)
        print(String(format: "synthetic 200k: compare %.3fs, %d hunks", elapsed, result.hunks.count))
        XCTAssertLessThan(elapsed, limit(debug: 3, release: 0.5))
        XCTAssertFalse(result.isApproximate)
        assertRebuildsBothFiles(result, leftCount: left.count, rightCount: right.count)
    }

    func test60Routes20k() throws {
        let timed = try timeFixture("60", debug: 0.5, release: 0.25)
        XCTAssertEqual(timed.result.changedLines, 1000)
    }

    func test61Routes200k() throws {
        let timed = try timeFixture("61", debug: 4, release: 1)
        XCTAssertEqual(timed.left.lines.count, 200_000)
        XCTAssertEqual(timed.result.changedLines, 1999)
        XCTAssertEqual(timed.result.deletedLines, 100)
        XCTAssertEqual(timed.result.insertedLines, 50)
    }

    /// Unrelated files: everything is deleted and inserted, apart from a few lines that
    /// happen to pair up.
    func test62Unrelated20k() throws {
        try requireFullRun()
        let timed = try timeFixture("62", debug: 7.5, release: 0.5)
        XCTAssertEqual(timed.result.hunks.count, 1)
        XCTAssertLessThanOrEqual(timed.result.changedLines, 5)
    }

    func test63Unrelated100k() throws {
        try requireFullRun()
        let timed = try timeFixture("63", debug: 15, release: 2.5, slowInDebug: true)
        XCTAssertEqual(timed.result.hunks.count, 1)
        XCTAssertLessThanOrEqual(timed.result.changedLines, 5)
    }

    /// No unique lines to anchor on; the 2% of edits should stay small hunks.
    func test64LowUnique100k() throws {
        let timed = try timeFixture("64", debug: 2, release: 0.5)
        XCTAssertLessThan(timed.result.deletedLines + timed.result.insertedLines + timed.result.changedLines, 5000)
    }

    /// Pairing (no drift) is checked in AlignmentTests.test65BigChangedBlockDoesNotDrift.
    func test65BigChangedBlock() throws {
        _ = try timeFixture("65", debug: 0.5, release: 0.25)
    }

    func test66EveryLineChanged50k() throws {
        try requireFullRun()
        let timed = try timeFixture("66", debug: 9, release: 0.5)
        XCTAssertEqual(timed.result.changedLines, 50_000)
        XCTAssertEqual(timed.result.hunks.count, 1)
    }

    /// Only with `scripts/make-fixtures.py --huge`; peak memory is measured with juxta-diff.
    func test67Routes1M() throws {
        try requireFullRun()
        let timed = try timeFixture("67", debug: 20, release: 3)
        XCTAssertEqual(timed.left.lines.count, 1_000_000)
        XCTAssertEqual(timed.result.changedLines, 1000)
    }
}
