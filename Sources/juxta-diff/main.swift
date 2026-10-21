import Foundation
import JuxtaCore

// Command-line front end to JuxtaCore, for scripts (scripts/compare-git.py) and debugging.
// Exit status follows diff: 0 identical, 1 different, 2 trouble.
//
// One `.juxta` file can stand in for the two files: its sides are compared with the options
// saved in it, unless ignore options are given, which then replace them. `--save` writes the
// comparison to a `.juxta` file and prints nothing unless an output mode is given too.

let usage = "usage: juxta-diff [--ignore-whitespace] [--ignore-case] [--ignore-timers]\n"
    + "                  [--stats | --json | --rows | --html [--context N | --all] [--paths]]\n"
    + "                  [--save <out.juxta> [--note <text>]] [--] (<left> <right> | <saved.juxta>)\n"
    + "(either file can be - for standard input)"

enum Mode { case stats, json, rows, html }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("juxta-diff: " + message + "\n").utf8))
    exit(2)
}

var options = DiffOptions()
var mode = Mode.stats
var modeGiven = false
var savePath: String?
var note: String?
var paths: [String] = []
var extent = HTMLReport.Extent.context(3)
var extentGiven = false
var includesPaths = false
var endOfOptions = false
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    if endOfOptions {
        paths.append(argument)
        continue
    }
    switch argument {
    case "--": endOfOptions = true
    case "--ignore-whitespace", "-w": options.ignoreWhitespace = true
    case "--ignore-case", "-i": options.ignoreCase = true
    case "--ignore-timers", "-t": options.ignoreTimers = true
    case "--stats": (mode, modeGiven) = (.stats, true)
    case "--json": (mode, modeGiven) = (.json, true)
    case "--rows": (mode, modeGiven) = (.rows, true)
    case "--html": (mode, modeGiven) = (.html, true)
    case "--save":
        guard let value = arguments.next() else { fail("--save needs a file\n" + usage) }
        savePath = value
    case "--note":
        guard let value = arguments.next() else { fail("--note needs text\n" + usage) }
        note = value
    case "--context":
        guard let value = arguments.next(), let lines = Int(value), lines >= 0 else {
            fail("--context needs a number of lines\n" + usage)
        }
        extent = .context(lines)
        extentGiven = true
    case "--all":
        extent = .all
        extentGiven = true
    case "--paths":
        includesPaths = true
        extentGiven = true
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        if argument.hasPrefix("-") && argument != "-" { fail("unknown option \(argument)\n" + usage) }
        paths.append(argument)
    }
}
/// One path is a saved comparison, if it has the extension the app opens as one.
let opensSaved = paths.count == 1 && URL(fileURLWithPath: paths[0]).pathExtension.lowercased() == "juxta"
guard paths.count == 2 || opensSaved else { fail("expected two files or one .juxta file\n" + usage) }
if extentGiven && mode != .html { fail("--context, --all and --paths go with --html\n" + usage) }
if note != nil && savePath == nil { fail("--note goes with --save\n" + usage) }
// Also keeps --save from taking an input, "-" or an option as the file to write.
if let savePath, URL(fileURLWithPath: savePath).pathExtension.lowercased() != "juxta" {
    fail("--save needs a file ending in .juxta\n" + usage)
}
if paths == ["-", "-"] { fail("only one file can be standard input") }

/// A file and its bytes, kept for --save so the file isn't read twice.
func load(_ path: String) -> (document: TextDocument, data: Data) {
    do {
        if path == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return (try TextDocument(fileData: data, name: "-"), data)
        }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return (try TextDocument(fileData: data, name: url.lastPathComponent, url: url), data)
    } catch let error as TextLoadError {
        fail("\(path): \(error.localizedDescription)")
    } catch {
        fail("\(path): \((error as NSError).localizedDescription)")
    }
}

/// A saved comparison and its sides as compared.
func loadSaved(_ path: String) -> (saved: SavedComparison, left: TextDocument, right: TextDocument) {
    do {
        let saved = try SavedComparison(data: Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe))
        let documents = try saved.documents()
        return (saved, documents.left, documents.right)
    } catch {
        fail("\(path): \(error.localizedDescription)")
    }
}

