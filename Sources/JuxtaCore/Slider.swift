import Foundation

/// Moves each run of inserted or deleted lines to where a reader expects it. A run can
/// often slide up or down because the lines at its edges are equal: a block deleted
/// between two `!` separators can take the `!` above it or its own `!` below. The diff
/// is equally minimal either way, so this only picks the boundary, like git's
/// `xdl_change_compact` with its indent heuristic.
///
/// For each run, all positions it can slide to are tried, preferring in order:
/// 1. lining up with a change on the other side, so a replacement stays one hunk;
/// 2. ending on a separator (`!`, `}`, `end`, `exit`, `exit-address-family`, `end-policy`,
///    `end-set`, `next`, blank) indented no deeper than the first non-blank line, which is
///    indented no deeper than the line after it, i.e. covering whole config blocks,
///    functions or paragraphs. Leading blank lines are the gap before a blank-separated block;
/// 3. git's indent heuristic: boundaries next to blank lines and at shallow indents
///    score better, and ones that cut into a deeper-indented body score worse.
/// Ties go to the position furthest down, as in git.
enum Slider {
    static func slide(
        _ matches: [Match], _ a: [Int32], _ b: [Int32], _ left: [String], _ right: [String]
    ) -> [Match] {
        if matches.count == a.count && matches.count == b.count { return matches }
        // changed[k + 1] is line k, with an unchanged sentinel at each end.
        var changedA = [Bool](repeating: true, count: a.count + 2)
        var changedB = [Bool](repeating: true, count: b.count + 2)
        changedA[0] = false; changedA[a.count + 1] = false
        changedB[0] = false; changedB[b.count + 1] = false
        for match in matches {
            changedA[match.a + 1] = false
            changedB[match.b + 1] = false
        }
        compact(a, left, &changedA, changedB)
        compact(b, right, &changedB, changedA)

        // Sliding keeps the unchanged lines of the two sides equal, in step.
        var out: [Match] = []
        out.reserveCapacity(matches.count)
        var i = 0, j = 0
        while true {
            while i < a.count && changedA[i + 1] { i += 1 }
            while j < b.count && changedB[j + 1] { j += 1 }
            if i == a.count || j == b.count { break }
            out.append(Match(i, j))
            i += 1
            j += 1
        }
        return out
    }

    /// Lines `start..<end` of one side, all changed, between two unchanged lines (or
    /// the ends of the file). Groups may be empty, so the n-th group of each side sits
    /// between the same pair of matched lines.
    private struct Group {
        var start = 0, end = 0
    }

    /// Slides the groups of one side (after xdiff's xdl_change_compact). `other` is
    /// only read, to know where the other side's changes are.
    private static func compact(_ ids: [Int32], _ lines: [String], _ changed: inout [Bool], _ other: [Bool]) {
        let n = ids.count, otherCount = other.count - 2
        func isChanged(_ k: Int) -> Bool { changed[k + 1] }
        func extend(_ g: inout Group) { while changed[g.end + 1] { g.end += 1 } }
        func next(_ g: inout Group, _ flags: [Bool], _ count: Int) -> Bool {
            if g.end == count { return false }
            g.start = g.end + 1
            g.end = g.start
            while flags[g.end + 1] { g.end += 1 }
            return true
        }
        func previous(_ g: inout Group, _ flags: [Bool]) {
            g.end = g.start - 1
            g.start = g.end
            while flags[g.start] { g.start -= 1 }
        }
        func slideUp(_ g: inout Group) -> Bool {
            guard g.start > 0 && ids[g.start - 1] == ids[g.end - 1] else { return false }
            g.start -= 1
            g.end -= 1
            changed[g.start + 1] = true
            changed[g.end + 1] = false
            while isChanged(g.start - 1) { g.start -= 1 }
            return true
        }
        func slideDown(_ g: inout Group) -> Bool {
            guard g.end < n && ids[g.start] == ids[g.end] else { return false }
            changed[g.start + 1] = false
            changed[g.end + 1] = true
            g.start += 1
            g.end += 1
            extend(&g)
            return true
        }

        var g = Group(), go = Group()
        extend(&g)
        while other[go.end + 1] { go.end += 1 }
        repeat {
            guard g.end > g.start else { continue }
            // Slide up, then down as far as possible, merging any groups bumped into,
            // until the group stops growing.
            var size = 0, earliestEnd = 0, endMatchingOther = -1
            repeat {
                size = g.end - g.start
                endMatchingOther = -1
                while slideUp(&g) { previous(&go, other) }
                earliestEnd = g.end
                if go.end > go.start { endMatchingOther = g.end }
                while slideDown(&g) {
                    _ = next(&go, other, otherCount)
                    if go.end > go.start { endMatchingOther = g.end }
                }
            } while size != g.end - g.start

            // The group is at its lowest position, so only upward moves remain.
            var target = g.end
            if g.end == earliestEnd {
                continue
            } else if endMatchingOther != -1 {
                target = endMatchingOther
            } else {
                var best: Score?
                // Positions a whole group-length apart look alike; git's bounds.
                for end in max(earliestEnd, g.end - size - 1, g.end - 100)...g.end {
                    let score = Score(lines, end - size, end)
                    if best == nil || score <= best! {
                        best = score
                        target = end
                    }
                }
            }
            while g.end > target {
                _ = slideUp(&g)
                previous(&go, other)
            }
        } while next(&g, changed, n) && next(&go, other, otherCount)
    }

