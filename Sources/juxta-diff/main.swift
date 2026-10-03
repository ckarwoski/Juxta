import Foundation
import JuxtaCore

// Command-line front end to JuxtaCore, for scripts (scripts/compare-git.py) and debugging.
// Exit status follows diff: 0 identical, 1 different, 2 trouble.

let usage = "usage: juxta-diff [--ignore-whitespace] [--ignore-case] [--stats|--json|--rows] [--] <left> <right>\n"
    + "(either file can be - for standard input)"

enum Mode { case stats, json, rows }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("juxta-diff: " + message + "\n").utf8))
    exit(2)
}

var options = DiffOptions()
var mode = Mode.stats
var paths: [String] = []
var endOfOptions = false
for argument in CommandLine.arguments.dropFirst() {
    if endOfOptions {
        paths.append(argument)
        continue
    }
    switch argument {
    case "--": endOfOptions = true
    case "--ignore-whitespace", "-w": options.ignoreWhitespace = true
    case "--ignore-case", "-i": options.ignoreCase = true
    case "--stats": mode = .stats
    case "--json": mode = .json
    case "--rows": mode = .rows
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        if argument.hasPrefix("-") && argument != "-" { fail("unknown option \(argument)\n" + usage) }
        paths.append(argument)
    }
}
guard paths.count == 2 else { fail("expected two files\n" + usage) }
if paths == ["-", "-"] { fail("only one file can be standard input") }

func load(_ path: String) -> TextDocument {
    do {
        if path == "-" {
            return try TextDocument(fileData: FileHandle.standardInput.readDataToEndOfFile(), name: "-")
        }
        return try TextDocument.load(from: URL(fileURLWithPath: path))
    } catch let error as TextLoadError {
        fail("\(path): \(error.localizedDescription)")
    } catch {
        fail("\(path): \((error as NSError).localizedDescription)")
    }
}

let left = load(paths[0]), right = load(paths[1])
let start = DispatchTime.now().uptimeNanoseconds
let result = Comparator.compare(left.lines, right.lines, options: options)
let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
let hidden = left.hiddenDifferences(from: right)
let byteIdentical = left.isByteIdentical(to: right) ?? false
// With an ignore option, differences it hides don't count, as with `diff -w`.
let ignoring = options.ignoreWhitespace || options.ignoreCase
let identical = result.isIdentical && (ignoring || (hidden.isEmpty && byteIdentical))

/// 1-based first line of each side's part of a hunk (for an empty part, the line it
/// comes before), and how many lines it has.
func ranges(_ hunk: Hunk) -> (left: (start: Int, count: Int), right: (start: Int, count: Int)) {
    let rows = result.rows[hunk.rows]
    // The row before a hunk is always a .same row with lines on both sides.
    let previous = hunk.rows.lowerBound > 0 ? result.rows[hunk.rows.lowerBound - 1] : nil
    return ((Int(previous?.left ?? -1) + 2, rows.filter { $0.left >= 0 }.count),
            (Int(previous?.right ?? -1) + 2, rows.filter { $0.right >= 0 }.count))
}

func symbol(_ kind: RowKind) -> Character {
    switch kind {
    case .same: return " "
    case .changed: return "~"
    case .deleted: return "-"
    case .inserted: return "+"
    }
}

/// The line with each highlighted range wrapped in brackets.
func marked(_ line: String, _ highlights: [NSRange]) -> String {
    let text = line as NSString
    var out = "", position = 0
    for range in highlights {
        out += text.substring(with: NSRange(location: position, length: range.location - position))
        out += "[" + text.substring(with: range) + "]"
        position = NSMaxRange(range)
    }
    return out + text.substring(from: position)
}

switch mode {
case .stats:
    print("hunks=\(result.hunks.count) modified=\(result.changedLines) deleted=\(result.deletedLines) "
          + "inserted=\(result.insertedLines) approximate=\(result.isApproximate) "
          + "hidden=\(hidden.isEmpty ? "none" : hidden.map { $0.rawValue.replacingOccurrences(of: " ", with: "-") }.joined(separator: ","))"
          + " byte-identical=\(byteIdentical) ms=\(String(format: "%.2f", elapsedMs))")
case .rows:
    for row in result.rows {
        let a = row.left >= 0 ? left.lines[Int(row.left)] : ""
        let b = row.right >= 0 ? right.lines[Int(row.right)] : ""
        switch row.kind {
        case .same: print("  " + a)
        case .deleted: print("- " + a)
        case .inserted: print("+ " + b)
        case .changed:
            let inline = Comparator.inlineChanges(a, b, options: options)
            print("~ " + marked(a, inline?.left ?? []) + " => " + marked(b, inline?.right ?? []))
        }
    }
case .json:
    let hunks: [[String: Any]] = result.hunks.map { hunk in
        let (l, r) = ranges(hunk)
        return ["left": ["start": l.start, "count": l.count], "right": ["start": r.start, "count": r.count],
                "rows": String(result.rows[hunk.rows].map { symbol($0.kind) })]
    }
    let object: [String: Any] = [
        "left": paths[0], "right": paths[1], "identical": identical,
        "leftLines": left.lines.count, "rightLines": right.lines.count,
        "modified": result.changedLines, "deleted": result.deletedLines, "inserted": result.insertedLines,
        "approximate": result.isApproximate, "hiddenDifferences": hidden.map(\.rawValue),
        "byteIdentical": byteIdentical, "ms": NSDecimalNumber(string: String(format: "%.2f", elapsedMs)), "hunks": hunks,
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}
exit(identical ? 0 : 1)
