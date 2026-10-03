import Foundation
import os

/// Lets another thread stop a comparison: the engine checks it wherever it checks its
/// time limit, and gives up as if the limit had passed.
public final class Cancellation: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    public init() {}
    public func cancel() { flag.withLock { $0 = true } }
    public var isCancelled: Bool { flag.withLock { $0 } }
}

/// A pair of indices where `a[a] == b[b]` in the computed alignment.
public struct Match: Equatable, Sendable {
    public let a: Int
    public let b: Int
    public init(_ a: Int, _ b: Int) { self.a = a; self.b = b }
}

public enum SequenceDiff {
    /// Aligns two sequences of interned tokens and returns the matched index pairs in
    /// increasing order.
    ///
    /// With `patience` enabled, lines that occur exactly once on each side are used as
    /// anchors to split the input into small independent regions (this keeps huge,
    /// mostly-unique inputs like routing tables fast and produces readable hunks).
    /// Each region is then solved with Myers' O(ND) bisection. If `timeLimit` is
    /// exceeded, the remaining unsolved regions are reported as unmatched.
    public static func matches(
        _ a: [Int32], _ b: [Int32], patience: Bool = true, timeLimit: TimeInterval = 5
    ) -> [Match] {
        alignment(a, b, patience: patience, timeLimit: timeLimit).matches
    }

    /// The longest subsequence of `candidates` (ordered by `a`) that also increases in
    /// `b`, found by patience sorting.
    static func longestIncreasingRun(_ candidates: [Match]) -> [Match] {
        if candidates.isEmpty { return [] }
        var tails: [Int] = []
        var previous = [Int](repeating: -1, count: candidates.count)
        for (k, candidate) in candidates.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if candidates[tails[mid]].b < candidate.b { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { previous[k] = tails[lo - 1] }
            if lo == tails.count { tails.append(k) } else { tails[lo] = k }
        }
        var run: [Match] = []
        var k = tails.last!
        while k >= 0 {
            run.append(candidates[k])
            k = previous[k]
        }
        return run.reversed()
    }

    /// Like `matches`, but also reports whether `timeLimit` (or `cancellation`) cut the
    /// search short, in which case the alignment is valid but not minimal.
    public static func alignment(
        _ a: [Int32], _ b: [Int32], patience: Bool = true, timeLimit: TimeInterval = 5,
        cancellation: Cancellation? = nil
    ) -> (matches: [Match], timedOut: Bool) {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeLimit) * 1e9)
        return a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                let differ = Differ(a: pa, b: pb, deadline: deadline, cancellation: cancellation)
                differ.run(0, pa.count, 0, pb.count, patience: patience)
                return (differ.out, differ.timedOut)
            }
        }
    }
}

private final class Differ {
    let a: UnsafeBufferPointer<Int32>
    let b: UnsafeBufferPointer<Int32>
    let deadline: UInt64
    let cancellation: Cancellation?
    var out: [Match] = []
    /// Set only when a region is left unsolved because the deadline passed (or the
    /// comparison was cancelled).
    private(set) var timedOut = false

    init(a: UnsafeBufferPointer<Int32>, b: UnsafeBufferPointer<Int32>, deadline: UInt64,
         cancellation: Cancellation?) {
        self.a = a
        self.b = b
        self.deadline = deadline
        self.cancellation = cancellation
        out.reserveCapacity(min(a.count, b.count))
    }

    private var pastDeadline: Bool {
        if timedOut { return true }
        if DispatchTime.now().uptimeNanoseconds > deadline || cancellation?.isCancelled == true {
            timedOut = true
        }
        return timedOut
    }

    /// Work still to do, last first. Regions nest one level per anchor (and per Myers
    /// split), which on some inputs is deeper than a background thread's stack allows,
    /// so they're queued here rather than solved recursively.
    private enum Task {
        case run(Int, Int, Int, Int, patience: Bool)
        case matches(Int, Int, count: Int)
        /// Re-solves a region with Myers once its anchored matches (from `mark`) are in.
        case check(mark: Int, Int, Int, Int, Int)
        case keepBetter(mark: Int, anchored: [Match])
    }