    // MARK: Scoring

    private static let separators: Set<Substring> = [
        "", "!", "}", "end", "exit", "exit-address-family", "end-policy", "end-set", "next",
    ]

    /// Columns of leading whitespace (tabs to multiples of 8), or -1 for a blank line.
    private static func indent(_ line: String) -> Int {
        var columns = 0
        for c in line.utf8 {
            switch c {
            case 0x20: columns += 1
            case 0x09: columns += 8 - columns % 8
            case 0x0B, 0x0C, 0x0D: break
            default: return min(columns, 200)
            }
        }
        return -1
    }

    /// How good a position for the group `start..<end` is; smaller is better.
    private struct Score: Comparable {
        /// Rule 2 (see `Slider`) holds.
        var wholeBlock = false
        var penalty = 0
        var indent = 0

        init(_ lines: [String], _ start: Int, _ end: Int) {
            wholeBlock = Score.isWholeBlock(lines, start, end)
            add(lines, start)
            add(lines, end)
        }

        /// Rule 2. Leading blank lines count as the gap before the block, so a blank-separated
        /// block can take its own blank line rather than the previous block's closer. A closer
        /// deeper than the block's first line (a nested `end` or `  !`) closes an inner block,
        /// not this one.
        ///
        /// (Whether the line above is a separator doesn't matter: if it isn't, the group can't
        /// slide up, and one line down, if it can go there, is also a whole block and scores
        /// better.)
        private static func isWholeBlock(_ lines: [String], _ start: Int, _ end: Int) -> Bool {
            let last = lines[end - 1].trimmingCharacters(in: .whitespaces)
            var head = start
            while head < end - 1 && Slider.indent(lines[head]) < 0 { head += 1 }
            let first = Slider.indent(lines[head])
            let second = head + 1 < lines.count ? Slider.indent(lines[head + 1]) : -1
            let closer = Slider.indent(lines[end - 1])
            return separators.contains(Substring(last)) && first >= 0 && (second < 0 || first <= second)
                && (closer < 0 || closer <= first)
        }

        static func < (x: Score, y: Score) -> Bool {
            if x.wholeBlock != y.wholeBlock { return x.wholeBlock }
            // git's weighting: total indent of the lines after the splits matters most.
            let indents = x.indent == y.indent ? 0 : x.indent < y.indent ? -1 : 1
            return 60 * indents + x.penalty - y.penalty < 0
        }

        static func == (x: Score, y: Score) -> Bool { !(x < y) && !(y < x) }

        /// git's measure_split + score_add_split for the boundary just above line
        /// `split`: blank lines around it are good (especially above), and a line more
        /// indented than the one before (cutting into a body) or a dedent is bad.
        private mutating func add(_ lines: [String], _ split: Int) {
            let maxBlanks = 20
            let at = split < lines.count ? Slider.indent(lines[split]) : -1
            var preBlank = 0, preIndent = -1
            for k in stride(from: split - 1, through: 0, by: -1) {
                preIndent = Slider.indent(lines[k])
                if preIndent >= 0 { break }
                preBlank += 1
                if preBlank == maxBlanks { preIndent = 0; break }
            }
            var postBlank = 0, postIndent = -1
            for k in (split + 1)..<max(split + 1, lines.count) {
                postIndent = Slider.indent(lines[k])
                if postIndent >= 0 { break }
                postBlank += 1
                if postBlank == maxBlanks { postIndent = 0; break }
            }

            if preIndent == -1 && preBlank == 0 { penalty += 1 }  // start of file
            if split >= lines.count { penalty += 21 }  // end of file
            let blanksAfter = at == -1 ? 1 + postBlank : 0
            let blanks = preBlank + blanksAfter
            penalty += -30 * blanks + 6 * blanksAfter
            let effective = at != -1 ? at : postIndent
            indent += effective
            if effective == -1 || preIndent == -1 || effective == preIndent {
                return
            } else if effective > preIndent {
                penalty += blanks > 0 ? 10 : -4
            } else if postIndent != -1 && postIndent > effective {
                penalty += blanks > 0 ? 17 : 24
            } else {
                penalty += blanks > 0 ? 17 : 23
            }
        }
    }
}
