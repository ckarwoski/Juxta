import XCTest
@testable import JuxtaCore

final class DeepAlignmentTests: XCTestCase {
    /// Each level's first left line is unique and anchors; the right side repeats the next
    /// level's anchor just before it, so that line only becomes unique inside the gap
    /// after the anchor. Patience anchoring nests one level per line.
    private static func nested(_ levels: Int) -> ([Int32], [Int32]) {
        var a: [Int32] = [], b: [Int32] = []
        for i in stride(from: Int32(levels), through: 1, by: -1) {
            a.append(i)
            b += [i - 1, i]
        }
        return (a + [-1], b + [-2])
    }

    private static func seconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    /// Matches for seeded inputs from small to past the size checked against Myers,
    /// hashed. The value was recorded from the recursive implementation.
    func testMatchesAreUnchangedOnSeededInputs() {
        var state: UInt64 = 1
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        var hash: UInt64 = 14_695_981_039_346_656_037
        func mix(_ value: Int) { hash = (hash ^ UInt64(bitPattern: Int64(value))) &* 1_099_511_628_211 }
        for round in 0..<400 {
            let count = [20, 200, 700, 3000][round % 4]
            let vocabulary = [3, 30, 300, 100_000][round / 4 % 4]
            let a = (0..<next(count) + 1).map { _ in Int32(next(vocabulary)) }
            var b = a
            for _ in 0..<next(a.count / 4 + 2) {
                let k = next(b.count + 1)
                switch next(3) {
                case 0: b.insert(Int32(next(vocabulary)), at: k)
                case 1 where k < b.count: b.remove(at: k)
                default: if k < b.count { b[k] = Int32(next(vocabulary)) }
                }
            }
            for patience in [true, false] {
                let matches = SequenceDiff.matches(a, b, patience: patience, timeLimit: 60)
                mix(matches.count)
                for m in matches { mix(m.a); mix(m.b) }
            }
        }
        XCTAssertEqual(hash, 1_852_842_628_762_876_396)
    }

    /// Compares run on a GCD worker, whose stack is 512 KB; the recursive version
    /// overflowed it at about 175 levels in a debug build and 2,000 in release.
    func testDeeplyNestedAnchorsFitASmallStack() {
        let (a, b) = Self.nested(1_500)
        var matches: [Match] = []
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            matches = SequenceDiff.matches(a, b)
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        done.wait()
        XCTAssertEqual(matches, (0..<1_500).map { Match($0, 2 * $0 + 1) })
    }

    /// Each level rescans its whole gap, so this took 11 s in a release build, past any
    /// time limit, before the anchoring phase checked the deadline too.
    func testDeeplyNestedAnchorsHonourTheTimeLimit() {
        let (a, b) = Self.nested(20_000)
        var start = DispatchTime.now().uptimeNanoseconds
        let limited = SequenceDiff.alignment(a, b, timeLimit: 0.1)
        XCTAssertLessThan(Self.seconds(since: start), 0.5)
        XCTAssertTrue(limited.timedOut)

        let cancellation = Cancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { cancellation.cancel() }
        start = DispatchTime.now().uptimeNanoseconds
        let cancelled = SequenceDiff.alignment(a, b, timeLimit: 60, cancellation: cancellation)
        XCTAssertLessThan(Self.seconds(since: start), 0.5)
        XCTAssertTrue(cancelled.timedOut)
    }
}
