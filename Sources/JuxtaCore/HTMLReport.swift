import Foundation

/// A comparison as one self-contained HTML page, to share with people who don't have
/// Juxta: a header with the names, note, date, options and counts, then both sides next to
/// each other with the app's row colors and changed characters highlighted.
///
/// The page has inline CSS and nothing else: no scripts and no external resources. It is
/// also well-formed XML, so it can be checked with a parser. Everything from the
/// documents is escaped; banners and descriptions contain `<` and `&`.
public struct HTMLReport: Sendable {
    public enum Extent: Equatable, Sendable {
        /// The changes, each with this many unchanged lines around it.
        case context(Int)
        case all
    }

    public var left: TextDocument
    public var right: TextDocument
    public var result: DiffResult
    public var options: DiffOptions
    /// Where each side came from, shown after its name. Nil (the default) shows names only,
    /// since the page is meant to be shared; see `displayPath(_:)`.
    public var leftPath: String?
    public var rightPath: String?
    public var note = ""
    /// Shown under the note, as warnings: "The right side was edited after it was saved".
    public var notices: [String] = []
    public var date = Date()
    /// What `date` is, shown before it: "Saved" or "Exported".
    public var dateLabel = "Exported"
    public var extent = Extent.context(3)
    /// Shows at most this many changes, then a line saying how many more there are.
    public var changeLimit: Int?
    /// Shows at most this many rows of changes, not counting context. The change that runs
    /// past it is cut off, for pages of unrelated files that are one change all through.
    public var rowLimit: Int?
    /// Stops adding rows once the rows shown take this many bytes of HTML, for pages of
    /// long lines. Checked before each row, so the last row can go past it.
    public var byteLimit: Int?
    public var timeZone = TimeZone.current
    public var locale = Locale.current

    public init(left: TextDocument, right: TextDocument, result: DiffResult, options: DiffOptions) {
        self.left = left
        self.right = right
        self.result = result
        self.options = options
    }

    /// Describes the page as the saved comparison `saved`: its note, when it was saved and
    /// which sides were edited since. Shared by `juxta-diff --html` and Quick Look so they
    /// say the same thing; paths are left as they are.
    public mutating func describe(_ saved: SavedComparison) {
        note = saved.note
        date = saved.saved
        dateLabel = "Saved"
        notices = [saved.editedNotice].compactMap { $0 }
    }

    /// A path as the page shows it, with the home folder as `~`.
    public static func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    public func render() -> String {
        let (ranges, omitted, cut) = shownRows()
        var out = ""
        let shownCount = ranges.reduce(0) { $0 + $1.count }
        out.reserveCapacity(8_000 + shownCount * 160)
        out += "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\"/>\n"
        out += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"/>\n"
        out += "<meta name=\"color-scheme\" content=\"light dark\"/>\n<meta name=\"generator\" content=\"Juxta\"/>\n<title>"
        Self.appendEscaped(note.isEmpty ? "\(left.name) vs \(right.name)" : note, to: &out)
        out += "</title>\n<style>\n"
        out += Self.css
        let digits = String(max(left.lines.count, right.lines.count, 1)).count
        out += "col.n { width: calc(\(digits)ch + 14px); }\n</style>\n</head>\n<body>\n"
        appendHeader(to: &out)
        var (rowsLeft, changesLeft) = (cut, omitted)
        if let stop = appendBody(ranges, truncated: omitted > 0 || cut > 0, to: &out) {
            (rowsLeft, changesLeft) = remainder(from: stop)
        }
        if rowsLeft > 0 || changesLeft > 0 {
            var more: [String] = []
            if rowsLeft > 0 { more.append("\(number(rowsLeft)) more \(rowsLeft == 1 ? "row" : "rows") of this change") }
            if changesLeft > 0 { more.append("\(number(changesLeft)) more \(changesLeft == 1 ? "change" : "changes")") }
            out += "<p class=\"more\">\(more.joined(separator: " and ")) not shown</p>\n"
        }
        out += "</body>\n</html>\n"
        return out
    }

    // MARK: - Rows

