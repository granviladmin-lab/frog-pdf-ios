import XCTest
import PDFKit
@testable import FrogPDF

final class FrogPDFTests: XCTestCase {

    // MARK: helpers

    /// A multi-page PDF with real text, like a typical document.
    static func samplePDF(pages: Int = 3) -> Data {
        let r = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        return r.pdfData { ctx in
            for i in 1...pages {
                ctx.beginPage()
                ("Test page \(i)" as NSString).draw(at: CGPoint(x: 72, y: 72),
                                                    withAttributes: [.font: UIFont(name: "TimesNewRomanPSMT", size: 36) ?? .systemFont(ofSize: 36)])
                ("The quick brown fox jumps over the lazy dog. Invoice total due." as NSString)
                    .draw(at: CGPoint(x: 72, y: 140), withAttributes: [.font: UIFont(name: "TimesNewRomanPSMT", size: 14) ?? .systemFont(ofSize: 14)])
                UIColor.black.setStroke()
                UIBezierPath(rect: CGRect(x: 72, y: 640, width: 468, height: 60)).stroke()
            }
        }
    }

    func reload(_ pdf: PDFDocument) -> PDFDocument {
        let data = PDFFileDocument.serialize(pdf)
        let out = PDFDocument(data: data)
        XCTAssertNotNil(out, "serialized PDF must re-open")
        return out!
    }

    /// Colour of the rendered page at a point in page space.
    func pixel(_ page: PDFPage, at p: CGPoint) -> UIColor {
        let box = page.bounds(for: .cropBox)
        let img = page.thumbnail(of: box.size, for: .cropBox)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        var rgba = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // thumbnail is top-left origin; page space is bottom-left
        let sx = img.size.width / box.width, sy = img.size.height / box.height
        ctx.translateBy(x: -p.x * sx, y: -(p.y * sy))
        ctx.draw(img.cgImage!, in: CGRect(x: 0, y: 0, width: img.size.width, height: img.size.height))
        return UIColor(red: CGFloat(rgba[0]) / 255, green: CGFloat(rgba[1]) / 255, blue: CGFloat(rgba[2]) / 255, alpha: 1)
    }

    func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: annotations survive saving

    func testAnnotationsRoundTrip() {
        let pdf = PDFDocument(data: Self.samplePDF())!
        let page = pdf.page(at: 0)!
        let ink = AnnotationFactory.ink(strokes: [[CGPoint(x: 100, y: 400), CGPoint(x: 150, y: 430), CGPoint(x: 220, y: 410)]],
                                        width: 2.5, color: .blue)!
        page.addAnnotation(ink)
        page.addAnnotation(AnnotationFactory.text("Hello\nSecond line", topLeft: CGPoint(x: 80, y: 300), size: 18, color: .red))
        page.addAnnotation(AnnotationFactory.box(CGRect(x: 300, y: 300, width: 120, height: 60), color: .red, width: 2))
        // covers the left edge of the stroked box (x 72, page y 92–152)
        page.addAnnotation(AnnotationFactory.whiteout(CGRect(x: 62, y: 80, width: 100, height: 90)))
        if let sel = pdf.findString("quick brown", withOptions: .caseInsensitive).first {
            AnnotationFactory.markup(sel, type: .highlight, color: UIColor.yellow.withAlphaComponent(0.5)).forEach { $0.0.addAnnotation($0.1) }
        } else {
            XCTFail("search should find sample text")
        }

        let back = reload(pdf).page(at: 0)!
        let types = back.annotations.compactMap { $0.type }.sorted()
        XCTAssertEqual(types, ["FreeText", "Highlight", "Ink", "Square", "Square"])
        let text = back.annotations.first { $0.type == "FreeText" }!
        XCTAssertEqual(text.contents, "Hello\nSecond line")
        XCTAssertEqual(text.font?.pointSize ?? 0, 18, accuracy: 0.5)
        let inkBack = back.annotations.first { $0.type == "Ink" }!
        XCTAssertEqual(inkBack.bounds.minX, ink.bounds.minX, accuracy: 1)
        XCTAssertEqual(inkBack.border?.lineWidth ?? 0, 2.5, accuracy: 0.1)
        // white-out actually hides the box's left edge after reloading
        let c = pixel(back, at: CGPoint(x: 72, y: 120))
        var w: CGFloat = 0
        c.getWhite(&w, alpha: nil)
        XCTAssertGreaterThan(w, 0.9, "white-out should hide the box line")
    }

