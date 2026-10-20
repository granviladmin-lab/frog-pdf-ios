import UIKit
import PDFKit

final class EditorViewController: UIViewController, UIGestureRecognizerDelegate, UISearchBarDelegate,
    UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    let document: PDFFileDocument
    var pdf: PDFDocument { return document.pdf! }
    var undo: UndoManager { return document.undoManager }

    let pdfView = PDFView()
    private let overlay = UIView()
    private let liveLayer = CAShapeLayer()
    private let outlineLayer = CAShapeLayer()
    private let toolbar = ToolbarView()
    private let selectionBar = UIStackView()
    private let markupBar = UIStackView()
    private let searchContainer = UIView()
    private let searchBar = UISearchBar()
    private let searchCount = UILabel()
    private lazy var pageEditor = PageEditor(pdf: pdf, undo: undo)

    private(set) var tool: Tool = .scroll
    private var colors: [Tool: UIColor] = [
        .pen: ToolbarView.colors[0], .highlighter: ToolbarView.colors[4],
        .text: ToolbarView.colors[0], .box: ToolbarView.colors[2],
    ]
    private let widths: [Tool: [CGFloat]] = [.pen: [1.2, 2.5, 5], .highlighter: [8, 14, 22], .box: [1, 2.5, 5]]
    private var widthIndex: [Tool: Int] = [.pen: 1, .highlighter: 1, .box: 1]
    private var textSize: CGFloat = 14

    /// After the first Apple Pencil stroke: pencil draws, fingers scroll (like Notes).
    private(set) var pencilOnly = UserDefaults.standard.bool(forKey: "frogpdf.pencilOnly")

    private(set) var selected: (page: PDFPage, annotation: PDFAnnotation)?
    private var signature: Signature?
    private var pendingImage: UIImage?

    // gesture state
    private lazy var drawGesture = DrawingGestureRecognizer(target: self, action: #selector(handleDraw(_:)))
    private lazy var tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    private var scrollView: UIScrollView?
    private var offsetObservation: NSKeyValueObservation?
    private var strokePage: PDFPage?
    private var strokeView = [CGPoint]()
    private var strokePage2 = [CGPoint]()
    private var rectStartView: CGPoint?
    private var rectEndView: CGPoint?
    private var moveStart: (point: CGPoint, bounds: CGRect)?
    private var erasing = false

    // search
    private var results = [PDFSelection]()
    private var resultIndex = 0
    private var lastQuery = ""

    private var undoItem: UIBarButtonItem!
    private var redoItem: UIBarButtonItem!

    init(document: PDFFileDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Setup

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Compat.groupedBackground
        title = document.fileURL.deletingPathExtension().lastPathComponent
        setUpNavigation()
        setUpViews()
        setUpGestures()
        setUpNotifications()
        setTool(.scroll)
        updatePageLabel()
        updateUndoButtons()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        attachScrollView()
        becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        overlay.frame = pdfView.convert(pdfView.bounds, to: view)
        liveLayer.frame = overlay.bounds
        outlineLayer.frame = overlay.bounds
        updateOutline()
    }

    override var canBecomeFirstResponder: Bool { return true }

    private func setUpNavigation() {
        let bar = navigationController?.navigationBar
        bar?.barTintColor = Brand.darkGreen
        bar?.tintColor = .white
        bar?.titleTextAttributes = [.foregroundColor: UIColor.white]
        bar?.barStyle = .black
        bar?.isTranslucent = false
        if #available(iOS 13.0, *) {
            let ap = UINavigationBarAppearance()
            ap.configureWithOpaqueBackground()
            ap.backgroundColor = Brand.darkGreen
            ap.titleTextAttributes = [.foregroundColor: UIColor.white]
            bar?.standardAppearance = ap
            bar?.scrollEdgeAppearance = ap
            bar?.compactAppearance = ap
        }
        let done = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        navigationItem.leftBarButtonItem = done
        undoItem = Compat.barButton("Undo", symbols: ["arrow.uturn.backward", "arrow.uturn.left"], target: self, action: #selector(doUndo))
        redoItem = Compat.barButton("Redo", symbols: ["arrow.uturn.forward", "arrow.uturn.right"], target: self, action: #selector(doRedo))
        let share = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(share(_:)))
        let pages = Compat.barButton("Pages", symbols: ["square.grid.2x2"], target: self, action: #selector(showPages))
        let search = UIBarButtonItem(barButtonSystemItem: .search, target: self, action: #selector(toggleSearch))
        let more = Compat.barButton("More", symbols: ["ellipsis.circle"], target: self, action: #selector(showMore(_:)))
        navigationItem.rightBarButtonItems = [share, more, pages, search, redoItem, undoItem]
    }

    private func setUpViews() {
        pdfView.document = pdf
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.backgroundColor = Compat.groupedBackground
        pdfView.pageShadowsEnabled = true
        pdfView.maxScaleFactor = 6

        searchBar.delegate = self
        searchBar.placeholder = "Find in document"
        searchBar.searchBarStyle = .minimal
        searchBar.autocapitalizationType = .none
        searchCount.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        searchCount.textColor = Compat.secondaryLabel
        let prev = UIButton(type: .system)
        prev.setTitle("‹ Prev", for: .normal)
        prev.addAction { [weak self] in self?.stepSearch(-1) }
        let next = UIButton(type: .system)
        next.setTitle("Next ›", for: .normal)
        next.addAction { [weak self] in self?.stepSearch(1) }
        let doneSearch = UIButton(type: .system)
        doneSearch.setTitle("Done", for: .normal)
        doneSearch.addAction { [weak self] in self?.toggleSearch() }
        let searchRow = UIStackView(arrangedSubviews: [searchBar, searchCount, prev, next, doneSearch])
        searchRow.spacing = 10
        searchRow.alignment = .center
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.addSubview(searchRow)
        searchContainer.backgroundColor = Compat.background
        searchContainer.isHidden = true
        NSLayoutConstraint.activate([
            searchRow.leadingAnchor.constraint(equalTo: searchContainer.safeAreaLayoutGuide.leadingAnchor, constant: 6),
            searchRow.trailingAnchor.constraint(equalTo: searchContainer.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            searchRow.topAnchor.constraint(equalTo: searchContainer.topAnchor),
            searchRow.bottomAnchor.constraint(equalTo: searchContainer.bottomAnchor),
            searchContainer.heightAnchor.constraint(equalToConstant: 52),
        ])

        let column = UIStackView(arrangedSubviews: [searchContainer, pdfView, toolbar])
        column.axis = .vertical
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        let bottomFill = UIView()
        bottomFill.backgroundColor = Brand.darkGreen
        bottomFill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomFill)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            column.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            column.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 64),
            bottomFill.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomFill.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomFill.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            bottomFill.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        overlay.isUserInteractionEnabled = false
        overlay.backgroundColor = .clear
        liveLayer.fillColor = UIColor.clear.cgColor
        liveLayer.lineCap = .round
        liveLayer.lineJoin = .round
        outlineLayer.fillColor = UIColor.clear.cgColor
        outlineLayer.strokeColor = Brand.green.cgColor
        outlineLayer.lineWidth = 2
        outlineLayer.lineDashPattern = [6, 4]
        overlay.layer.addSublayer(liveLayer)
        overlay.layer.addSublayer(outlineLayer)
        view.addSubview(overlay)

        toolbar.onTool = { [weak self] t in self?.toolTapped(t) }
        toolbar.onColor = { [weak self] c in self?.colorTapped(c) }
        toolbar.onWidth = { [weak self] i in
            guard let self = self else { return }
            self.widthIndex[self.tool] = i
            self.refreshOptions()
        }

        configureFloatingBar(selectionBar)
        addBarButton(selectionBar, "Edit") { [weak self] in self?.editSelectedText() }
        addBarButton(selectionBar, "A−") { [weak self] in self?.resizeSelected(1 / 1.15) }
        addBarButton(selectionBar, "A+") { [weak self] in self?.resizeSelected(1.15) }
        addBarButton(selectionBar, "Delete", destructive: true) { [weak self] in self?.deleteSelected() }

        configureFloatingBar(markupBar)
        addBarButton(markupBar, "Highlight") { [weak self] in self?.markupSelection(.highlight) }
        addBarButton(markupBar, "Underline") { [weak self] in self?.markupSelection(.underline) }
        addBarButton(markupBar, "Strike out") { [weak self] in self?.markupSelection(.strikeOut) }
    }

    private func configureFloatingBar(_ bar: UIStackView) {
        bar.axis = .horizontal
        bar.spacing = 4
        bar.isLayoutMarginsRelativeArrangement = true
        bar.layoutMargins = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        bar.isHidden = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        let bg = UIView()
        bg.backgroundColor = Brand.darkGreen
        bg.layer.cornerRadius = 12
        bg.layer.shadowOpacity = 0.3
        bg.layer.shadowRadius = 8
        bg.translatesAutoresizingMaskIntoConstraints = false
        bar.insertSubview(bg, at: 0)
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            bg.topAnchor.constraint(equalTo: bar.topAnchor),
            bg.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -12),
        ])
    }

    private func addBarButton(_ bar: UIStackView, _ title: String, destructive: Bool = false, _ fn: @escaping () -> Void) {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        b.setTitleColor(.white, for: .normal)
        b.backgroundColor = destructive ? UIColor(red: 0.85, green: 0.25, blue: 0.22, alpha: 1) : UIColor(white: 1, alpha: 0.12)
        b.layer.cornerRadius = 8
        b.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        b.addAction(fn)
        bar.addArrangedSubview(b)
    }

    private func setUpGestures() {
        drawGesture.delegate = self
        drawGesture.cancelsTouchesInView = true
        pdfView.addGestureRecognizer(drawGesture)
        tapGesture.delegate = self
        pdfView.addGestureRecognizer(tapGesture)
        drawGesture.shouldBeginAt = { [weak self] p in
            guard let self = self else { return false }
            if self.tool != .select { return true }
            guard let hit = self.hitTest(p) else { return false }
            self.select(hit)
            return true
        }
    }

    private func setUpNotifications() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
        nc.addObserver(self, selector: #selector(viewChanged), name: .PDFViewScaleChanged, object: pdfView)
        nc.addObserver(self, selector: #selector(textSelectionChanged), name: .PDFViewSelectionChanged, object: pdfView)
        nc.addObserver(self, selector: #selector(pagesChanged), name: PageEditor.didChange, object: nil)
        for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            nc.addObserver(self, selector: #selector(undoChanged), name: name, object: undo)
        }
    }

    /// PDFView scrolls with an internal UIScrollView; we adjust its gestures per tool.
    private func attachScrollView() {
        guard scrollView == nil, let sv = findScrollView(in: pdfView) else { return }
        scrollView = sv
        offsetObservation = sv.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            self?.updateOutline()
        }
        applyGestureConfig()
    }

    private func findScrollView(in view: UIView) -> UIScrollView? {
        for sub in view.subviews {
            if let sv = sub as? UIScrollView { return sv }
            if let found = findScrollView(in: sub) { return found }
        }
        return nil
    }

    // MARK: - Tools

    private func toolTapped(_ t: Tool) {
        setTool(t)
        switch t {
        case .sign: chooseSignature()
        case .image: chooseImage()
        case .text: toast("Tap where the text should go", seconds: 1.6)
        case .box: toast("Drag to draw a box", seconds: 1.6)
        case .whiteout: toast("Drag over content to cover it", seconds: 1.6)
        case .eraser: toast("Tap or drag over marks to erase", seconds: 1.6)
        case .select: toast("Tap a mark to select it, drag to move it", seconds: 1.6)
        default: break
        }
    }

    func setTool(_ t: Tool) {
        tool = t
        toolbar.select(t)
        if t != .select { deselect() }
        if t != .scroll && t != .select { pdfView.clearSelection() }
        applyGestureConfig()
        refreshOptions()
    }

    private func applyGestureConfig() {
        let direct = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        let indirect = NSNumber(value: UITouch.TouchType.indirect.rawValue)
        drawGesture.isEnabled = tool.isDrawing || tool == .select
        tapGesture.isEnabled = [.text, .sign, .image, .select].contains(tool)
        let pan = scrollView?.panGestureRecognizer
        if tool.isDrawing && pencilOnly {
            drawGesture.allowedTouchTypes = [pencil]
            pan?.minimumNumberOfTouches = 1
            pan?.allowedTouchTypes = [direct, indirect]
        } else if tool.isDrawing {
            drawGesture.allowedTouchTypes = [direct, pencil]
            pan?.minimumNumberOfTouches = 2
            pan?.allowedTouchTypes = [direct, indirect, pencil]
        } else {
            drawGesture.allowedTouchTypes = [direct, pencil]
            pan?.minimumNumberOfTouches = 1
            pan?.allowedTouchTypes = [direct, indirect, pencil]
        }
    }

    private func refreshOptions() {
        if let sel = selected?.annotation, AnnotationFactory.isEditable(sel), !(sel is ImageStampAnnotation), !isWhiteout(sel) {
            toolbar.showOptions(color: sel.type == "FreeText" ? (sel.fontColor ?? .black) : sel.color.withAlphaComponent(1),
                                widths: [], widthIndex: 0)
            return
        }
        let ws = widths[tool] ?? []
        toolbar.showOptions(color: tool.hasColor ? colors[tool] : nil, widths: ws, widthIndex: widthIndex[tool] ?? 0)
    }

    private func colorTapped(_ c: UIColor) {
        if case let (page, a)? = selected {
            setColor(c, of: a, on: page)
        } else {
            colors[tool] = c
        }
        refreshOptions()
    }

    private func currentWidth(_ t: Tool) -> CGFloat {
        let ws = widths[t] ?? [2]
        return ws[min(widthIndex[t] ?? 0, ws.count - 1)]
    }

    private func isWhiteout(_ a: PDFAnnotation) -> Bool {
        return a.type == "Square" && a.interiorColor != nil && (a.border?.lineWidth ?? 0) == 0
    }

    // MARK: - Gesture delegate

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        guard g === drawGesture, tool != .select, let sv = scrollView else { return false }
        // let a second finger turn into scroll / pinch while drawing with one finger
        return other === sv.panGestureRecognizer || other === sv.pinchGestureRecognizer
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if g === tapGesture, pencilOnly, tool.isDrawing { return false }
        return true
    }

    // MARK: - Drawing

    @objc private func handleDraw(_ g: DrawingGestureRecognizer) {
        let samples = g.takeSamples()
        switch g.state {
        case .began:
            if g.lastTouchType == .pencil, !pencilOnly, tool.isDrawing {
                setPencilOnly(true)
                toast("Apple Pencil detected: the pencil draws and your finger scrolls. Change this under More.", seconds: 3.5)
            }
            begin(at: samples.first ?? g.location(in: pdfView))
            if samples.count > 1 { extend(Array(samples.dropFirst())) }
        case .changed:
            extend(samples)
        case .ended:
            extend(samples)
            finish()
        case .cancelled, .failed:
            cancelGesture()
        default:
            break
        }
    }

    private func begin(at p: CGPoint) {
        switch tool {
        case .pen, .highlighter:
            guard let page = pdfView.page(for: p, nearest: true) else { return }
            strokePage = page
            strokeView = [p]
            strokePage2 = [pdfView.convert(p, to: page)]
            liveLayer.strokeColor = colors[tool]?.cgColor
            liveLayer.opacity = tool == .highlighter ? 0.4 : 1
            liveLayer.lineWidth = currentWidth(tool) * pdfView.scaleFactor
            liveLayer.lineDashPattern = nil
            liveLayer.fillColor = UIColor.clear.cgColor
            drawLive()
        case .box, .whiteout:
            strokePage = pdfView.page(for: p, nearest: true)
            rectStartView = p
            liveLayer.opacity = 1
            liveLayer.lineWidth = tool == .box ? currentWidth(.box) * pdfView.scaleFactor : 1
            liveLayer.strokeColor = tool == .box ? colors[.box]?.cgColor : UIColor.gray.cgColor
            liveLayer.fillColor = tool == .whiteout ? UIColor.white.cgColor : UIColor.clear.cgColor
            liveLayer.lineDashPattern = tool == .whiteout ? [4, 3] : nil
        case .eraser:
            undo.beginUndoGrouping()
            erasing = true
            erase(at: p)
        case .select:
            if let s = selected { moveStart = (p, s.annotation.bounds) }
        default:
            break
        }
    }

    private func extend(_ pts: [CGPoint]) {
        guard !pts.isEmpty else { return }
        switch tool {
        case .pen, .highlighter:
            guard let page = strokePage else { return }
            for p in pts {
                if let last = strokeView.last, hypot(p.x - last.x, p.y - last.y) < 1.2 { continue }
                strokeView.append(p)
                strokePage2.append(pdfView.convert(p, to: page))
            }
            drawLive()
        case .box, .whiteout:
            guard let start = rectStartView, let p = pts.last else { return }
            rectEndView = p
            liveLayer.path = UIBezierPath(rect: rectFrom(start, p)).cgPath
        case .eraser:
            pts.forEach { erase(at: $0) }
        case .select:
            guard case let (page, a)? = selected, let start = moveStart, let p = pts.last else { return }
            let p0 = pdfView.convert(start.point, to: page), p1 = pdfView.convert(p, to: page)
            a.bounds = start.bounds.offsetBy(dx: p1.x - p0.x, dy: p1.y - p0.y)
            redisplay(a, on: page)
            updateOutline()
        default:
            break
        }
    }

    private func finish() {
        switch tool {
        case .pen, .highlighter:
            if let page = strokePage, let color = colors[tool] {
                let c = tool == .highlighter ? color.withAlphaComponent(0.4) : color
                if let a = AnnotationFactory.ink(strokes: [strokePage2], width: currentWidth(tool), color: c) {
                    add(a, to: page, name: tool == .pen ? "Pen" : "Highlight")
                }
            }
        case .box, .whiteout:
            if let page = strokePage, let start = rectStartView, let end = rectEndView {
                let p0 = pdfView.convert(start, to: page)
                let p1 = pdfView.convert(end, to: page)
                let pageRect = rectFrom(p0, p1)
                if pageRect.width > 3, pageRect.height > 3 {
                    let a = tool == .box
                        ? AnnotationFactory.box(pageRect, color: colors[.box] ?? .red, width: currentWidth(.box))
                        : AnnotationFactory.whiteout(pageRect)
                    add(a, to: page, name: tool == .box ? "Box" : "White-out")
                }
            }
        case .eraser:
            endErase()
        case .select:
            if case let (page, a)? = selected, let start = moveStart, a.bounds != start.bounds {
                let moved = a.bounds
                a.bounds = start.bounds
                setBounds(moved, of: a, on: page, name: "Move")
            }
            moveStart = nil
        default:
            break
        }
        clearLive()
    }

    private func cancelGesture() {
        if erasing { endErase() }
        if tool == .select, let (page, a) = selected, let start = moveStart {
            a.bounds = start.bounds
            redisplay(a, on: page)
            updateOutline()
        }
        moveStart = nil
        clearLive()
    }

    private func clearLive() {
        liveLayer.path = nil
        strokePage = nil
        strokeView = []
        strokePage2 = []
        rectStartView = nil
        rectEndView = nil
    }

    private func drawLive() {
        liveLayer.path = AnnotationFactory.smoothPath(strokeView).cgPath
    }

    private func rectFrom(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func erase(at p: CGPoint) {
        guard let hit = hitTest(p) else { return }
        remove(hit.annotation, from: hit.page, name: "Erase")
    }

    private func endErase() {
        if erasing {
            undo.endUndoGrouping()
            erasing = false
        }
    }

    // MARK: - Taps (text, signature, image, select)

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let p = g.location(in: pdfView)
        guard let page = pdfView.page(for: p, nearest: true) else { return }
        let pt = pdfView.convert(p, to: page)
        switch tool {
        case .text:
            let entry = TextEntryViewController(title: "Add Text", text: "", size: textSize)
            entry.onDone = { [weak self] text, size in
                guard let self = self else { return }
                self.textSize = size
                let a = AnnotationFactory.text(text, topLeft: pt, size: size, color: self.colors[.text] ?? .black)
                self.add(a, to: page, name: "Text")
            }
            presentSheet(entry, from: CGRect(origin: p, size: .zero))
        case .sign:
            guard let sig = signature else { chooseSignature(); return }
            placeSignature(sig, at: p, on: page)
        case .image:
            guard let img = pendingImage else { chooseImage(); return }
            let w: CGFloat = min(240, page.bounds(for: .cropBox).width * 0.8)
            let h = w * img.size.height / max(img.size.width, 1)
            let a = ImageStampAnnotation(image: img, bounds: CGRect(x: pt.x - w / 2, y: pt.y - h / 2, width: w, height: h))
            add(a, to: page, name: "Image")
            setTool(.select)
            select((page, a))
            toast("Drag to move, A− / A+ to resize. Images become part of the page when you close the file.", seconds: 3.5)
        case .select:
            if let hit = hitTest(p) { select(hit) } else { deselect() }
        default:
            break
        }
    }

    func placeSignature(_ sig: Signature, at p: CGPoint, on page: PDFPage) {
        let widthPts: CGFloat = 160
        let wv = widthPts * pdfView.scaleFactor
        let strokes = sig.strokes.map { s in
            s.map { n -> CGPoint in
                let v = CGPoint(x: p.x + (n.x - 0.5) * wv, y: p.y + (n.y - sig.aspect / 2) * wv)
                return pdfView.convert(v, to: page)
            }
        }
        guard let a = AnnotationFactory.ink(strokes: strokes, width: 1.8, color: colors[.pen] == ToolbarView.colors[1] ? ToolbarView.colors[1] : .black) else { return }
        add(a, to: page, name: "Signature")
        setTool(.select)
        select((page, a))
        toast("Signed. Drag to move, A− / A+ to resize.")
    }

    func chooseSignature() {
        let vc = SignatureViewController()
        vc.onChoose = { [weak self] s in
            self?.signature = s
            self?.setTool(.sign)
            self?.toast("Tap where the signature goes")
        }
        presentFullScreen(vc)
    }

    private func chooseImage() {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = self
        // iOS 12 requires a popover for the photo library on iPad; iPhone adapts to full screen
        picker.modalPresentationStyle = .popover
        picker.popoverPresentationController?.sourceView = toolbar
        picker.popoverPresentationController?.sourceRect = toolbar.bounds
        present(picker, animated: true)
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let img = info[.originalImage] as? UIImage else { return }
        pendingImage = img.downscaled(maxSide: 1600)
        setTool(.image)
        toast("Tap where the image goes")
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    private func presentSheet(_ vc: UIViewController, from rect: CGRect?) {
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    /// Full screen, not a sheet: on iOS 13+ a sheet's swipe-to-dismiss pan claims downward
    /// strokes and cancels them, even with isModalInPresentation set.
    private func presentFullScreen(_ vc: UIViewController) {
        let nav = DrawingNavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }

    // MARK: - Selection

    private func hitTest(_ p: CGPoint) -> (page: PDFPage, annotation: PDFAnnotation)? {
        guard let page = pdfView.page(for: p, nearest: false) else { return nil }
        let pt = pdfView.convert(p, to: page)
        let slop = 10 / max(pdfView.scaleFactor, 0.1)
        for a in page.annotations.reversed() where AnnotationFactory.isEditable(a) {
            if a.bounds.insetBy(dx: -slop, dy: -slop).contains(pt) { return (page, a) }
        }
        return nil
    }

    private func select(_ hit: (page: PDFPage, annotation: PDFAnnotation)) {
        selected = hit
        selectionBar.isHidden = false
        markupBar.isHidden = true
        selectionBar.arrangedSubviews.first?.isHidden = hit.annotation.type != "FreeText"
        let resizable = !(hit.annotation.type == "Highlight" || hit.annotation.type == "Underline" || hit.annotation.type == "StrikeOut")
        selectionBar.arrangedSubviews[1].isHidden = !resizable
        selectionBar.arrangedSubviews[2].isHidden = !resizable
        updateOutline()
        refreshOptions()
    }

    func deselect() {
        guard selected != nil else { return }
        selected = nil
        selectionBar.isHidden = true
        outlineLayer.path = nil
        refreshOptions()
    }

    private func updateOutline() {
        guard case let (page, a)? = selected, a.page != nil else {
            outlineLayer.path = nil
            return
        }
        let r = pdfView.convert(a.bounds, from: page).insetBy(dx: -5, dy: -5)
        outlineLayer.path = UIBezierPath(roundedRect: r, cornerRadius: 4).cgPath
    }

    @objc private func viewChanged() { updateOutline() }

    @objc private func pageChanged() { updatePageLabel() }

    private func updatePageLabel() {
        let n = pdf.pageCount
        let i = pdfView.currentPage.map { pdf.index(for: $0) } ?? 0
        toolbar.pageLabel.text = "\(i + 1) / \(n)"
    }

    @objc private func textSelectionChanged() {
        let has = (pdfView.currentSelection?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        markupBar.isHidden = !(has && selected == nil)
    }

    private func editSelectedText() {
        guard case let (page, a)? = selected, a.type == "FreeText" else { return }
        let entry = TextEntryViewController(title: "Edit Text", text: a.contents ?? "", size: a.font?.pointSize ?? 14)
        entry.onDone = { [weak self] text, size in
            self?.setText(text, size: size, of: a, on: page)
        }
        presentSheet(entry, from: nil)
    }

    private func resizeSelected(_ f: CGFloat) {
        guard case let (page, a)? = selected else { return }
        switch a.type ?? "" {
        case "FreeText":
            let size = max(4, (a.font?.pointSize ?? 14) * f).rounded()
            setText(a.contents ?? "", size: size, of: a, on: page)
        case "Ink":
            guard let scaled = AnnotationFactory.scaledInk(a, by: f) else { return }
            undo.beginUndoGrouping()
            remove(a, from: page, name: "Resize")
            add(scaled, to: page, name: "Resize")
            undo.endUndoGrouping()
            select((page, scaled))
        default:
            let b = a.bounds
            let nb = CGRect(x: b.midX - b.width * f / 2, y: b.midY - b.height * f / 2, width: b.width * f, height: b.height * f)
            setBounds(nb, of: a, on: page, name: "Resize")
        }
        updateOutline()
    }

    private func deleteSelected() {
        guard case let (page, a)? = selected else { return }
        remove(a, from: page, name: "Delete")
    }

    private func markupSelection(_ type: PDFAnnotationSubtype) {
        guard let sel = pdfView.currentSelection else { return }
        let color: UIColor
        switch type {
        case .highlight: color = UIColor(red: 1, green: 0.84, blue: 0.04, alpha: 0.5)
        case .underline: color = ToolbarView.colors[1]
        default: color = ToolbarView.colors[2]
        }
        let made = AnnotationFactory.markup(sel, type: type, color: color)
        guard !made.isEmpty else { return }
        undo.beginUndoGrouping()
        made.forEach { add($0.1, to: $0.0, name: "Markup") }
        undo.endUndoGrouping()
        pdfView.clearSelection()
        markupBar.isHidden = true
    }

    // MARK: - Undoable edits

    func add(_ a: PDFAnnotation, to page: PDFPage, name: String) {
        page.addAnnotation(a)
        undo.registerUndo(withTarget: self) { $0.remove(a, from: page, name: name) }
        undo.setActionName(name)
    }

    func remove(_ a: PDFAnnotation, from page: PDFPage, name: String) {
        if selected?.annotation === a { deselect() }
        page.removeAnnotation(a)
        undo.registerUndo(withTarget: self) { $0.add(a, to: page, name: name) }
        undo.setActionName(name)
    }

    func setBounds(_ b: CGRect, of a: PDFAnnotation, on page: PDFPage, name: String) {
        let old = a.bounds
        a.bounds = b
        redisplay(a, on: page)
        undo.registerUndo(withTarget: self) { $0.setBounds(old, of: a, on: page, name: name) }
        undo.setActionName(name)
        updateOutline()
    }

    private func setColor(_ c: UIColor, of a: PDFAnnotation, on page: PDFPage) {
        let oldColor = a.color, oldFont = a.fontColor
        if a.type == "FreeText" {
            a.fontColor = c
        } else {
            let alpha = a.color.cgColor.alpha
            a.color = c.withAlphaComponent(alpha)
        }
        redisplay(a, on: page)
        undo.registerUndo(withTarget: self) { me in
            a.color = oldColor
            a.fontColor = oldFont
            me.redisplay(a, on: page)
        }
        undo.setActionName("Color")
    }

    private func setText(_ text: String, size: CGFloat, of a: PDFAnnotation, on page: PDFPage) {
        let oldText = a.contents ?? "", oldSize = a.font?.pointSize ?? 14
        a.contents = text
        a.font = UIFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
        AnnotationFactory.refit(a)
        redisplay(a, on: page)
        undo.registerUndo(withTarget: self) { $0.setText(oldText, size: oldSize, of: a, on: page) }
        undo.setActionName("Edit Text")
        updateOutline()
    }

    /// PDFKit doesn't always repaint after geometry changes; re-adding forces it.
    private func redisplay(_ a: PDFAnnotation, on page: PDFPage) {
        page.removeAnnotation(a)
        page.addAnnotation(a)
    }

    @objc private func undoChanged() {
        DispatchQueue.main.async {
            self.updateUndoButtons()
            self.updatePageLabel()
            if let s = self.selected, s.annotation.page == nil { self.deselect() }
            self.updateOutline()
        }
    }

    private func updateUndoButtons() {
        undoItem.isEnabled = undo.canUndo
        redoItem.isEnabled = undo.canRedo
    }

    @objc private func doUndo() { deselect(); if undo.canUndo { undo.undo() } }
    @objc private func doRedo() { deselect(); if undo.canRedo { undo.redo() } }

    // MARK: - Search

    @objc private func toggleSearch() {
        let show = searchContainer.isHidden
        UIView.animate(withDuration: 0.2) { self.searchContainer.isHidden = !show }
        if show {
            searchBar.becomeFirstResponder()
        } else {
            searchBar.resignFirstResponder()
            pdfView.highlightedSelections = nil
            results = []
            lastQuery = ""
            searchCount.text = nil
        }
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        let q = (searchBar.text ?? "").trimmingCharacters(in: .whitespaces)
        if q == lastQuery, !results.isEmpty { stepSearch(1); return }
        runSearch(q)
    }

    func runSearch(_ q: String) {
        lastQuery = q
        guard !q.isEmpty else { return }
        results = pdf.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive])
        results.forEach { $0.color = UIColor(red: 1, green: 0.75, blue: 0.1, alpha: 0.6) }
        pdfView.highlightedSelections = results
        resultIndex = 0
        showResult()
    }

    private func stepSearch(_ d: Int) {
        guard !results.isEmpty else {
            runSearch((searchBar.text ?? "").trimmingCharacters(in: .whitespaces))
            return
        }
        resultIndex = (resultIndex + d + results.count) % results.count
        showResult()
    }

    private func showResult() {
        guard !results.isEmpty else {
            searchCount.text = "No matches"
            return
        }
        let sel = results[resultIndex]
        searchCount.text = "\(resultIndex + 1) of \(results.count)"
        pdfView.setCurrentSelection(sel, animate: true)
        pdfView.go(to: sel)
    }

    // MARK: - Pages, sharing, more

    @objc private func showPages() {
        deselect()
        let current = pdfView.currentPage.map { pdf.index(for: $0) } ?? 0
        let grid = PageGridViewController(editor: pageEditor, current: current)
        grid.onPick = { [weak self] i in
            if let self = self, let page = self.pdf.page(at: i) { self.pdfView.go(to: page) }
        }
        let nav = UINavigationController(rootViewController: grid)
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }

    @objc private func pagesChanged() {
        pdfView.layoutDocumentView()
        updatePageLabel()
    }

    @objc private func share(_ sender: UIBarButtonItem) {
        deselect()
        let name = document.fileURL.lastPathComponent
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try PDFFileDocument.serialize(pdf).write(to: url, options: .atomic)
        } catch {
            toast("Couldn't prepare the file: \(error.localizedDescription)")
            return
        }
        document.autosave(completionHandler: nil)
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.popoverPresentationController?.barButtonItem = sender
        present(vc, animated: true)
    }

    @objc private func showMore(_ sender: UIBarButtonItem) {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Go to Page…", style: .default) { [weak self] _ in self?.goToPagePrompt() })
        sheet.addAction(UIAlertAction(title: pencilOnly ? "Let Fingers Draw Too" : "Only Apple Pencil Draws", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.setPencilOnly(!self.pencilOnly)
            self.toast(self.pencilOnly ? "Only Apple Pencil draws; fingers scroll" : "Fingers draw; use two fingers to scroll")
        })
        sheet.addAction(UIAlertAction(title: "Print…", style: .default) { [weak self] _ in self?.printDocument() })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = sender
        present(sheet, animated: true)
    }

    private func setPencilOnly(_ on: Bool) {
        pencilOnly = on
        UserDefaults.standard.set(on, forKey: "frogpdf.pencilOnly")
        applyGestureConfig()
    }

    private func goToPagePrompt() {
        let alert = UIAlertController(title: "Go to Page", message: "1 – \(pdf.pageCount)", preferredStyle: .alert)
        alert.addTextField { $0.keyboardType = .numberPad }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Go", style: .default) { [weak self] _ in
            guard let self = self, let n = Int(alert.textFields?.first?.text ?? ""), let page = self.pdf.page(at: n - 1) else { return }
            self.pdfView.go(to: page)
        })
        present(alert, animated: true)
    }

    private func printDocument() {
        let pc = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = title ?? "Frog PDF"
        info.outputType = .general
        pc.printInfo = info
        pc.printingItem = PDFFileDocument.serialize(pdf)
        pc.present(animated: true, completionHandler: nil)
    }

    @objc private func close() {
        deselect()
        document.close { [weak self] _ in self?.dismiss(animated: true) }
    }

    // MARK: - Keyboard (Magic Keyboard / Smart Keyboard)

    override var keyCommands: [UIKeyCommand]? {
        return [
            UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(doUndo), discoverabilityTitle: "Undo"),
            UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(doRedo), discoverabilityTitle: "Redo"),
            UIKeyCommand(input: "f", modifierFlags: .command, action: #selector(toggleSearch), discoverabilityTitle: "Find"),
            UIKeyCommand(input: "\u{8}", modifierFlags: [], action: #selector(keyDelete), discoverabilityTitle: "Delete Selection"),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(keyEscape), discoverabilityTitle: "Deselect"),
        ]
    }

    @objc private func keyDelete() { deleteSelected() }
    @objc private func keyEscape() { deselect(); setTool(.scroll) }
}

extension UIImage {
    func downscaled(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return normalizedOrientation() }
        let s = maxSide / longest
        let newSize = CGSize(width: (size.width * s).rounded(), height: (size.height * s).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}