    /// The runs of rows to show, in order, how many changes were left out, and how many
    /// rows of the last change shown were cut off by `rowLimit`.
    func shownRows() -> (ranges: [Range<Int>], omitted: Int, cut: Int) {
        let count = result.rows.count
        var hunks = changeLimit.map { Array(result.hunks.prefix(max(0, $0))) } ?? result.hunks
        var cut = 0
        if let rowLimit {
            var remaining = max(0, rowLimit)
            for (index, hunk) in hunks.enumerated() {
                guard hunk.rows.count > remaining else {
                    remaining -= hunk.rows.count
                    continue
                }
                hunks.removeSubrange(index...)
                // A change with no room left is left out whole.
                if remaining > 0 {
                    hunks.append(Hunk(rows: hunk.rows.lowerBound..<hunk.rows.lowerBound + remaining))
                    cut = hunk.rows.count - remaining
                }
                break
            }
        }
        let omitted = result.hunks.count - hunks.count
        let truncated = omitted > 0 || cut > 0
        switch extent {
        case .all:
            let end = truncated ? hunks.last?.rows.upperBound ?? 0 : count
            return (end > 0 ? [0..<end] : [], omitted, cut)
        case .context(let lines):
            let lines = max(0, lines)
            var ranges: [Range<Int>] = []
            for (index, hunk) in hunks.enumerated() {
                // A change that was cut off has no context after it.
                let after = cut > 0 && index == hunks.count - 1 ? 0 : lines
                var range = max(0, hunk.rows.lowerBound - lines)..<min(count, hunk.rows.upperBound + after)
                // A single hidden line is shown instead: its separator would be as tall.
                if range.lowerBound == 1 { range = 0..<range.upperBound }
                if range.upperBound == count - 1 && !truncated { range = range.lowerBound..<count }
                // Changes closer than 2N lines share their context.
                if let last = ranges.last, range.lowerBound <= last.upperBound + 1 {
                    ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
                } else {
                    ranges.append(range)
                }
            }
            return (ranges, omitted, cut)
        }
    }

    /// Adds the table of rows. Returns the first row left out when `byteLimit` stopped it,
    /// or nil when every row in `ranges` was added.
    @discardableResult
    private func appendBody(_ ranges: [Range<Int>], truncated: Bool, to out: inout String) -> Int? {
        let rows = result.rows
        guard !rows.isEmpty else { return nil }
        // When changes were left out or cut off, the line saying so follows the last one
        // shown instead of a count of the lines after it.
        var trailingSkip = !truncated || ranges.isEmpty
        out += "<table class=\"diff\">\n<colgroup><col class=\"n\"/><col class=\"s\"/><col class=\"t\"/>"
        out += "<col class=\"n\"/><col class=\"s\"/><col class=\"t\"/></colgroup>\n<tbody>\n"
        let start = out.utf8.count
        var position = 0
        var stop: Int?
        rows: for range in ranges {
            if range.lowerBound > position { appendSkip(range.lowerBound - position, to: &out) }
            for index in range {
                if let byteLimit, out.utf8.count - start >= byteLimit {
                    stop = index
                    break rows
                }
                appendRow(rows[index], to: &out)
            }
            position = range.upperBound
        }
        if let stop {
            // With no changes after it, the rest is counted as unchanged lines as usual.
            position = stop
            trailingSkip = remainder(from: stop) == (0, 0)
        }
        if trailingSkip && position < rows.count { appendSkip(rows.count - position, to: &out) }
        out += "</tbody>\n</table>\n"
        return stop
    }

    /// What isn't shown when the page stops before `row`: the rest of the change it stops
    /// in, if some of that change was shown, and the changes after it.
    private func remainder(from row: Int) -> (rows: Int, changes: Int) {
        if let index = result.hunk(containing: row), result.hunks[index].rows.lowerBound < row {
            return (result.hunks[index].rows.upperBound - row, result.hunks.count - index - 1)
        }
        return (0, result.hunks.count - result.firstHunk(atOrAfter: row))
    }

    private func appendSkip(_ count: Int, to out: inout String) {
        out += "<tr class=\"skip\"><td colspan=\"6\">⋯ \(number(count)) unchanged \(count == 1 ? "line" : "lines")</td></tr>\n"
    }

