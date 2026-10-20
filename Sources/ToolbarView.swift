import UIKit

enum Tool: Int, CaseIterable {
    case scroll, select, pen, highlighter, text, box, whiteout, sign, image, eraser

    var title: String {
        switch self {
        case .scroll: return "Scroll"
        case .select: return "Select"
        case .pen: return "Pen"
        case .highlighter: return "Highlight"
        case .text: return "Text"
        case .box: return "Box"
        case .whiteout: return "White-out"
        case .sign: return "Sign"
        case .image: return "Image"
        case .eraser: return "Erase"
        }
    }

    /// SF Symbols, newest first; iOS 12 falls back to `glyph`.
    var symbols: [String] {
        switch self {
        case .scroll: return ["hand.raised", "hand.draw", "arrow.up.and.down"]
        case .select: return ["cursorarrow", "hand.point.up.left", "arrow.up.left"]
        case .pen: return ["pencil.tip", "pencil"]
        case .highlighter: return ["highlighter", "paintbrush"]
        case .text: return ["textformat", "t.square"]
        case .box: return ["square"]
        case .whiteout: return ["rectangle.fill"]
        case .sign: return ["signature", "pencil.and.outline"]
        case .image: return ["photo"]
        case .eraser: return ["eraser", "delete.left"]
        }
    }

    var glyph: String {
        switch self {
        case .scroll: return "✋"
        case .select: return "➢"
        case .pen: return "✎"
        case .highlighter: return "▮"
        case .text: return "T"
        case .box: return "□"
        case .whiteout: return "█"
        case .sign: return "✒"
        case .image: return "▣"
        case .eraser: return "⌫"
        }
    }

    /// Tools that draw with a drag, so one finger must not scroll.
    var isDrawing: Bool {
        switch self {
        case .pen, .highlighter, .box, .whiteout, .eraser: return true
        default: return false
        }
    }

    var hasColor: Bool {
        switch self {
        case .pen, .highlighter, .text, .box: return true
        default: return false
        }
    }
}

final class ToolButton: UIControl {
    let tool: Tool
    private let icon = UIImageView()
    private let glyph = UILabel()
    private let label = UILabel()

    init(tool: Tool) {
        self.tool = tool
        super.init(frame: .zero)
        layer.cornerRadius = 10
        let image = Compat.symbol(contentsOf: tool.symbols)
        icon.image = image
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        glyph.text = tool.glyph
        glyph.font = .systemFont(ofSize: 20)
        glyph.textColor = .white
        glyph.textAlignment = .center
        label.text = tool.title
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = UIColor(white: 1, alpha: 0.8)
        label.textAlignment = .center
        let top: UIView = image != nil ? icon : glyph
        let stack = UIStackView(arrangedSubviews: [top, label])
        stack.axis = .vertical
        stack.spacing = 3
        stack.alignment = .center
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 64),
            heightAnchor.constraint(equalToConstant: 52),
            icon.heightAnchor.constraint(equalToConstant: 22),
            icon.widthAnchor.constraint(equalToConstant: 26),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        accessibilityLabel = tool.title
        accessibilityTraits = .button
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isSelected: Bool {
        didSet { backgroundColor = isSelected ? Brand.green : .clear }
    }
}

extension Compat {
    static func symbol(contentsOf names: [String]) -> UIImage? {
        if #available(iOS 13.0, *) {
            let cfg = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
            for n in names {
                if let img = UIImage(systemName: n, withConfiguration: cfg) { return img }
            }
        }
        return nil
    }
}

