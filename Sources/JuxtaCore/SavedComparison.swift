import CryptoKit
import Foundation

public enum SavedComparisonError: LocalizedError {
    /// A file side's bytes no longer match what was compared.
    case fileChanged(String)
    /// A file side couldn't be read again to save it.
    case fileMissing(String)
    case newerVersion(Int)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .fileChanged(let name): return "“\(name)” changed since it was loaded."
        case .fileMissing(let name): return "“\(name)” can’t be found where it was loaded from."
        case .newerVersion(let version):
            return "This comparison was saved by a newer version of Juxta (format \(version))."
        case .malformed(let reason): return "This isn’t a valid Juxta comparison: \(reason)."
        }
    }
}

/// A comparison saved to a `.juxta` file: both sides' original bytes, with the names,
/// note and options they were compared with. See docs/saved-comparisons.md for the format.
public struct SavedComparison: Sendable {
    public struct Side: Sendable {
        public enum Source: Equatable, Sendable {
            case pasted
            /// Where the file was loaded from; only for reference, never read again.
            case file(String)
        }

        public var name: String
        public var source: Source
        /// The file's bytes exactly as compared; UTF-8 for pasted text.
        public let bytes: Data
        /// The SHA-256 written in the file, as lowercase hex.
        public let sha256: String
        /// False when the bytes were edited after saving, so they no longer match `sha256`.
        public let matchesDigest: Bool

        /// A side to save. Pasted text is saved as UTF-8. A file side needs its bytes read
        /// again from disk (`fileData`, nil if that failed), and they must still match the
        /// digest from when it was loaded, so nothing is saved that wasn't compared.
        ///
        /// A side reopened from a saved comparison has no file to read. `previous` is the
        /// sides of the comparison it was opened from, and order matters: the side this one
        /// was opened as goes first, then the other, since both sides can hold the same
        /// bytes. `init(saving:…)` passes them in that order. The first one holding this
        /// document's text is kept: a file side with the same bytes for a document with no
        /// url, or a pasted side with the same lines for pasted text. Its saved SHA-256 is
        /// kept too, so a side edited after it was saved still shows as edited when saved
        /// again.
        public init(document: TextDocument, fileData: Data?, previous: [Side] = []) throws {
            guard let digest = document.digest else {
                // Pasted text has no digest; its lines tell whether a previous side is the same text.
                if let match = try previous.first(where: {
                    try $0.source == .pasted && $0.document().lines == document.lines
                }) {
                    self.init(name: document.name, source: .pasted, bytes: match.bytes, sha256: match.sha256)
                    return
                }
                // Each line gets its own "\n" so a trailing empty line survives.
                let text = document.lines.map { $0 + "\n" }.joined()
                self.init(name: document.name, source: .pasted, bytes: Data(text.utf8))
                return
            }
            // A document with a url was loaded from disk since, so it's read again instead.
            if document.url == nil, let match = previous.first(where: {
                if case .file = $0.source { return SHA256.hash(data: $0.bytes) == digest }
                return false
            }) {
                self.init(name: document.name, source: match.source, bytes: match.bytes, sha256: match.sha256)
                return
            }
            guard let fileData else { throw SavedComparisonError.fileMissing(document.name) }
            guard SHA256.hash(data: fileData) == digest else {
                throw SavedComparisonError.fileChanged(document.name)
            }
            // No url for standard input; its name ("-") stands in for the path.
            self.init(name: document.name, source: .file(document.url?.path ?? document.name), bytes: fileData)
        }

        public init(name: String, source: Source, bytes: Data) {
            self.init(name: name, source: source, bytes: bytes, sha256: Self.hex(SHA256.hash(data: bytes)))
        }

        fileprivate init(name: String, source: Source, bytes: Data, sha256: String) {
            self.name = name
            self.source = source
            self.bytes = bytes
            self.sha256 = sha256
            matchesDigest = Self.hex(SHA256.hash(data: bytes)) == sha256
        }