/// The comparison read from the `.juxta` file, or written by --save. --html and --json
/// describe it as the app's export does: its note, when it was saved and which sides were
/// edited since.
var saved: SavedComparison?
let left: TextDocument, right: TextDocument
var fileData: (left: Data?, right: Data?) = (nil, nil)
if opensSaved {
    let opened = loadSaved(paths[0])
    saved = opened.saved
    left = opened.left
    right = opened.right
    options = opened.saved.options(given: options)
} else {
    let a = load(paths[0]), b = load(paths[1])
    left = a.document
    right = b.document
    fileData = (a.data, b.data)
}

if let savePath {
    do {
        // A saved comparison's sides keep their sources, and their saved digests, so a side
        // edited after it was saved still shows as edited.
        let new = try SavedComparison(saving: left, right, fileData: fileData, previous: (saved?.left, saved?.right),
                                      note: note ?? saved?.note ?? "", options: options)
        try new.encode().write(to: URL(fileURLWithPath: savePath), options: .atomic)
        saved = new
    } catch {
        fail("\(savePath): \(error.localizedDescription)")
    }
}

let start = DispatchTime.now().uptimeNanoseconds
let result = Comparator.compare(left.lines, right.lines, options: options)
let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
let hidden = left.hiddenDifferences(from: right)
// Nil when either side is pasted text (from a .juxta file), which has no bytes of its own.
let byteIdentical = left.isByteIdentical(to: right)
// With an ignore option, differences it hides don't count, as with `diff -w`.
let ignoring = options.ignoresAny
let identical = result.isIdentical && (ignoring || (hidden.isEmpty && byteIdentical != false))

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

// With --save, nothing is printed unless an output mode was asked for.
switch savePath != nil && !modeGiven ? nil : mode {
case nil: break
case .stats:
    print("hunks=\(result.hunks.count) modified=\(result.changedLines) deleted=\(result.deletedLines) "
          + "inserted=\(result.insertedLines) approximate=\(result.isApproximate) "
          + "hidden=\(hidden.isEmpty ? "none" : hidden.map { $0.rawValue.replacingOccurrences(of: " ", with: "-") }.joined(separator: ","))"
          + (byteIdentical.map { " byte-identical=\($0)" } ?? "") + " ms=\(String(format: "%.2f", elapsedMs))")
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
case .html:
    var report = HTMLReport(left: left, right: right, result: result, options: options)
    report.extent = extent
    // Names only unless asked: the page is meant to be shared. Standard input has no path.
    // A saved side has no url; the path it was saved from is shown instead.
    if includesPaths {
        report.leftPath = (left.url?.path ?? saved?.left.path).map(HTMLReport.displayPath)
        report.rightPath = (right.url?.path ?? saved?.right.path).map(HTMLReport.displayPath)
    }
    if let saved { report.describe(saved) }
    FileHandle.standardOutput.write(Data(report.render().utf8))
case .json:
    let hunks: [[String: Any]] = result.hunks.map { hunk in
        let (l, r) = ranges(hunk)
        return ["left": ["start": l.start, "count": l.count], "right": ["start": r.start, "count": r.count],
                "rows": String(result.rows[hunk.rows].map { symbol($0.kind) })]
    }
    // For a .juxta file, the sides' saved names stand in for the paths.
    var object: [String: Any] = [
        "left": opensSaved ? left.name : paths[0], "right": opensSaved ? right.name : paths[1], "identical": identical,
        "leftLines": left.lines.count, "rightLines": right.lines.count,
        "modified": result.changedLines, "deleted": result.deletedLines, "inserted": result.insertedLines,
        "approximate": result.isApproximate, "hiddenDifferences": hidden.map(\.rawValue),
        "byteIdentical": byteIdentical ?? NSNull(),
        "ms": NSDecimalNumber(string: String(format: "%.2f", elapsedMs)), "hunks": hunks,
    ]
    if let saved {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        object["saved"] = [
            "note": saved.note, "date": formatter.string(from: saved.saved),
            "edited": [(saved.left, "left"), (saved.right, "right")].filter { !$0.0.matchesDigest }.map(\.1),
        ] as [String: Any]
    }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}
exit(identical ? 0 : 1)