    private func appendRow(_ row: DiffRow, to out: inout String) {
        let a = row.left >= 0 ? left.lines[Int(row.left)] : nil
        let b = row.right >= 0 ? right.lines[Int(row.right)] : nil
        var inline: InlineChanges?
        var trailingDiffers = true
        if row.kind == .changed, let a, let b {
            inline = Comparator.inlineChanges(a, b, options: options)
            trailingDiffers = Invisibles.trailingWhitespace(a) != Invisibles.trailingWhitespace(b)
        }
        let (kind, sign): (String, String) = switch row.kind {
        case .same: ("", "")
        case .changed: (" c", "~")
        case .deleted: (" d", "−")
        case .inserted: (" i", "+")
        }
        out += "<tr>"
        for (line, number, highlights) in [(a, row.left, inline?.left), (b, row.right, inline?.right)] {
            guard let line else {
                out += "<td class=\"n\"></td><td class=\"s\"></td><td class=\"t f\"></td>"
                continue
            }
            out += "<td class=\"n\(kind)\">\(number + 1)</td><td class=\"s\(kind)\">\(sign)</td><td class=\"t\(kind)\">"
            // Invisibles are marked only on rows that differ, as in the app.
            let marks = row.kind != .same
            Self.appendLine(line, highlights: highlights ?? [], marksInvisibles: marks,
                            marksTrailing: marks && trailingDiffers, to: &out)
            out += "</td>"
        }
        out += "</tr>\n"
    }

    // MARK: - Header

