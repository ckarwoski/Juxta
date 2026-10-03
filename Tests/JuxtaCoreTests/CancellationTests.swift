import XCTest
@testable import JuxtaCore

final class CancellationTests: XCTestCase {
    /// Random lines from a four-line vocabulary: nothing unique to anchor on, so Myers
    /// bisection has to search with a huge edit distance (seconds, up to the time limit).
    private static func pathological(_ count: Int, seed: UInt64) -> [String] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return "line \(state >> 62)"
        }
    }

    private static func seconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    func testCancelStopsAPathologicalCompare() {
        let left = Self.pathological(40_000, seed: 1)
        let right = Self.pathological(40_000, seed: 2)
        // It really is slow: a short limit runs out.
        XCTAssertTrue(Comparator.compare(left, right, timeLimit: 0.2).isApproximate)

        let cancellation = Cancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { cancellation.cancel() }
        let start = DispatchTime.now().uptimeNanoseconds
        let result = Comparator.compare(left, right, timeLimit: 5, cancellation: cancellation)
        let elapsed = Self.seconds(since: start)
        print(String(format: "cancelled compare returned after %.3fs", elapsed))
        XCTAssertNil(result)
        // 50 ms until cancel, plus a debug build's slack for the next check.
        XCTAssertLessThan(elapsed, 0.3)
    }

    func testCancelledBeforeStartReturnsNothing() {
        let cancellation = Cancellation()
        cancellation.cancel()
        XCTAssertNil(Comparator.compare(["a", "b"], ["a", "c"], cancellation: cancellation))
        // A cancelled search also gives up inside the engine, not just at the end.
        let a = Self.pathological(2_000, seed: 3).map { Int32($0.last!.wholeNumberValue!) }
        let b = Self.pathological(2_000, seed: 4).map { Int32($0.last!.wholeNumberValue!) }
        XCTAssertTrue(SequenceDiff.alignment(a, b, cancellation: cancellation).timedOut)
    }

    func testUncancelledResultIsTheSame() {
        let left = ["hostname r1", "interface Gi0/1", " mtu 9000", "!"]
        let right = ["hostname r1", "interface Gi0/1", " mtu 1514", " shutdown", "!"]
        let plain = Comparator.compare(left, right)
        let result = Comparator.compare(left, right, cancellation: Cancellation())
        XCTAssertEqual(result?.rows, plain.rows)
        XCTAssertEqual(result?.hunks, plain.hunks)
    }
}