/// Bottom bar: tools, then colour swatches and line widths for the active tool.
final class ToolbarView: UIView {
    static let colors: [UIColor] = [
        UIColor(white: 0.07, alpha: 1),
        UIColor(red: 0.12, green: 0.37, blue: 0.84, alpha: 1),
        UIColor(red: 0.84, green: 0.18, blue: 0.18, alpha: 1),
        UIColor(red: 0.12, green: 0.62, blue: 0.30, alpha: 1),
        UIColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1),
        UIColor.white,
    ]

    var onTool: ((Tool) -> Void)?
    var onColor: ((UIColor) -> Void)?
    var onWidth: ((Int) -> Void)?

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var toolButtons = [ToolButton]()
    private let optionStack = UIStackView()
    let pageLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Brand.darkGreen
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        stack.axis = .horizontal
        stack.spacing = 2
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        for t in Tool.allCases {
            let b = ToolButton(tool: t)
            b.addTarget(self, action: #selector(toolTapped(_:)), for: .touchUpInside)
            toolButtons.append(b)
            stack.addArrangedSubview(b)
        }
        let sep = UIView()
        sep.backgroundColor = UIColor(white: 1, alpha: 0.2)
        sep.widthAnchor.constraint(equalToConstant: 1).isActive = true
        sep.heightAnchor.constraint(equalToConstant: 34).isActive = true
        stack.addArrangedSubview(spacer(8))
        stack.addArrangedSubview(sep)
        stack.addArrangedSubview(spacer(8))
        optionStack.axis = .horizontal
        optionStack.spacing = 8
        optionStack.alignment = .center
        stack.addArrangedSubview(optionStack)
        stack.addArrangedSubview(spacer(16))
        pageLabel.textColor = UIColor(white: 1, alpha: 0.8)
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        stack.addArrangedSubview(pageLabel)
        stack.addArrangedSubview(spacer(12))

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 64),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func spacer(_ w: CGFloat) -> UIView {
        let v = UIView()
        v.widthAnchor.constraint(equalToConstant: w).isActive = true
        return v
    }

    @objc private func toolTapped(_ b: ToolButton) { onTool?(b.tool) }

    func select(_ tool: Tool) {
        toolButtons.forEach { $0.isSelected = $0.tool == tool }
    }

    /// Rebuilds the option area. `color` nil hides swatches; `widths` empty hides widths.
    func showOptions(color: UIColor?, widths: [CGFloat], widthIndex: Int) {
        optionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let color = color {
            for c in ToolbarView.colors {
                let b = UIButton(type: .custom)
                b.backgroundColor = c
                b.layer.cornerRadius = 14
                b.layer.borderWidth = c.isClose(to: color) ? 3 : 1.5
                b.layer.borderColor = c.isClose(to: color) ? UIColor.white.cgColor : UIColor(white: 1, alpha: 0.3).cgColor
                b.widthAnchor.constraint(equalToConstant: 28).isActive = true
                b.heightAnchor.constraint(equalToConstant: 28).isActive = true
                b.addAction { [weak self] in self?.onColor?(c) }
                optionStack.addArrangedSubview(b)
            }
        }
        if !widths.isEmpty {
            optionStack.addArrangedSubview(spacer(6))
            let maxW = widths.max() ?? 1
            for (i, w) in widths.enumerated() {
                let b = UIButton(type: .custom)
                b.layer.cornerRadius = 6
                b.backgroundColor = i == widthIndex ? UIColor(white: 1, alpha: 0.2) : .clear
                let bar = UIView()
                bar.backgroundColor = .white
                bar.isUserInteractionEnabled = false
                bar.layer.cornerRadius = 2
                bar.translatesAutoresizingMaskIntoConstraints = false
                b.addSubview(bar)
                NSLayoutConstraint.activate([
                    b.widthAnchor.constraint(equalToConstant: 36),
                    b.heightAnchor.constraint(equalToConstant: 32),
                    bar.centerXAnchor.constraint(equalTo: b.centerXAnchor),
                    bar.centerYAnchor.constraint(equalTo: b.centerYAnchor),
                    bar.widthAnchor.constraint(equalToConstant: 22),
                    bar.heightAnchor.constraint(equalToConstant: max(2, 12 * w / maxW)),
                ])
                b.addAction { [weak self] in self?.onWidth?(i) }
                optionStack.addArrangedSubview(b)
            }
        }
    }
}

extension UIColor {
    func isClose(to other: UIColor) -> Bool {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return abs(r1 - r2) + abs(g1 - g2) + abs(b1 - b2) < 0.05
    }
}

/// Closure-based target/action for iOS 12 (UIAction arrived in iOS 14).
private var actionKey: UInt8 = 0
final class ClosureBox: NSObject {
    let fn: () -> Void
    init(_ fn: @escaping () -> Void) { self.fn = fn }
    @objc func invoke() { fn() }
}

extension UIControl {
    func addAction(for event: UIControl.Event = .touchUpInside, _ fn: @escaping () -> Void) {
        let box = ClosureBox(fn)
        addTarget(box, action: #selector(ClosureBox.invoke), for: event)
        var boxes = (objc_getAssociatedObject(self, &actionKey) as? [ClosureBox]) ?? []
        boxes.append(box)
        objc_setAssociatedObject(self, &actionKey, boxes, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
