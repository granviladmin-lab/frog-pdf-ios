import UIKit
import PDFKit

/// A PDF opened in place from Files. UIDocument handles coordinated reads/writes,
/// autosave and iCloud; changes are tracked through its undoManager.
final class PDFFileDocument: UIDocument {
    private(set) var pdf: PDFDocument?

    override func load(fromContents contents: Any, ofType typeName: String?) throws {
        guard let data = contents as? Data, let doc = PDFDocument(data: data) else {
            throw NSError(domain: "FrogPDF", code: 1, userInfo: [NSLocalizedDescriptionKey: "This file isn't a readable PDF."])
        }
        pdf = doc
    }

    override func contents(forType typeName: String) throws -> Any {
        guard let pdf = pdf else { return Data() }
        return PDFFileDocument.serialize(pdf)
    }

    /// PDFKit can't write custom-drawn annotations, so pages that carry placed images
    /// are flattened into new page content in the saved copy. The open document keeps
    /// them movable until it is closed.
    static func serialize(_ pdf: PDFDocument) -> Data {
        guard let data = pdf.dataRepresentation() else { return Data() }
        var imagePages = [Int]()
        for i in 0..<pdf.pageCount {
            if let page = pdf.page(at: i), page.annotations.contains(where: { $0 is ImageStampAnnotation }) {
                imagePages.append(i)
            }
        }
        guard !imagePages.isEmpty, let copy = PDFDocument(data: data) else { return data }
        for i in imagePages {
            guard let page = pdf.page(at: i), let flat = Flattener.flatten(page) else { continue }
            copy.removePage(at: i)
            copy.insert(flat, at: i)
        }
        return copy.dataRepresentation() ?? data
    }

    static func blankPDF(size: CGSize = CGSize(width: 612, height: 792)) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
        return renderer.pdfData { ctx in ctx.beginPage() }
    }
}

enum Flattener {
    /// Renders a page and all of its annotations into a fresh single-page PDF.
    static func flatten(_ page: PDFPage) -> PDFPage? {
        let box = page.bounds(for: .cropBox)
        let rotation = page.rotation
        page.rotation = 0
        defer { page.rotation = rotation }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: box.size))
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            let cg = ctx.cgContext
            cg.translateBy(x: 0, y: box.height)
            cg.scaleBy(x: 1, y: -1)
            page.draw(with: .cropBox, to: cg)
        }
        guard let doc = PDFDocument(data: data), let out = doc.page(at: 0) else { return nil }
        out.rotation = rotation
        return out
    }
}
