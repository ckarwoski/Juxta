import Foundation

/// The words that sum up a comparison, shared by the window's subtitle and exported pages
/// so both say the same thing.
public enum ComparisonSummary {
    /// The outcome, then hidden differences, ignored options and whether the result is
    /// approximate: "3 changes", "11 modified", "differs in encoding", "ignoring timers".
    /// Counts are formatted for `locale`. `currentHunk` says "Change 2 of 3" in place of the
    /// count; `listsIgnored` leaves out the ignored options when they are shown elsewhere.
    public static func parts(_ result: DiffResult, left: TextDocument, right: TextDocument, options: DiffOptions,
                             locale: Locale, currentHunk: Int? = nil, listsIgnored: Bool = true) -> [String] {
        func number(_ value: Int) -> String { value.formatted(.number.locale(locale)) }
        var parts: [String] = []
        // Lines are compared without encoding and line endings, so those differences
        // are reported here; the files must never look identical when they aren't.
        let hidden = left.hiddenDifferences(from: right)
        let bytesSame = left.isByteIdentical(to: right)
        if result.isIdentical {
            if !hidden.isEmpty {
                parts.append("Same text")
            } else if bytesSame == false && !options.ignoresAny {
                parts.append("Same text, but the files aren't byte-for-byte identical")
            } else if bytesSame == true {
                // Only when the bytes match; for pasted text, or same text with ignore
                // options on, "no differences" is all that was checked.
                parts.append(result.rows.isEmpty ? "Both files are empty" : "Files are identical")
            } else {
                parts.append("No differences")
            }
        } else {
            let count = result.hunks.count
            if let currentHunk {
                parts.append("Change \(number(currentHunk + 1)) of \(number(count))")
            } else {
                parts.append(count == 1 ? "1 change" : "\(number(count)) changes")
            }
            if result.changedLines > 0 { parts.append("\(number(result.changedLines)) modified") }
            if result.deletedLines > 0 { parts.append("\(number(result.deletedLines)) removed") }
            if result.insertedLines > 0 { parts.append("\(number(result.insertedLines)) added") }
        }
        var ignoring: [String] = []
        if options.ignoreWhitespace { ignoring.append("whitespace") }
        if options.ignoreCase { ignoring.append("case") }
        if options.ignoreTimers { ignoring.append("timers") }
        if !hidden.isEmpty { parts.append("differs in " + listed(hidden.map(\.rawValue))) }
        if !ignoring.isEmpty && listsIgnored { parts.append("ignoring " + listed(ignoring)) }
        if result.isApproximate { parts.append("approximate (comparison timed out)") }
        return parts
    }

    /// The options that are on, as the menu names them.
    public static func optionTitles(_ options: DiffOptions) -> [String] {
        [(options.ignoreWhitespace, "Ignore Whitespace"), (options.ignoreCase, "Ignore Case"),
         (options.ignoreTimers, "Ignore Timers")].filter(\.0).map(\.1)
    }

    /// "a", "a & b", "a, b & c".
    public static func listed(_ items: [String]) -> String {
        guard let last = items.last, items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " & " + last
    }
}
