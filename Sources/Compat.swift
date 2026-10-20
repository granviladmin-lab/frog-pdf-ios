import UIKit

/// Shims so one code base runs on iOS 12 (iPad Air 1) and current iPadOS.
enum Compat {
    static var background: UIColor {
        if #available(iOS 13.0, *) { return .systemBackground }
        return .white
    }
    static var groupedBackground: UIColor {
        if #available(iOS 13.0, *) { return .secondarySystemBackground }
        return UIColor(white: 0.94, alpha: 1)
    }
    static var label: UIColor {
        if #available(iOS 13.0, *) { return .label }
        return .black
    }
    static var secondaryLabel: UIColor {
        if #available(iOS 13.0, *) { return .secondaryLabel }
        return .gray
    }

    /// First SF Symbol that exists on this OS, or nil (iOS 12 has none).
    static func symbol(_ names: String...) -> UIImage? {
        if #available(iOS 13.0, *) {
            for n in names {
                if let img = UIImage(systemName: n) { return img }
            }
        }
        return nil
    }

    static func barButton(_ title: String, symbols: [String], target: Any?, action: Selector) -> UIBarButtonItem {
        var img: UIImage?
        if #available(iOS 13.0, *) {
            for n in symbols where img == nil { img = UIImage(systemName: n) }
        }
        let item = img != nil
            ? UIBarButtonItem(image: img, style: .plain, target: target, action: action)
            : UIBarButtonItem(title: title, style: .plain, target: target, action: action)
        item.accessibilityLabel = title
        return item
    }
}

enum Brand {
    static let green = UIColor(red: 0.18, green: 0.62, blue: 0.31, alpha: 1)
    static let darkGreen = UIColor(red: 0.09, green: 0.24, blue: 0.15, alpha: 1)
}

extension UIViewController {
    func toast(_ message: String, seconds: TimeInterval = 2.4) {
        let label = PaddedLabel()
        label.text = message
        label.textColor = .white
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.backgroundColor = UIColor(white: 0.1, alpha: 0.9)
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alpha = 0
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.9),
        ])
        UIView.animate(withDuration: 0.2) { label.alpha = 1 }
        UIView.animate(withDuration: 0.3, delay: seconds, options: [], animations: { label.alpha = 0 }) { _ in
            label.removeFromSuperview()
        }
    }
}

final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
    }
}

var isRunningTests: Bool {
    return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
