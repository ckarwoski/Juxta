import XCTest
@testable import JuxtaCore

enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    static let pairs = root.appendingPathComponent("pairs")

    /// The `side` ("left" or "right") file of the fixture whose folder starts with `number`.
    static func file(_ number: String, _ side: String, in folder: String = "pairs") throws -> URL {
        let dir = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(folder),
                                                        includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(number + "-") }, "no fixture \(number)")
        return try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(side + ".") })
    }
}

/// Every line of both files appears exactly once, in order.
func assertRebuildsBothFiles(_ result: DiffResult, leftCount: Int, rightCount: Int, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(result.rows.compactMap { $0.left >= 0 ? Int($0.left) : nil }, Array(0..<leftCount),
                   message, file: file, line: line)
    XCTAssertEqual(result.rows.compactMap { $0.right >= 0 ? Int($0.right) : nil }, Array(0..<rightCount),
                   message, file: file, line: line)
}