    private func appendHeader(to out: inout String) {
        out += "<header>\n<h1>"
        Self.appendEscaped(left.name, to: &out)
        out += " <span class=\"vs\">vs</span> "
        Self.appendEscaped(right.name, to: &out)
        out += "</h1>\n"
        if !note.isEmpty {
            out += "<p class=\"note\">"
            Self.appendEscaped(note, to: &out)
            out += "</p>\n"
        }
        for notice in notices {
            out += "<p class=\"notice\">"
            Self.appendEscaped(notice, to: &out)
            out += "</p>\n"
        }
        out += "<table class=\"sides\"><tbody>\n"
        appendSide("Left", left, path: leftPath, other: right, to: &out)
        appendSide("Right", right, path: rightPath, other: left, to: &out)
        out += "</tbody></table>\n<p class=\"meta\">"
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale,
                                     calendar: Calendar(identifier: .gregorian), timeZone: timeZone)
        var meta = [dateLabel + " " + date.formatted(style)]
        let titles = ComparisonSummary.optionTitles(options)
        if !titles.isEmpty { meta.append(ComparisonSummary.listed(titles)) }
        Self.appendEscaped(meta.joined(separator: " · "), to: &out)
        out += "</p>\n<p class=\"summary\(result.isIdentical ? " same" : "")\">"
        let parts = ComparisonSummary.parts(result, left: left, right: right, options: options, locale: locale,
                                            listsIgnored: false)
        Self.appendEscaped(parts.joined(separator: " · "), to: &out)
        out += "</p>\n</header>\n"
    }

    private func appendSide(_ label: String, _ document: TextDocument, path: String?, other: TextDocument,
                            to out: inout String) {
        out += "<tr><th>\(label)</th><td class=\"name\">"
        Self.appendEscaped(document.name, to: &out)
        out += "</td><td class=\"where\">"
        let lines = number(document.lines.count) + (document.lines.count == 1 ? " line" : " lines")
        Self.appendEscaped((path ?? (document.format == nil ? "Pasted text" : "File")) + " · " + lines, to: &out)
        out += "</td><td class=\"format\">"
        // The same labels as the pane headers, with the ones that differ stressed.
        if let format = document.format {
            let differing = other.format.map { format.differences(from: $0) } ?? []
            var first = true
            for aspect in TextFormat.Aspect.allCases {
                guard let text = format.label(for: aspect) else { continue }
                if !first { out += " · " }
                first = false
                if differing.contains(aspect) {
                    out += "<strong>"
                    Self.appendEscaped(text, to: &out)
                    out += "</strong>"
                } else {
                    Self.appendEscaped(text, to: &out)
                }
            }
        }
        out += "</td></tr>\n"
    }

    private func number(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }

    // MARK: - Text

    /// Escapes text for an element or attribute.
    static func appendEscaped(_ text: String, to out: inout String) {
        guard text.utf8.contains(where: { $0 == 0x26 || $0 == 0x3C || $0 == 0x3E || $0 == 0x22 || $0 < 0x20 })
        else { return out += text }
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\n", "\r": out += " "
            default:
                if scalar.value < 0x20 && scalar != "\t" { out += " " } else { out.unicodeScalars.append(scalar) }
            }
        }
    }

    /// Whether a line can be copied into the page as it is: printable ASCII, tabs, and
    /// nothing that needs escaping.
    private static func isPlain(_ line: String) -> Bool {
        line.utf8.allSatisfy { byte in
            (byte >= 0x20 && byte < 0x7F && byte != 0x26 && byte != 0x3C && byte != 0x3E && byte != 0x22) || byte == 0x09
        }
    }

    /// Characters that can't be in the page as they are: controls, and code points that
    /// aren't characters. They always get a badge, even on unchanged rows.
    private static func mustBadge(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value < 0x20 && scalar != "\t") || (0x7F...0x9F).contains(scalar.value)
            || scalar.properties.isNoncharacterCodePoint
    }

    /// One line's text: highlights (UTF-16 ranges) as `<span class="h">`, trailing
    /// whitespace as `<span class="w">`, and characters that draw nothing as badges with
    /// the app's labels. Spans are closed and reopened where they cross, so they nest.
    static func appendLine(_ line: String, highlights: [NSRange], marksInvisibles: Bool, marksTrailing: Bool,
                           to out: inout String) {
        if highlights.isEmpty && !marksInvisibles && isPlain(line) { return out += line }
        let length = line.utf16.count
        let trailingLength = marksTrailing ? Invisibles.trailingWhitespace(line).utf16.count : 0
        let trailingStart = trailingLength > 0 ? length - trailingLength : Int.max
        var next = 0 // first highlight not wholly before the current offset
        var open: (highlight: Bool, trailing: Bool) = (false, false)
        var offset = 0
        func spans(at offset: Int) {
            while next < highlights.count && NSMaxRange(highlights[next]) <= offset { next += 1 }
            let highlight = next < highlights.count && highlights[next].location <= offset
            let trailing = offset >= trailingStart
            guard (highlight, trailing) != open else { return }
            close()
            if trailing { out += "<span class=\"w\">" }
            if highlight { out += "<span class=\"h\">" }
            open = (highlight, trailing)
        }
        func close() {
            if open.highlight { out += "</span>" }
            if open.trailing { out += "</span>" }
            open = (false, false)
        }
        for scalar in line.unicodeScalars {
            spans(at: offset)
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                if (marksInvisibles || mustBadge(scalar)), let label = Invisibles.badgeLabel(scalar) {
                    out += "<span class=\"b\">\(label)</span>"
                } else if mustBadge(scalar) {
                    out += "<span class=\"b\">" + String(format: "U+%04X", scalar.value) + "</span>"
                } else if marksInvisibles && Invisibles.isUnusualSpace(scalar) {
                    out += "<span class=\"u\" title=\"" + String(format: "U+%04X", scalar.value) + "\">"
                    out.unicodeScalars.append(scalar)
                    out += "</span>"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
            offset += scalar.utf16.count
        }
        close()
    }

    // MARK: - Style

    /// Colors from `Theme` in the app, for light, dark and Increase Contrast. Printing
    /// uses the light colors and keeps the row backgrounds.
    static let css = """
        :root {
          --bg: #ffffff; --fg: #000000; --muted: #69696e; --rule: #d8d8dc; --header: #f2f2f4;
          --del: #ffe9e9; --ins: #e4f7e5; --chg: #e6efff; --hl: #b2cdff; --hl-border: transparent;
          --fill: #f6f6f7; --hatch: #e2e2e5; --badge: rgba(0, 0, 0, 0.07); --invisible: rgba(0, 0, 0, 0.26);
          --trail: rgba(255, 158, 26, 0.22); --differs: #a84e00;
          --sign-c: #007aff; --sign-d: #ff3b30; --sign-i: #28a745;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #1e1e1e; --fg: #ffffffd9; --muted: #aaaab0; --rule: #3a3a3c; --header: #2a2a2c;
            --del: #542125; --ins: #1b4626; --chg: #1d3258; --hl: #325caa;
            --fill: #242426; --hatch: #36363a; --badge: rgba(255, 255, 255, 0.1); --invisible: rgba(255, 255, 255, 0.25);
            --trail: rgba(255, 158, 26, 0.28); --differs: #ff9f0a;
            --sign-c: #0a84ff; --sign-d: #ff453a; --sign-i: #30d158;
          }
        }
        @media (prefers-contrast: more) {
          :root {
            --muted: #404044; --del: #ffccce; --ins: #c4eec8; --chg: #ccdeff; --hl: #80aafa; --hl-border: #0040be;
            --fill: #eeeef0; --hatch: #b0b0b6; --badge: rgba(0, 0, 0, 0.14); --trail: rgba(255, 140, 0, 0.4);
            --differs: #8c3e00;
          }
        }
        @media (prefers-color-scheme: dark) and (prefers-contrast: more) {
          :root {
            --muted: #e8e8ec; --del: #6e1e26; --ins: #165828; --chg: #1c3870; --hl: #2852a4; --hl-border: #96c3ff;
            --fill: #28282b; --hatch: #54545a; --badge: rgba(255, 255, 255, 0.2); --trail: rgba(255, 158, 26, 0.45);
            --differs: #ff9f0a;
          }
        }
        * { box-sizing: border-box; }
        html { -webkit-text-size-adjust: 100%; }
        body { margin: 0; background: var(--bg); color: var(--fg);
          font: 13px -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
        header { padding: 16px 20px 12px; background: var(--header); border-bottom: 1px solid var(--rule); }
        h1 { margin: 0 0 6px; font-size: 17px; font-weight: 600; overflow-wrap: anywhere; }
        h1 .vs { color: var(--muted); font-weight: 400; }
        header p { margin: 4px 0; overflow-wrap: anywhere; }
        .note { font-size: 14px; }
        .notice { color: var(--differs); font-weight: 600; }
        .meta, .where, .format { color: var(--muted); }
        .format strong { color: var(--differs); }
        .summary { font-weight: 600; }
        table.sides { border-collapse: collapse; margin: 6px 0; }
        table.sides th, table.sides td { padding: 1px 12px 1px 0; text-align: left; vertical-align: baseline;
          overflow-wrap: anywhere; }
        table.sides th { color: var(--muted); font-weight: 400; }
        table.sides .name { font-weight: 600; }
        table.diff { width: 100%; table-layout: fixed; border-collapse: collapse;
          font: 12px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; tab-size: 4; -moz-tab-size: 4; }
        col.s { width: 18px; }
        table.diff td { padding: 0 6px 0 0; vertical-align: top; }
        td.n { text-align: right; color: var(--muted); padding-left: 6px; user-select: none; -webkit-user-select: none; }
        td.s { text-align: center; padding: 0; user-select: none; -webkit-user-select: none; font-weight: 700; }
        td.s.c { color: var(--sign-c); } td.s.d { color: var(--sign-d); } td.s.i { color: var(--sign-i); }
        td.t { white-space: pre-wrap; overflow-wrap: anywhere; padding-left: 4px; }
        td.t + td.n { border-left: 1px solid var(--rule); }
        .c { background: var(--chg); } .d { background: var(--del); } .i { background: var(--ins); }
        td.f { background: repeating-linear-gradient(-45deg, var(--hatch) 0 1px, var(--fill) 1px 7px); }
        .h { background: var(--hl); border-radius: 2px; box-shadow: inset 0 0 0 1.5px var(--hl-border); }
        .w { background: var(--trail); }
        .b { display: inline-block; margin: 0 1px; padding: 0 2px; border-radius: 3px; background: var(--badge);
          box-shadow: inset 0 0 0 0.5px var(--invisible); font-size: 8px; line-height: 13px; vertical-align: 1px;
          font-weight: 500; }
        .u { outline: 1px dotted var(--invisible); outline-offset: -2px; }
        tr.skip td { padding: 3px 12px; color: var(--muted); background: var(--header);
          border-top: 1px solid var(--rule); border-bottom: 1px solid var(--rule);
          font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; font-size: 12px; }
        .more { margin: 0; padding: 10px 20px; color: var(--muted); border-top: 1px solid var(--rule); }
        @media print {
          :root {
            --bg: #ffffff; --fg: #000000; --muted: #555559; --rule: #c8c8cc; --header: #f2f2f4;
            --del: #ffe9e9; --ins: #e4f7e5; --chg: #e6efff; --hl: #b2cdff; --hl-border: transparent;
            --fill: #f6f6f7; --hatch: #e2e2e5; --badge: rgba(0, 0, 0, 0.07); --invisible: rgba(0, 0, 0, 0.3);
            --trail: rgba(255, 158, 26, 0.22); --differs: #a84e00;
            --sign-c: #007aff; --sign-d: #ff3b30; --sign-i: #28a745;
          }
          * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
          tr { break-inside: avoid; page-break-inside: avoid; }
          header { break-after: avoid; }
        }

        """
}
