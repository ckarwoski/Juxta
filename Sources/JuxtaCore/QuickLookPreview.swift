import Foundation

/// What Finder's Quick Look shows for a `.juxta` file: the HTML export's changes-only page,
/// as `juxta-diff --html` writes it for the file, cut off after the first 200 changes. Paths
/// are never shown, since a preview is often on screen while sharing it.
///
/// Quick Look waits for the whole page and shows it in a web view, so the page is kept to a
/// few megabytes: besides the change limit, at most 5,000 changed rows and about 3 MB of
/// rows are shown. Those only cut off pages where most lines changed, such as two unrelated
/// files, or pages of very long lines.
///
/// A file that can't be read as a comparison gets a short page saying why, rather than an
/// error, so the preview says "saved by a newer version of Juxta" instead of showing a
/// generic icon.
public enum QuickLookPreview {
    public static let context = 3
    public static let changeLimit = 200
    public static let rowLimit = 5_000
    public static let byteLimit = 3_000_000
    /// Shorter than the app's, since Quick Look waits for the whole page. A comparison
    /// cut short says "approximate", as in the app.
    public static let timeLimit: TimeInterval = 2

    /// The page for a `.juxta` file's bytes.
    public static func page(for data: Data, timeLimit: TimeInterval = timeLimit) -> String {
        do {
            return try report(for: data, timeLimit: timeLimit).render()
        } catch {
            return errorPage(error)
        }
    }

    /// The report the page is rendered from; throws for a file that isn't a comparison.
    static func report(for data: Data, timeLimit: TimeInterval = timeLimit) throws -> HTMLReport {
        let saved = try SavedComparison(data: data)
        let (left, right) = try saved.documents()
        let result = Comparator.compare(left.lines, right.lines, options: saved.options, timeLimit: timeLimit)
        var report = HTMLReport(left: left, right: right, result: result, options: saved.options)
        report.describe(saved)
        report.extent = .context(context)
        report.changeLimit = changeLimit
        report.rowLimit = rowLimit
        report.byteLimit = byteLimit
        return report
    }

    /// A page with the reason the file can't be shown, styled like the report's header.
    static func errorPage(_ error: Error) -> String {
        var out = "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\"/>\n"
        out += "<meta name=\"color-scheme\" content=\"light dark\"/>\n<meta name=\"generator\" content=\"Juxta\"/>\n"
        out += "<title>Can’t show this comparison</title>\n<style>\n" + HTMLReport.css + "</style>\n</head>\n<body>\n"
        out += "<header>\n<h1>Can’t show this comparison</h1>\n<p class=\"notice\">"
        HTMLReport.appendEscaped(error.localizedDescription, to: &out)
        out += "</p>\n</header>\n</body>\n</html>\n"
        return out
    }
}