    private var tasks: [Task] = []

    func run(_ aStart: Int, _ aEnd: Int, _ bStart: Int, _ bEnd: Int, patience: Bool) {
        tasks.append(.run(aStart, aEnd, bStart, bEnd, patience: patience))
        while let task = tasks.popLast() {
            switch task {
            case let .run(aLo, aHi, bLo, bHi, patience):
                region(aLo, aHi, bLo, bHi, patience: patience)
            case let .matches(a, b, count):
                for s in 0..<count { out.append(Match(a + s, b + s)) }
            case let .check(mark, aLo, aHi, bLo, bHi):
                if timedOut {
                    checked = false
                    continue
                }
                // An Array, not a slice: a slice would share `out`'s buffer and make the
                // removal copy all of `out`, once per checked region.
                let anchored = Array(out[mark...])
                out.removeSubrange(mark...)
                tasks.append(.keepBetter(mark: mark, anchored: anchored))
                bisect(aLo, aHi, bLo, bHi)
            case let .keepBetter(mark, anchored):
                if out.count - mark <= anchored.count {
                    out.replaceSubrange(mark..., with: anchored)
                }
                checked = false
            }
        }
    }

    private func region(_ aStart: Int, _ aEnd: Int, _ bStart: Int, _ bEnd: Int, patience: Bool) {
        var aLo = aStart, bLo = bStart
        while aLo < aEnd && bLo < bEnd && a[aLo] == b[bLo] {
            out.append(Match(aLo, bLo))
            aLo += 1
            bLo += 1
        }
        var suffix = 0
        while aLo < aEnd - suffix && bLo < bEnd - suffix
            && a[aEnd - 1 - suffix] == b[bEnd - 1 - suffix] {
            suffix += 1
        }
        let aHi = aEnd - suffix, bHi = bEnd - suffix
        if suffix > 0 { tasks.append(.matches(aHi, bHi, count: suffix)) }
        if aLo < aHi && bLo < bHi {
            if !(patience && patienceSplit(aLo, aHi, bLo, bHi)) {
                bisect(aLo, aHi, bLo, bHi)
            }
        }
    }

    // MARK: Patience anchoring

    private struct Occurrence {
        var countA: Int32 = 0
        var countB: Int32 = 0
        var indexA: Int32 = 0
        var indexB: Int32 = 0
    }

    /// Returns false if the region contains no unique common lines to anchor on but
    /// does share some lines.
    private func patienceSplit(_ aLo: Int, _ aHi: Int, _ bLo: Int, _ bHi: Int) -> Bool {
        // Anchors can nest one per line, each level rescanning its gap, so this phase
        // alone can take O(n²) time.
        if pastDeadline { return true }
        var table = [Int32: Occurrence](minimumCapacity: aHi - aLo)
        for i in aLo..<aHi {
            table[a[i], default: Occurrence()].countA += 1
            table[a[i]]!.indexA = Int32(i)
        }
        var shared = false
        for j in bLo..<bHi {
            // Only lines present on the left can become anchors.
            guard var entry = table[b[j]] else { continue }
            shared = true
            entry.countB += 1
            entry.indexB = Int32(j)
            table[b[j]] = entry
        }

        // Unique-in-both lines, ordered by their position on the left.
        var candidates: [Match] = []
        for i in aLo..<aHi {
            let entry = table[a[i]]!
            if entry.countA == 1 && entry.countB == 1 {
                candidates.append(Match(i, Int(entry.indexB)))
            }
        }
        // With nothing in common there is nothing to align, and bisection would take
        // O(n·m) to find that out (every line of a show output changed, unrelated files).
        if candidates.isEmpty { return !shared }

        let anchors = SequenceDiff.longestIncreasingRun(candidates)

        // Anchoring on the longest run of unique lines can keep the wrong block when
        // blocks swap places (the bigger one stays, the smaller ones move around it).
        // Small regions are cheap to check against plain Myers, which is minimal; it
        // only wins when it keeps more lines, so patience's tidier hunks stay the rule.
        if !checked && (aHi - aLo) + (bHi - bLo) <= Self.myersCheckLimit {
            checked = true
            tasks.append(.check(mark: out.count, aLo, aHi, bLo, bHi))
        }

        var aEnd = aHi, bEnd = bHi
        for anchor in anchors.reversed() {
            tasks.append(.run(anchor.a + 1, aEnd, anchor.b + 1, bEnd, patience: true))
            tasks.append(.matches(anchor.a, anchor.b, count: 1))
            aEnd = anchor.a
            bEnd = anchor.b
        }
        tasks.append(.run(aLo, aEnd, bLo, bEnd, patience: true))
        return true
    }

