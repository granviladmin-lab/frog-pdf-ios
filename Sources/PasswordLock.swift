import UIKit
import CommonCrypto

/// Same password check as the Frog PDF web app: PBKDF2-SHA256 against a stored hash.
/// The plaintext password is never stored.
enum PasswordLock {
    static let salt = "a88f0887615c6abe077a46c3f4a7590a"
    static let iterations: UInt32 = 200_000
    static let hash = "77977b601b45a85b96d405835c62cc31849630a26b36e372b5ddb5ce6fa45648"
    private static let key = "frogpdf.unlocked"

    static var isUnlocked: Bool {
        return UserDefaults.standard.string(forKey: key) == hash
    }

    static func remember() { UserDefaults.standard.set(hash, forKey: key) }

    static func derive(_ password: String) -> String {
        return derive(password, salt: hexBytes(salt), iterations: iterations)
    }

    static func derive(_ password: String, salt saltBytes: [UInt8], iterations rounds: UInt32) -> String {
        let pw = Array(password.utf8).map { Int8(bitPattern: $0) }
        var out = [UInt8](repeating: 0, count: 32)
        _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count,
                                 saltBytes, saltBytes.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                                 &out, out.count)
        return out.map { String(format: "%02x", $0) }.joined()
    }

    static func check(_ password: String) -> Bool { return derive(password) == hash }

    private static func hexBytes(_ h: String) -> [UInt8] {
        var bytes = [UInt8]()
        var idx = h.startIndex
        while idx < h.endIndex {
            let next = h.index(idx, offsetBy: 2)
            bytes.append(UInt8(h[idx..<next], radix: 16) ?? 0)
            idx = next
        }
        return bytes
    }
}

final class LockViewController: UIViewController, UITextFieldDelegate {
    private let field = UITextField()
    private let message = UILabel()
    private let button = UIButton(type: .system)
    private let remember = UISwitch()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Brand.darkGreen

        let logo = UIImageView(image: UIImage(named: "FrogLogo"))
        logo.contentMode = .scaleAspectFit
        logo.layer.cornerRadius = 28
        logo.clipsToBounds = true

        let title = UILabel()
        title.text = "Frog PDF"
        title.font = .systemFont(ofSize: 30, weight: .bold)
        title.textColor = .white
        title.textAlignment = .center

        field.placeholder = "Password"
        field.isSecureTextEntry = true
        field.borderStyle = .roundedRect
        field.font = .systemFont(ofSize: 18)
        field.backgroundColor = .white
        field.textColor = .black
        field.returnKeyType = .go
        field.delegate = self
        field.autocapitalizationType = .none
        field.autocorrectionType = .no

        remember.isOn = true
        remember.onTintColor = Brand.green
        let rememberLabel = UILabel()
        rememberLabel.text = "Remember on this device"
        rememberLabel.textColor = UIColor(white: 1, alpha: 0.85)
        rememberLabel.font = .systemFont(ofSize: 15)
        let rememberRow = UIStackView(arrangedSubviews: [rememberLabel, remember])
        rememberRow.spacing = 10

        button.setTitle("Unlock", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = Brand.green
        button.layer.cornerRadius = 12
        button.addTarget(self, action: #selector(unlock), for: .touchUpInside)

        message.textColor = UIColor(red: 1, green: 0.7, blue: 0.68, alpha: 1)
        message.textAlignment = .center
        message.font = .systemFont(ofSize: 15)

        let stack = UIStackView(arrangedSubviews: [logo, title, field, rememberRow, button, message])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 140),
            logo.heightAnchor.constraint(equalToConstant: 140),
            field.widthAnchor.constraint(equalToConstant: 300),
            field.heightAnchor.constraint(equalToConstant: 48),
            button.widthAnchor.constraint(equalToConstant: 300),
            button.heightAnchor.constraint(equalToConstant: 50),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        field.becomeFirstResponder()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { return .lightContent }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        unlock()
        return false
    }

    @objc private func unlock() {
        let pw = field.text ?? ""
        guard !pw.isEmpty else { return }
        button.isEnabled = false
        message.text = "Checking…"
        let keep = remember.isOn
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = PasswordLock.check(pw)
            DispatchQueue.main.async {
                self.button.isEnabled = true
                if ok {
                    if keep { PasswordLock.remember() }
                    self.field.resignFirstResponder()
                    self.dismiss(animated: true)
                } else {
                    self.message.text = "Wrong password"
                    self.field.selectAll(nil)
                    let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
                    shake.values = [-12, 12, -8, 8, 0]
                    shake.duration = 0.35
                    self.field.layer.add(shake, forKey: "shake")
                }
            }
        }
    }
}
