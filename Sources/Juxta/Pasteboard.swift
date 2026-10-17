import AppKit

extension NSPasteboard {
    var text: String? {
        string(forType: .string)
    }

    /// Files on the pasteboard, as dragged or copied in Finder. Folders are left out.
    var fileURLs: [URL] {
        let urls = readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
    }
}