        /// The side as compared: a file side gets its format and digest back, and pasted
        /// text stays pasted. Throws if a file side's bytes aren't text.
        public func document() throws -> TextDocument {
            switch source {
            case .pasted: return TextDocument(text: String(decoding: bytes, as: UTF8.self), name: name)
            case .file: return try TextDocument(fileData: bytes, name: name, url: nil)
            }
        }

        /// The path a file side was loaded from; nil for pasted text and for standard
        /// input, whose source "-" isn't a path.
        public var path: String? {
            if case .file(let path) = source, !path.isEmpty, path != "-" { return path }
            return nil
        }

        private static func hex(_ digest: SHA256.Digest) -> String {
            digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    public var note: String
    public var saved: Date
    public var options: DiffOptions
    public var left: Side
    public var right: Side

    static let version = 1

    public init(note: String = "", saved: Date = Date(), options: DiffOptions, left: Side, right: Side) {
        self.note = note
        self.saved = saved
        self.options = options
        self.left = left
        self.right = right
    }

    /// A comparison to save from the two documents compared. `fileData` is each file
    /// side's bytes as read for saving (nil for pasted text, or a side with no file).
    /// `previous` is the saved side each document was opened as, if any; each document
    /// looks in its own first, then the other's (see `Side.init(document:fileData:previous:)`).
    /// An empty name keeps the document's own.
    public init(saving left: TextDocument, _ right: TextDocument,
                fileData: (left: Data?, right: Data?) = (nil, nil),
                previous: (left: Side?, right: Side?) = (nil, nil),
                names: (left: String, right: String) = ("", ""),
                note: String = "", saved: Date = Date(), options: DiffOptions) throws {
        func side(_ document: TextDocument, _ data: Data?, _ own: Side?, _ other: Side?,
                  _ name: String) throws -> Side {
            var side = try Side(document: document, fileData: data, previous: [own, other].compactMap { $0 })
            if !name.isEmpty { side.name = name }
            return side
        }
        self.init(note: note, saved: saved, options: options,
                  left: try side(left, fileData.left, previous.left, previous.right, names.left),
                  right: try side(right, fileData.right, previous.right, previous.left, names.right))
    }

    public func documents() throws -> (left: TextDocument, right: TextDocument) {
        (try left.document(), try right.document())
    }

    /// The options to compare with: the saved ones, unless any are given (on the command
    /// line), which then replace the saved ones entirely.
    public func options(given: DiffOptions) -> DiffOptions {
        given.ignoresAny ? given : options
    }

    /// The warning for sides whose bytes were edited after they were saved, or nil.
    public static func editedNotice(left: Bool, right: Bool) -> String? {
        switch (left, right) {
        case (false, false): return nil
        case (true, true): return "Both sides were edited after they were saved"
        default: return "The \(left ? "left" : "right") side was edited after it was saved"
        }
    }

    public var editedNotice: String? {
        Self.editedNotice(left: !left.matchesDigest, right: !right.matchesDigest)
    }

    // MARK: - Writing

    public func encode() -> Data {
        var header = "juxta-comparison \(Self.version)\n"
        func line(_ key: String, _ value: String) {
            // Values are one line, so a header can't be broken by what's in them.
            let flat = value.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            header += flat.isEmpty ? "\(key):\n" : "\(key): \(flat)\n"
        }
        line("saved", Self.dateFormatter().string(from: saved))
        line("note", note)
        line("options", Self.optionNames.filter { options[keyPath: $0.1] }.map(\.0).joined(separator: " "))
        for (label, side) in [("left", left), ("right", right)] {
            header += "\n\(label)\n"
            line("name", side.name)
            switch side.source {
            case .pasted: line("source", "pasted")
            case .file(let path): line("source", path)
            }
            line("bytes", String(side.bytes.count))
            line("sha256", side.sha256)
        }
        // The header ends with a blank line before "--- left"; each body is followed by "\n".
        var data = Data(header.utf8)
        for (label, side) in [("left", left), ("right", right)] {
            data.append(Data("\n--- \(label)\n".utf8))
            data.append(side.bytes)
        }
        data.append(0x0A)
        return data
    }

    // MARK: - Reading

    public init(data: Data) throws {
        // `data` may be a slice, so positions are its own indices.
        var position = data.startIndex
        /// The next line without its "\n", or nil at the end of the data.
        func nextLine() -> String? {
            guard position < data.endIndex else { return nil }
            let end = data[position...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = String(decoding: data[position..<end], as: UTF8.self)
            position = min(end + 1, data.endIndex)
            return line
        }

        guard let first = nextLine(), first.hasPrefix("juxta-comparison "),
              let version = Int(first.dropFirst("juxta-comparison ".count)), version >= 1 else {
            throw SavedComparisonError.malformed("the first line isn’t “juxta-comparison 1”")
        }
        guard version <= Self.version else { throw SavedComparisonError.newerVersion(version) }

        // Header fields by section: "" before "left", then "left" and "right". A key is
        // read only in its own section; one anywhere else is ignored like an unknown key.
        var fields: [String: [String: String]] = [:]
        var section = ""
        while true {
            guard let line = nextLine() else {
                throw SavedComparisonError.malformed("there is no “--- left” line")
            }
            if line == "--- left" { break }
            if line == "left" || line == "right" {
                section = line
            } else if let colon = line.firstIndex(of: ":") {
                var value = line[line.index(after: colon)...]
                if value.first == " " { value = value.dropFirst() }
                // Unknown keys are kept here and never asked for.
                fields[section, default: [:]][String(line[..<colon])] = String(value)
            }
        }

        func field(_ key: String, in section: String = "") throws -> String {
            guard let value = fields[section]?[key] else {
                let place = section.isEmpty ? "" : " for the \(section) side"
                throw SavedComparisonError.malformed("the “\(key)” line\(place) is missing")
            }
            return value
        }
        guard let saved = Self.dateFormatter().date(from: try field("saved")) else {
            throw SavedComparisonError.malformed("the “saved” date isn’t readable")
        }
        let optionWords = Set((fields[""]?["options"] ?? "").split(separator: " ").map(String.init))
        var options = DiffOptions()
        for (word, keyPath) in Self.optionNames where optionWords.contains(word) {
            options[keyPath: keyPath] = true
        }

        func side(_ label: String) throws -> Side {
            guard let count = Int(try field("bytes", in: label)), count >= 0 else {
                throw SavedComparisonError.malformed("the \(label) side’s byte count isn’t a number")
            }
            // Bodies are found by their byte counts, never by searching, since a body
            // can contain anything, including "--- right".
            guard count <= data.endIndex - position else {
                throw SavedComparisonError.malformed(
                    "the \(label) side’s \(count) bytes run past the end of the file")
            }
            // Copied, so each side's bytes start at index 0.
            let body = Data(data[position..<position + count])
            position += count
            let source = try field("source", in: label)
            return Side(name: try field("name", in: label), source: source == "pasted" ? .pasted : .file(source),
                        bytes: body, sha256: try field("sha256", in: label).lowercased())
        }
        func expect(_ marker: String, after label: String, _ missing: String) throws {
            guard data[position...].starts(with: marker.utf8) else {
                throw SavedComparisonError.malformed("the \(label) side isn’t followed by \(missing)")
            }
            position += marker.utf8.count
        }
        let left = try side("left")
        try expect("\n--- right\n", after: "left", "a “--- right” line")
        let right = try side("right")
        try expect("\n", after: "right", "a newline")

        self.init(note: fields[""]?["note"] ?? "", saved: saved, options: options, left: left, right: right)
    }

    // MARK: - Fields

    private static let optionNames: [(String, WritableKeyPath<DiffOptions, Bool>)] = [
        ("ignore-whitespace", \.ignoreWhitespace),
        ("ignore-case", \.ignoreCase),
        ("ignore-timers", \.ignoreTimers),
    ]

    /// ISO 8601 with the local UTC offset, e.g. 2026-10-21T14:03:12-04:00. Made fresh each
    /// time because the formatter isn't Sendable.
    private static func dateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = .withInternetDateTime
        formatter.timeZone = .current
        return formatter
    }
}
