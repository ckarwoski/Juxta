import Foundation
import JuxtaCore
import QuickLookUI
import UniformTypeIdentifiers

/// Finder's Quick Look preview of a `.juxta` file: the page `QuickLookPreview` makes, as a
/// data-based preview. A file that isn't a comparison gets a page saying why; only a file
/// that can't be read at all fails, and Quick Look then shows its icon.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        // The work happens in the data block, as QLPreviewReply asks. Quick Look gives no
        // way to stop it early; QuickLookPreview.timeLimit bounds the comparison instead.
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 1200, height: 800)) { _ in
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return Data(QuickLookPreview.page(for: data).utf8)
        }
        reply.stringEncoding = .utf8
        return reply
    }
}
