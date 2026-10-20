import UIKit

/// Multi-line text entry with a font size picker.
final class TextEntryViewController: UIViewController {
    static let sizes: [CGFloat] = [10, 12, 14, 18, 24, 32, 48]
    private let textView = UITextView()
    private let sizeControl = UISegmentedControl(items: TextEntryViewController.sizes.map { String(format: "%g", Double($0)) })
    private let initialText: String
    private let initialSize: CGFloat
    var onDone: ((String, CGFloat) -> Void)?

    init(title: String, text: String, size: CGFloat) {
        initialText = text
        initialSize = size
        super.init(nibName: nil, bundle: nil)
        self.title = title
        preferredContentSize = CGSize(width: 460, height: 280)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Compat.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
        textView.text = initialText
        textView.font = UIFont(name: "Helvetica", size: 18)
        textView.textColor = Compat.label
        textView.backgroundColor = Compat.groupedBackground
        textView.layer.cornerRadius = 8
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        sizeControl.selectedSegmentIndex = TextEntryViewController.sizes.firstIndex(of: initialSize) ?? 2
        let sizeLabel = UILabel()
        sizeLabel.text = "Size"
        sizeLabel.textColor = Compat.secondaryLabel
        let row = UIStackView(arrangedSubviews: [sizeLabel, sizeControl])
        row.spacing = 10
        let stack = UIStackView(arrangedSubviews: [textView, row])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            textView.heightAnchor.constraint(equalToConstant: 140),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }

    @objc private func cancel() { dismiss(animated: true) }

    @objc private func done() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let size = TextEntryViewController.sizes[max(0, sizeControl.selectedSegmentIndex)]
        dismiss(animated: true) { if !text.isEmpty { self.onDone?(text, size) } }
    }
}

// MARK: - Signatures

/// A signature as normalised strokes: x in 0...1, y in 0...aspect (y down).
struct Signature: Codable {
    var strokes: [[CGPoint]]
    var aspect: CGFloat

    func image(height: CGFloat, color: UIColor = .black) -> UIImage {
        let w = height / max(aspect, 0.05)
        let size = CGSize(width: w + 8, height: height + 8)
        return UIGraphicsImageRenderer(size: size).image { _ in
            color.setStroke()
            for s in strokes {
                let path = AnnotationFactory.smoothPath(s.map { CGPoint(x: 4 + $0.x * w, y: 4 + $0.y * w) })
                path.lineWidth = 2
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
        }
    }
}

enum SignatureStore {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("signatures.json")
    }

    static func load() -> [Signature] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Signature].self, from: data)) ?? []
    }

    static func save(_ sigs: [Signature]) {
        if let data = try? JSONEncoder().encode(sigs) { try? data.write(to: url, options: .atomic) }
    }
}

final class SignaturePadView: UIView {
    private(set) var strokes = [[CGPoint]]()
    private var current = [CGPoint]()
    var inkColor: UIColor = .black

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        layer.cornerRadius = 10
        layer.borderWidth = 1
        layer.borderColor = UIColor(white: 0.75, alpha: 1).cgColor
        isMultipleTouchEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func clear() { strokes = []; current = []; setNeedsDisplay() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        current = [t.location(in: self)]
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let samples = event?.coalescedTouches(for: t) ?? [t]
        current.append(contentsOf: samples.map { $0.location(in: self) })
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !current.isEmpty { strokes.append(current) }
        current = []
        setNeedsDisplay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touchesEnded(touches, with: event) }

    override func draw(_ rect: CGRect) {
        UIColor(white: 0.85, alpha: 1).setStroke()
        let line = UIBezierPath()
        line.move(to: CGPoint(x: 24, y: bounds.height * 0.72))
        line.addLine(to: CGPoint(x: bounds.width - 24, y: bounds.height * 0.72))
        line.lineWidth = 1
        line.stroke()
        inkColor.setStroke()
        for s in strokes + [current] where !s.isEmpty {
            let p = AnnotationFactory.smoothPath(s)
            p.lineWidth = 3
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.stroke()
        }
    }