    func testImagesAreFlattenedOnSave() {
        let pdf = PDFDocument(data: Self.samplePDF(pages: 1))!
        let page = pdf.page(at: 0)!
        let red = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        page.addAnnotation(ImageStampAnnotation(image: red, bounds: CGRect(x: 300, y: 400, width: 100, height: 100)))
        let back = reload(pdf).page(at: 0)!
        XCTAssertFalse(back.annotations.contains { $0.type == "Stamp" }, "image should be part of the page content")
        let c = pixel(back, at: CGPoint(x: 350, y: 450))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: nil)
        XCTAssertGreaterThan(r, 0.8)
        XCTAssertLessThan(g, 0.3)
        // text on the flattened page is still selectable
        XCTAssertTrue((back.string ?? "").contains("quick brown"))
    }

    func testSignatureNormalisationAndScaling() {
        let pad = SignaturePadView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        XCTAssertNil(pad.signature())
        let sig = Signature(strokes: [[CGPoint(x: 0, y: 0.1), CGPoint(x: 0.5, y: 0.3), CGPoint(x: 1, y: 0)]], aspect: 0.3)
        let data = try! JSONEncoder().encode([sig])
        XCTAssertEqual(try! JSONDecoder().decode([Signature].self, from: data).first?.strokes.first?.count, 3)

        let ink = AnnotationFactory.ink(strokes: [[CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 150)]], width: 2, color: .black)!
        let bigger = AnnotationFactory.scaledInk(ink, by: 2)!
        XCTAssertEqual(bigger.bounds.width, (ink.bounds.width - 8) * 2 + 2 * (4 + 2), accuracy: 2)
        XCTAssertEqual(bigger.bounds.midX, ink.bounds.midX, accuracy: 1)
    }

    // MARK: pages

    func testPageOperationsWithUndo() {
        let pdf = PDFDocument(data: Self.samplePDF(pages: 3))!
        let undo = UndoManager()
        undo.groupsByEvent = false
        let ed = PageEditor(pdf: pdf, undo: undo)
        func titles() -> [String] {
            return (0..<pdf.pageCount).map { (pdf.page(at: $0)?.string ?? "").components(separatedBy: "\n").first ?? "" }
        }
        func step(_ fn: () -> Void) { undo.beginUndoGrouping(); fn(); undo.endUndoGrouping() }

        step { ed.rotate(1, by: 90) }
        XCTAssertEqual(pdf.page(at: 1)?.rotation, 90)
        step { ed.move(from: 0, to: 2) }
        XCTAssertTrue(titles()[2].contains("page 1"))
        step { ed.duplicate(0) }
        XCTAssertEqual(pdf.pageCount, 4)
        step { ed.insertBlank(after: 3) }
        XCTAssertEqual(pdf.pageCount, 5)
        XCTAssertEqual(pdf.page(at: 4)?.string?.isEmpty ?? true, true)
        let other = PDFDocument(data: Self.samplePDF(pages: 2))!
        step { ed.insertDocument(other, after: 0) }
        XCTAssertEqual(pdf.pageCount, 7)
        step { ed.delete(0) }
        XCTAssertEqual(pdf.pageCount, 6)

        // the saved file reflects all of it
        XCTAssertEqual(reload(pdf).pageCount, 6)

        for _ in 0..<6 { undo.undo() }
        XCTAssertEqual(pdf.pageCount, 3)
        XCTAssertTrue(titles()[0].contains("page 1"))
        XCTAssertEqual(pdf.page(at: 1)?.rotation, 0)
        undo.redo()
        XCTAssertEqual(pdf.page(at: 1)?.rotation, 90)
    }

    func testPasswordDerivation() {
        // RFC 7914 / common PBKDF2-HMAC-SHA256 vector
        let v = PasswordLock.derive("password", salt: Array("salt".utf8), iterations: 1)
        XCTAssertEqual(v, "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        XCTAssertFalse(PasswordLock.check("frog"))
        XCTAssertEqual(PasswordLock.hash.count, 64)
    }

    func testBlankDocumentCreation() {
        let doc = PDFDocument(data: PDFFileDocument.blankPDF())
        XCTAssertEqual(doc?.pageCount, 1)
        XCTAssertEqual(doc?.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 612, height: 792))
    }

    // MARK: UI screenshots (written to $SHOTS_DIR for review)

    func testScreenshots() throws {
        let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] ?? NSTemporaryDirectory()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Sample.pdf")
        try Self.samplePDF().write(to: url)
        let document = PDFFileDocument(fileURL: url)
        let opened = expectation(description: "open")
        document.open { ok in XCTAssertTrue(ok); opened.fulfill() }
        wait(for: [opened], timeout: 10)

        let window = makeWindow()
        let editor = EditorViewController(document: document)
        let nav = UINavigationController(rootViewController: editor)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        spin(2)

        let page = document.pdf!.page(at: 0)!
        let ink = AnnotationFactory.ink(strokes: [(0..<30).map { CGPoint(x: 100 + CGFloat($0) * 8, y: 420 + sin(CGFloat($0) / 3) * 25) }],
                                        width: 2.5, color: ToolbarView.colors[1])!
        editor.add(ink, to: page, name: "Pen")
        editor.add(AnnotationFactory.text("Approved — Frog PDF", topLeft: CGPoint(x: 80, y: 560), size: 24, color: ToolbarView.colors[2]), to: page, name: "Text")
        editor.add(AnnotationFactory.box(CGRect(x: 360, y: 380, width: 160, height: 90), color: ToolbarView.colors[2], width: 2.5), to: page, name: "Box")
        if let sel = document.pdf!.findString("lazy dog", withOptions: .caseInsensitive).first {
            AnnotationFactory.markup(sel, type: .highlight, color: UIColor(red: 1, green: 0.84, blue: 0.04, alpha: 0.5)).forEach { editor.add($0.1, to: $0.0, name: "Markup") }
        }
        let sig = Signature(strokes: [(0..<40).map { i -> CGPoint in
            let t = CGFloat(i) / 39
            return CGPoint(x: t, y: 0.15 + sin(t * 12) * 0.1 * (1 - t))
        }], aspect: 0.3)
        editor.placeSignature(sig, at: editor.pdfView.convert(CGPoint(x: 420, y: 140), from: page), on: page)
        spin(2)
        save(window, to: "\(dir)/editor.png")

        editor.setTool(.pen)
        editor.deselect()
        spin(0.5)
        save(window, to: "\(dir)/editor-pen.png")

        // The signature pad must not sit under a pan gesture (a sheet's swipe-to-dismiss
        // cancels downward strokes), so it is presented full screen.
        editor.chooseSignature()
        spin(1.5)
        let sigNav = try XCTUnwrap(nav.presentedViewController as? DrawingNavigationController)
        XCTAssertEqual(sigNav.modalPresentationStyle, .fullScreen)
        let pad = try XCTUnwrap(Self.find(SignaturePadView.self, in: sigNav.view))
        var ancestor = pad.superview
        while let v = ancestor {
            // the navigation controller's own back-swipe pans can't begin on its root screen
            for g in (v === sigNav.view ? [] : v.gestureRecognizers ?? []) where g.isEnabled && g is UIPanGestureRecognizer && !(g is UIScreenEdgePanGestureRecognizer) {
                XCTFail("pan gesture \(g) on \(type(of: v)) can steal signature strokes")
            }
            ancestor = v.superview
        }
        XCTAssertLessThanOrEqual(pad.bounds.height, 361)
        save(window, to: "\(dir)/signature-presented.png")
        sigNav.dismiss(animated: false)
        spin(0.5)

        let lockWindow = makeWindow()
        lockWindow.rootViewController = LockViewController()
        lockWindow.makeKeyAndVisible()
        spin(1)
        save(lockWindow, to: "\(dir)/lock.png")

        let sigWindow = makeWindow()
        sigWindow.rootViewController = UINavigationController(rootViewController: SignatureViewController())
        sigWindow.makeKeyAndVisible()
        spin(1)
        save(sigWindow, to: "\(dir)/signature.png")

        let grid = PageGridViewController(editor: PageEditor(pdf: document.pdf!, undo: UndoManager()), current: 0)
        let gridWindow = makeWindow()
        gridWindow.rootViewController = UINavigationController(rootViewController: grid)
        gridWindow.makeKeyAndVisible()
        spin(1.5)
        save(gridWindow, to: "\(dir)/pages.png")

        let closed = expectation(description: "close")
        document.close { _ in closed.fulfill() }
        wait(for: [closed], timeout: 10)
        // annotations were saved to the file through UIDocument
        let saved = PDFDocument(url: url)!
        XCTAssertGreaterThanOrEqual(saved.page(at: 0)!.annotations.count, 4)
    }

    static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let v = view as? T { return v }
        for sub in view.subviews { if let v = find(type, in: sub) { return v } }
        return nil
    }

    private func makeWindow() -> UIWindow {
        if #available(iOS 13.0, *), let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            let w = UIWindow(windowScene: scene)
            w.frame = scene.coordinateSpace.bounds
            w.windowLevel = .alert
            return w
        }
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.windowLevel = .alert
        return w
    }

    private func save(_ window: UIWindow, to path: String) {
        let img = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? img.pngData()?.write(to: URL(fileURLWithPath: path))
    }
}
