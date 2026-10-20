import UIKit
import PDFKit

/// Builds the annotation types Frog PDF creates. All geometry is in PDF page space.
enum AnnotationFactory {
    static let editableTypes: Set<String> = ["Ink", "FreeText", "Square", "Circle", "Line", "Highlight",
                                             "Underline", "StrikeOut", "Stamp"]

    static func isEditable(_ a: PDFAnnotation) -> Bool {
        if a is ImageStampAnnotation { return true }
        return editableTypes.contains(a.type ?? "")
    }

    /// Smooth path through points (quadratic curves via midpoints).
    static func smoothPath(_ pts: [CGPoint]) -> UIBezierPath {
        let path = UIBezierPath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 1 {
            path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
            return path
        }
        if pts.count == 2 {
            path.addLine(to: pts[1])
            return path
        }
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, controlPoint: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    /// Ink annotation from strokes given in page coordinates.
    static func ink(strokes: [[CGPoint]], width: CGFloat, color: UIColor) -> PDFAnnotation? {
        let all = strokes.flatMap { $0 }
        guard !all.isEmpty else { return nil }
        let xs = all.map { $0.x }, ys = all.map { $0.y }
        let pad = width + 2
        let bounds = CGRect(x: xs.min()! - pad, y: ys.min()! - pad,
                            width: xs.max()! - xs.min()! + 2 * pad, height: ys.max()! - ys.min()! + 2 * pad)
        let a = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        // PDFKit expects ink paths relative to the annotation's origin.
        for stroke in strokes {
            let local = stroke.map { CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY) }
            a.add(smoothPath(local))
        }
        let border = PDFBorder()
        border.lineWidth = width
        a.border = border
        a.color = color
        return a
    }

    /// Text box whose top-left corner is at `topLeft` (page coordinates, y up).
    static func text(_ string: String, topLeft: CGPoint, size: CGFloat, color: UIColor) -> PDFAnnotation {
        let font = UIFont(name: "Helvetica", size: size) ?? UIFont.systemFont(ofSize: size)
        let box = textSize(string, font: font)
        let bounds = CGRect(x: topLeft.x, y: topLeft.y - box.height, width: box.width, height: box.height)
        let a = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        a.contents = string
        a.font = font
        a.fontColor = color
        a.color = .clear
        a.alignment = .left
        let border = PDFBorder()
        border.lineWidth = 0
        a.border = border
        return a
    }

    static func textSize(_ string: String, font: UIFont) -> CGSize {
        let r = (string as NSString).boundingRect(with: CGSize(width: 4000, height: 4000),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                  attributes: [.font: font], context: nil)
        return CGSize(width: ceil(r.width) + 10, height: ceil(r.height) + 6)
    }

    /// Re-flows a text box after its string or font size changed, keeping the top-left corner.
    static func refit(_ a: PDFAnnotation) {
        guard let font = a.font else { return }
        let s = textSize(a.contents ?? "", font: font)
        let top = a.bounds.maxY
        a.bounds = CGRect(x: a.bounds.minX, y: top - s.height, width: s.width, height: s.height)
    }

    static func box(_ rect: CGRect, color: UIColor, width: CGFloat) -> PDFAnnotation {
        let a = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        a.color = color
        let border = PDFBorder()
        border.lineWidth = width
        a.border = border
        return a
    }

    static func whiteout(_ rect: CGRect) -> PDFAnnotation {
        let a = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        a.color = .white
        a.interiorColor = .white
        let border = PDFBorder()
        border.lineWidth = 0
        a.border = border
        return a
    }

    static func markup(_ selection: PDFSelection, type: PDFAnnotationSubtype, color: UIColor) -> [(PDFPage, PDFAnnotation)] {
        var out = [(PDFPage, PDFAnnotation)]()
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let b = line.bounds(for: page)
                guard b.width > 0.5, b.height > 0.5 else { continue }
                let a = PDFAnnotation(bounds: b, forType: type, withProperties: nil)
                a.color = color
                out.append((page, a))
            }
        }
        return out
    }

    /// Ink annotations: scale strokes about the annotation's centre (resize handle).
    static func scaledInk(_ a: PDFAnnotation, by f: CGFloat) -> PDFAnnotation? {
        guard let paths = a.paths, !paths.isEmpty else { return nil }
        let c = CGPoint(x: a.bounds.midX, y: a.bounds.midY)
        var strokes = [[CGPoint]]()
        for p in paths {
            var pts = [CGPoint]()
            p.cgPath.applyPoints { pt in
                let abs = CGPoint(x: pt.x + a.bounds.minX, y: pt.y + a.bounds.minY)
                pts.append(CGPoint(x: c.x + (abs.x - c.x) * f, y: c.y + (abs.y - c.y) * f))
            }
            strokes.append(pts)
        }
        let width = max(0.5, (a.border?.lineWidth ?? 2) * f)
        return ink(strokes: strokes, width: width, color: a.color)
    }
}

extension CGPath {
    /// Visits the end point of every path element.
    func applyPoints(_ body: (CGPoint) -> Void) {
        var pts = [CGPoint]()
        applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint, .addLineToPoint: pts.append(e.points[0])
            case .addQuadCurveToPoint: pts.append(e.points[1])
            case .addCurveToPoint: pts.append(e.points[2])
            case .closeSubpath: break
            @unknown default: break
            }
        }
        pts.forEach(body)
    }
}

/// A photo placed on the page. Drawn on screen by PDFKit; flattened into the page when saved.
final class ImageStampAnnotation: PDFAnnotation {
    let image: UIImage

    init(image: UIImage, bounds: CGRect) {
        self.image = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let cg = image.cgImage else { return }
        context.saveGState()
        context.draw(cg, in: bounds)
        context.restoreGState()
    }
}
