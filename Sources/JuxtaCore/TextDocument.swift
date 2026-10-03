import CryptoKit
import Foundation

public enum TextLoadError: LocalizedError {
    case binary(String)

    public var errorDescription: String? {
        switch self {
        case .binary(let name): return "“\(name)” appears to be a binary file."
        }
    }
}

/// How a file's text was stored. Lines are compared after decoding and without their
/// line endings, so these are reported separately to explain files whose bytes
/// differ while their lines don't.
public struct TextFormat: Equatable, Sendable {
    public enum Encoding: String, Sendable {
        case utf8 = "UTF-8"
        /// Mostly UTF-8; lines that aren't valid UTF-8 were read as Windows Latin 1.
        case invalidUTF8 = "UTF-8 with invalid bytes"
        case utf16LittleEndian = "UTF-16 LE"
        case utf16BigEndian = "UTF-16 BE"
        case windowsLatin1 = "Windows Latin 1"
    }

    public struct LineEndings: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let lf = LineEndings(rawValue: 1)
        public static let crlf = LineEndings(rawValue: 2)
        public static let cr = LineEndings(rawValue: 4)
    }

    public enum Aspect: String, CaseIterable, Sendable {
        case encoding = "encoding"
        case byteOrderMark = "byte order mark"
        case lineEndings = "line endings"
        case finalNewline = "final newline"
    }

    public var encoding: Encoding = .utf8
    public var hasBOM = false
    /// Every kind of line ending in the file; empty if it has no line breaks.
    public var lineEndings: LineEndings = []
    /// False when the last line has no line ending. True for an empty file.
    public var endsWithNewline = true

    public init() {}

    /// How `self` and `other` differ, in `Aspect.allCases` order.
    public func differences(from other: TextFormat) -> [Aspect] {
        Aspect.allCases.filter { aspect in
            switch aspect {
            case .encoding: return encoding != other.encoding
            // Part of the encoding difference when the encodings differ.
            case .byteOrderMark: return encoding == other.encoding && hasBOM != other.hasBOM
            // A file without line breaks has nothing to compare.
            case .lineEndings:
                return !lineEndings.isEmpty && !other.lineEndings.isEmpty && lineEndings != other.lineEndings
            case .finalNewline: return endsWithNewline != other.endsWithNewline
            }
        }
    }

    /// Short text for one aspect, or nil when there is nothing worth showing for it.
    public func label(for aspect: Aspect) -> String? {
        switch aspect {
        case .encoding: return encoding.rawValue
        case .byteOrderMark:
            switch encoding {
            case .utf16LittleEndian, .utf16BigEndian: return hasBOM ? nil : "no BOM"
            default: return hasBOM ? "BOM" : nil
            }
        case .lineEndings:
            switch lineEndings {
            case []: return nil
            case .lf: return "LF"
            case .crlf: return "CRLF"
            case .cr: return "CR"
            default: return "mixed line endings"
            }
        case .finalNewline: return endsWithNewline ? nil : "no final newline"
        }
    }
}

public struct TextDocument: Sendable {
    public var lines: [String]
    public var name: String
    /// The file this text came from; nil for pasted text.
    public var url: URL?
    /// Widest line in columns (approximate; tabs count as four, and badges for invisible
    /// characters as their label), used to size the view.
    public var maxColumns: Int
    /// How the file was stored; nil for pasted text, where it isn't meaningful.
    public var format: TextFormat?
    /// Hash of the file's bytes; nil for pasted text.
    public var digest: SHA256.Digest?

    public init(text: String, name: String) {
        self.init(data: Data(text.utf8), name: name, url: nil)
    }

    public static func load(from url: URL) throws -> TextDocument {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try TextDocument(fileData: data, name: url.lastPathComponent, url: url)
    }

    /// Reads file contents: detects the encoding, then splits into lines.
    public init(fileData data: Data, name: String, url: URL? = nil) throws {
        var format = TextFormat()
        var text = data
        if let utf16 = Self.utf16Encoding(of: data) {
            format.encoding = utf16.encoding
            format.hasBOM = utf16.bomLength > 0
            text = Data(Self.decodeUTF16(data.dropFirst(utf16.bomLength),
                                         bigEndian: utf16.encoding == .utf16BigEndian).utf8)
        } else if data.prefix(8192).contains(0) {
            throw TextLoadError.binary(name)
        }
        self.init(data: text, name: name, url: url, format: format)
        digest = SHA256.hash(data: data)
    }

