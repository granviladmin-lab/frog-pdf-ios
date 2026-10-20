import UIKit
import PDFKit

/// Home screen: the system Files browser (recents, iCloud Drive, On My iPad, other providers).
final class DocumentBrowserViewController: UIDocumentBrowserViewController, UIDocumentBrowserViewControllerDelegate {
    private var pendingURL: URL?

    init() {
        super.init(forOpeningFilesWithContentTypes: ["com.adobe.pdf"])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        allowsDocumentCreation = true
        allowsPickingMultipleItems = false
        browserUserInterfaceStyle = .white
        view.tintColor = Brand.green
        let about = UIBarButtonItem(title: "Frog PDF", style: .plain, target: self, action: #selector(showAbout))
        additionalLeadingNavigationBarButtonItems = [about]
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let url = pendingURL, presentedViewController == nil {
            pendingURL = nil
            openExternal(url)
        }
    }

    @objc private func showAbout() {
        let alert = UIAlertController(title: "Frog PDF",
                                      message: "View, mark up, sign and rearrange PDFs. Files are edited in place and save automatically.\n\nTip: with an Apple Pencil, the pencil draws and your finger scrolls.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: Opening

    func openExternal(_ url: URL) {
        // Wait until the lock screen (or another document) is dismissed.
        if presentedViewController != nil {
            pendingURL = url
            return
        }
        revealDocument(at: url, importIfNeeded: true) { [weak self] revealed, error in
            if let error = error {
                self?.showError(error)
                return
            }
            if let revealed = revealed { self?.presentDocument(at: revealed) }
        }
    }

    func presentDocument(at url: URL) {
        let document = PDFFileDocument(fileURL: url)
        document.open { [weak self] ok in
            guard let self = self else { return }
            guard ok, let pdf = document.pdf else {
                self.showError(NSError(domain: "FrogPDF", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't open \(url.lastPathComponent)."]))
                return
            }
            self.unlockIfNeeded(pdf) { unlocked in
                guard unlocked else { document.close(completionHandler: nil); return }
                let editor = EditorViewController(document: document)
                let nav = UINavigationController(rootViewController: editor)
                nav.modalPresentationStyle = .fullScreen
                self.present(nav, animated: true)
            }
        }
    }

    private func unlockIfNeeded(_ pdf: PDFDocument, completion: @escaping (Bool) -> Void) {
        guard pdf.isLocked else { completion(true); return }
        let alert = UIAlertController(title: "Password protected", message: "Enter the password for this PDF.", preferredStyle: .alert)
        alert.addTextField { $0.isSecureTextEntry = true }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: "Unlock", style: .default) { [weak self] _ in
            if pdf.unlock(withPassword: alert.textFields?.first?.text ?? "") {
                completion(true)
            } else {
                self?.unlockIfNeeded(pdf, completion: completion)
            }
        })
        present(alert, animated: true)
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: "Frog PDF", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: UIDocumentBrowserViewControllerDelegate

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentsAt documentURLs: [URL]) {
        if let url = documentURLs.first { presentDocument(at: url) }
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController,
                         didRequestDocumentCreationWithHandler importHandler: @escaping (URL?, UIDocumentBrowserViewController.ImportMode) -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Untitled.pdf")
        do {
            try PDFFileDocument.blankPDF().write(to: url, options: .atomic)
            importHandler(url, .move)
        } catch {
            importHandler(nil, .none)
        }
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didImportDocumentAt sourceURL: URL, toDestinationURL destinationURL: URL) {
        presentDocument(at: destinationURL)
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, failedToImportDocumentAt documentURL: URL, error: Error?) {
        if let error = error { showError(error) }
    }
}