    /// Normalised signature, or nil if nothing meaningful was drawn.
    func signature() -> Signature? {
        let all = strokes.flatMap { $0 }
        guard let minX = all.map({ $0.x }).min(), let maxX = all.map({ $0.x }).max(),
              let minY = all.map({ $0.y }).min(), let maxY = all.map({ $0.y }).max() else { return nil }
        let w = maxX - minX, h = maxY - minY
        guard w > 12 || h > 12 else { return nil }
        let unit = max(w, 1)
        let norm = strokes.map { s in s.map { CGPoint(x: ($0.x - minX) / unit, y: ($0.y - minY) / unit) } }
        return Signature(strokes: norm, aspect: max(h, 1) / unit)
    }
}

/// Hands screen-edge gestures (Control Center, home indicator) to the app first, so a
/// stroke that runs to the edge of the pad isn't taken over by the system.
final class DrawingNavigationController: UINavigationController {
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { return .all }
}

final class SignatureViewController: UIViewController {
    var onChoose: ((Signature) -> Void)?
    private let pad = SignaturePadView()
    private let savedStack = UIStackView()
    private var saved = SignatureStore.load()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Signature"
        view.backgroundColor = Compat.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Use", style: .done, target: self, action: #selector(use)),
            UIBarButtonItem(title: "Clear", style: .plain, target: self, action: #selector(clear)),
        ]

        let savedLabel = UILabel()
        savedLabel.font = .systemFont(ofSize: 13)
        savedLabel.textColor = Compat.secondaryLabel
        savedLabel.text = "Tap a saved signature, or sign below (it's saved for next time). Long-press to delete."
        savedLabel.numberOfLines = 0
        savedStack.axis = .horizontal
        savedStack.spacing = 10
        let savedScroll = UIScrollView()
        savedScroll.addSubview(savedStack)
        savedStack.translatesAutoresizingMaskIntoConstraints = false

        // full screen now, so cap the pad at a signing-box height instead of filling a tall iPad
        let padHeight = pad.heightAnchor.constraint(equalToConstant: 360)
        padHeight.priority = .defaultHigh
        let stack = UIStackView(arrangedSubviews: [savedLabel, savedScroll, pad])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            savedScroll.heightAnchor.constraint(equalToConstant: 64),
            pad.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            padHeight,
            savedStack.leadingAnchor.constraint(equalTo: savedScroll.contentLayoutGuide.leadingAnchor),
            savedStack.trailingAnchor.constraint(equalTo: savedScroll.contentLayoutGuide.trailingAnchor),
            savedStack.topAnchor.constraint(equalTo: savedScroll.contentLayoutGuide.topAnchor),
            savedStack.bottomAnchor.constraint(equalTo: savedScroll.contentLayoutGuide.bottomAnchor),
            savedStack.heightAnchor.constraint(equalTo: savedScroll.frameLayoutGuide.heightAnchor),
        ])
        reloadSaved()
    }

    private func reloadSaved() {
        savedStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, s) in saved.enumerated() {
            let b = UIButton(type: .custom)
            b.setImage(s.image(height: 48), for: .normal)
            b.backgroundColor = .white
            b.layer.cornerRadius = 8
            b.layer.borderWidth = 1
            b.layer.borderColor = UIColor(white: 0.8, alpha: 1).cgColor
            b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
            b.addAction { [weak self] in self?.choose(s) }
            let lp = UILongPressGestureRecognizer(target: self, action: #selector(deleteSaved(_:)))
            b.tag = i
            b.addGestureRecognizer(lp)
            savedStack.addArrangedSubview(b)
        }
    }

    @objc private func deleteSaved(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let i = g.view?.tag, i < saved.count else { return }
        let alert = UIAlertController(title: "Delete this signature?", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
            self.saved.remove(at: i)
            SignatureStore.save(self.saved)
            self.reloadSaved()
        })
        present(alert, animated: true)
    }

    private func choose(_ s: Signature) {
        dismiss(animated: true) { self.onChoose?(s) }
    }

    @objc private func cancel() { dismiss(animated: true) }
    @objc private func clear() { pad.clear() }

    @objc private func use() {
        guard let s = pad.signature() else {
            toast("Sign in the box first")
            return
        }
        saved.insert(s, at: 0)
        SignatureStore.save(Array(saved.prefix(6)))
        choose(s)
    }
}