    /// Ways the two files' bytes differ that their lines don't show. Empty when either
    /// side is pasted text.
    public func hiddenDifferences(from other: TextDocument) -> [TextFormat.Aspect] {
        guard let format, let otherFormat = other.format else { return [] }
        return format.differences(from: otherFormat)
    }

    /// Whether both files have exactly the same bytes; nil when either side is pasted text.
    public func isByteIdentical(to other: TextDocument) -> Bool? {
        guard let digest, let otherDigest = other.digest else { return nil }
        return digest == otherDigest
    }

    // MARK: - Decoding

    /// Recognizes UTF-16 by its byte order mark, or, without one, by NUL bytes that
    /// only appear in every other position (ASCII text stored as UTF-16).
    private static func utf16Encoding(of data: Data) -> (encoding: TextFormat.Encoding, bomLength: Int)? {
        let probe = [UInt8](data.prefix(8192))
        if probe.starts(with: [0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
        if probe.starts(with: [0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
        guard probe.count >= 4 else { return nil }
        var zeros = [0, 0]
        for (index, byte) in probe.enumerated() where byte == 0 { zeros[index & 1] += 1 }
        let pairs = probe.count / 2
        if zeros[0] == 0 && zeros[1] * 2 >= pairs { return (.utf16LittleEndian, 0) }
        if zeros[1] == 0 && zeros[0] * 2 >= pairs { return (.utf16BigEndian, 0) }
        return nil
    }

    private static func decodeUTF16(_ data: Data, bigEndian: Bool) -> String {
        var units = [UInt16]()
        units.reserveCapacity(data.count / 2)
        var index = data.startIndex
        while index + 1 < data.endIndex {
            let a = UInt16(data[index]), b = UInt16(data[index + 1])
            units.append(bigEndian ? a << 8 | b : b << 8 | a)
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Splits text into lines on LF, CRLF or a lone CR. `format` is nil for pasted text.
    private init(data: Data, name: String, url: URL?, format: TextFormat? = nil) {
        self.name = name
        self.url = url
        var format = format
        let isUTF8 = String(data: data, encoding: .utf8) != nil
        var sawValidNonASCII = false
        var sawInvalid = false
        var endings: TextFormat.LineEndings = []
        var endsWithNewline = true
        var lines: [String] = []
        var maxColumns = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress else { return }
            let count = bytes.count
            var start = 0
            if count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
                start = 3
                format?.hasBOM = true
            }
            func find(_ byte: UInt8, from: Int, to: Int) -> Int? {
                guard from < to, let hit = memchr(base + from, Int32(byte), to - from) else { return nil }
                return base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            }
            while start < count {
                let lf = find(0x0A, from: start, to: count) ?? count
                let stop: Int, next: Int
                if let cr = find(0x0D, from: start, to: lf) {
                    stop = cr
                    if cr + 1 == lf && lf < count {
                        next = lf + 1
                        endings.insert(.crlf)
                    } else {
                        next = cr + 1
                        endings.insert(.cr)
                    }
                } else {
                    stop = lf
                    next = lf + 1
                    if lf < count { endings.insert(.lf) } else { endsWithNewline = false }
                }
                let slice = UnsafeBufferPointer(rebasing: bytes[start..<stop])
                let line: String
                if isUTF8 {
                    line = String(decoding: slice, as: UTF8.self)
                } else if let valid = String(bytes: slice, encoding: .utf8) {
                    line = valid
                    if !sawValidNonASCII { sawValidNonASCII = slice.contains { $0 >= 0x80 } }
                } else {
                    sawInvalid = true
                    line = String(bytes: slice, encoding: .windowsCP1252)
                        ?? String(bytes: slice, encoding: .isoLatin1)!
                }
                var tabs = 0, unusual = false
                for byte in slice {
                    if byte == 0x09 { tabs += 1 } else if byte < 0x20 || byte >= 0x7F { unusual = true }
                }
                // Changed lines draw badges for invisible characters, which need room.
                let badges = unusual ? Invisibles.extraColumns(line) : 0
                maxColumns = max(maxColumns, slice.count + tabs * 3 + badges)
                lines.append(line)
                start = next
            }
        }
        if format?.encoding == .utf8 && sawInvalid {
            format?.encoding = sawValidNonASCII ? .invalidUTF8 : .windowsLatin1
        }
        format?.lineEndings = endings
        format?.endsWithNewline = endsWithNewline
        self.lines = lines
        self.maxColumns = maxColumns
        self.format = format
    }
}
