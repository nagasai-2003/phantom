import AppKit
import PDFKit

// Pulls plain text out of a resume file: PDF, Word (.docx/.doc), RTF or text.
enum ResumeReader {
    static let fileExtensions = ["pdf", "docx", "doc", "rtf", "txt", "md"]

    static func text(from url: URL) -> String? {
        let raw: String?
        switch url.pathExtension.lowercased() {
        case "pdf":
            raw = PDFDocument(url: url)?.string
        case "docx":
            raw = attributed(url, .officeOpenXML)
        case "doc":
            raw = attributed(url, .docFormat)
        case "rtf":
            raw = attributed(url, .rtf)
        default:
            raw = try? String(contentsOf: url, encoding: .utf8)
        }
        guard let text = raw.map(clean), !text.isEmpty else { return nil }
        return text
    }

    private static func attributed(_ url: URL, _ type: NSAttributedString.DocumentType) -> String? {
        try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil).string
    }

    // Collapses the extra spaces and blank lines PDFs and Word files tend to produce.
    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