    /// Regions up to this many lines (both sides) are also solved by plain Myers.
    private static let myersCheckLimit = 1000
    /// A region is being checked against Myers, so the regions nested in it aren't.
    private var checked = false

    // MARK: Myers bisection (after diff-match-patch's diff_bisect)

    private func bisect(_ aLo: Int, _ aHi: Int, _ bLo: Int, _ bHi: Int) {
        if pastDeadline { return }
        let n = aHi - aLo, m = bHi - bLo
        let maxD = (n + m + 1) / 2
        let vOffset = maxD
        let vLength = 2 * maxD + 2
        var v1 = [Int](repeating: -1, count: vLength)
        var v2 = [Int](repeating: -1, count: vLength)
        v1[vOffset + 1] = 0
        v2[vOffset + 1] = 0
        let delta = n - m
        let front = delta % 2 != 0
        var k1start = 0, k1end = 0, k2start = 0, k2end = 0

        for d in 0..<maxD {
            if d & 63 == 63 && pastDeadline { return }

            var k1 = -d + k1start
            while k1 <= d - k1end {
                let k1o = vOffset + k1
                var x1: Int
                if k1 == -d || (k1 != d && v1[k1o - 1] < v1[k1o + 1]) {
                    x1 = v1[k1o + 1]
                } else {
                    x1 = v1[k1o - 1] + 1
                }
                var y1 = x1 - k1
                while x1 < n && y1 < m && a[aLo + x1] == b[bLo + y1] {
                    x1 += 1
                    y1 += 1
                }
                v1[k1o] = x1
                if x1 > n {
                    k1end += 2
                } else if y1 > m {
                    k1start += 2
                } else if front {
                    let k2o = vOffset + delta - k1
                    if k2o >= 0 && k2o < vLength && v2[k2o] != -1 {
                        if x1 >= n - v2[k2o] {
                            split(aLo, aHi, bLo, bHi, x1, y1)
                            return
                        }
                    }
                }
                k1 += 2
            }

            var k2 = -d + k2start
            while k2 <= d - k2end {
                let k2o = vOffset + k2
                var x2: Int
                if k2 == -d || (k2 != d && v2[k2o - 1] < v2[k2o + 1]) {
                    x2 = v2[k2o + 1]
                } else {
                    x2 = v2[k2o - 1] + 1
                }
                var y2 = x2 - k2
                while x2 < n && y2 < m && a[aHi - x2 - 1] == b[bHi - y2 - 1] {
                    x2 += 1
                    y2 += 1
                }
                v2[k2o] = x2
                if x2 > n {
                    k2end += 2
                } else if y2 > m {
                    k2start += 2
                } else if !front {
                    let k1o = vOffset + delta - k2
                    if k1o >= 0 && k1o < vLength && v1[k1o] != -1 {
                        let x1 = v1[k1o]
                        let y1 = vOffset + x1 - k1o
                        if x1 >= n - x2 {
                            split(aLo, aHi, bLo, bHi, x1, y1)
                            return
                        }
                    }
                }
                k2 += 2
            }
        }
        // No common subsequence: everything in this region is a replacement.
    }

    private func split(_ aLo: Int, _ aHi: Int, _ bLo: Int, _ bHi: Int, _ x: Int, _ y: Int) {
        // Guard against a degenerate split that would loop forever.
        if (x == 0 && y == 0) || (aLo + x == aHi && bLo + y == bHi) { return }
        tasks.append(.run(aLo + x, aHi, bLo + y, bHi, patience: false))
        tasks.append(.run(aLo, aLo + x, bLo, bLo + y, patience: false))
    }
}
