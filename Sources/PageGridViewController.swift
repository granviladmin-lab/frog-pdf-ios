import UIKit
import PDFKit
import MobileCoreServices

/// Page operations with undo. Shared by the page grid and tests.
final class PageEditor {
    static let didChange = Notification.Name("FrogPDFPagesChanged")
    let pdf: PDFDocument
    let undo: UndoManager
    /// Called after every change (the open page grid reloads); also posts `didChange`.
    var onChange: (() -> Void)?
    /// Pages inserted from other files keep a reference to their source document.
    private var sources = [PDFDocument]()

    init(pdf: PDFDocument, undo: UndoManager) {
        self.pdf = pdf
        self.undo = undo
    }

    func rotate(_ i: Int, by degrees: Int) {
        guard let page = pdf.page(at: i) else { return }
        page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        undo.registerUndo(withTarget: self) { $0.rotate(i, by: -degrees) }
        undo.setActionName("Rotate Page")
        changed()
    }

    func move(from: Int, to: Int) {
        guard from != to, let page = pdf.page(at: from) else { return }
        pdf.removePage(at: from)
        pdf.insert(page, at: to)
        undo.registerUndo(withTarget: self) { $0.move(from: to, to: from) }
        undo.setActionName("Move Page")
        changed()
    }

    func delete(_ i: Int) {
        guard pdf.pageCount > 1, let page = pdf.page(at: i) else { return }
        pdf.removePage(at: i)
        undo.registerUndo(withTarget: self) { $0.insert(page, at: i) }
        undo.setActionName("Delete Page")
        changed()
    }

    func insert(_ page: PDFPage, at i: Int) {
        pdf.insert(page, at: i)
        undo.registerUndo(withTarget: self) { $0.delete(i) }
        undo.setActionName("Insert Page")
        changed()
    }

    private func changed() {
        onChange?()
        NotificationCenter.default.post(name: PageEditor.didChange, object: self)
    }

    func duplicate(_ i: Int) {
        guard let page = pdf.page(at: i), let copy = page.copy() as? PDFPage else { return }
        insert(copy, at: i + 1)
    }

    func insertBlank(after i: Int) {
        let ref = pdf.page(at: i)
        let size = ref?.bounds(for: .mediaBox).size ?? CGSize(width: 612, height: 792)
        guard let doc = PDFDocument(data: PDFFileDocument.blankPDF(size: size)), let page = doc.page(at: 0) else { return }
        sources.append(doc)
        page.rotation = ref?.rotation ?? 0
        insert(page, at: i + 1)
    }

    /// Inserts every page of `other` after index `i`. Returns the number of pages added.
    @discardableResult
    func insertDocument(_ other: PDFDocument, after i: Int) -> Int {
        sources.append(other)
        undo.beginUndoGrouping()
        for k in 0..<other.pageCount {
            if let p = other.page(at: k) { insert(p, at: i + 1 + k) }
        }
        undo.endUndoGrouping()
        undo.setActionName("Add Pages")
        return other.pageCount
    }
}

final class PageCell: UICollectionViewCell {
    let imageView = UIImageView()
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.layer.shadowColor = UIColor.black.cgColor
        imageView.layer.shadowOpacity = 0.25
        imageView.layer.shadowRadius = 3
        imageView.layer.shadowOffset = CGSize(width: 0, height: 1)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textAlignment = .center
        label.textColor = Compat.secondaryLabel
        let stack = UIStackView(arrangedSubviews: [imageView, label])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        contentView.layer.cornerRadius = 10
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            label.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isSelected: Bool {
        didSet {
            contentView.backgroundColor = isSelected ? Brand.green.withAlphaComponent(0.25) : .clear
            contentView.layer.borderWidth = isSelected ? 2 : 0
            contentView.layer.borderColor = Brand.green.cgColor
        }
    }
}

final class PageGridViewController: UICollectionViewController, UIDocumentPickerDelegate {
    private let editor: PageEditor
    private var selectedIndex: Int
    var onPick: ((Int) -> Void)?

    init(editor: PageEditor, current: Int) {
        self.editor = editor
        self.selectedIndex = current
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 150, height: 210)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 16
        layout.sectionInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        super.init(collectionViewLayout: layout)
        title = "Pages"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = Compat.groupedBackground
        collectionView.register(PageCell.self, forCellWithReuseIdentifier: "page")
        installsStandardGestureForInteractiveMovement = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        navigationItem.prompt = "Tap a page to select it. Press and drag to reorder."
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        toolbarItems = [
            Compat.barButton("Rotate Left", symbols: ["rotate.left"], target: self, action: #selector(rotateLeft)), flex,
            Compat.barButton("Rotate Right", symbols: ["rotate.right"], target: self, action: #selector(rotateRight)), flex,
            Compat.barButton("Duplicate", symbols: ["plus.square.on.square", "doc.on.doc"], target: self, action: #selector(duplicate)), flex,
            Compat.barButton("Blank Page", symbols: ["doc.badge.plus", "plus.rectangle"], target: self, action: #selector(blank)), flex,
            Compat.barButton("Add PDF", symbols: ["doc.on.clipboard", "folder.badge.plus"], target: self, action: #selector(addPDF)), flex,
            Compat.barButton("Delete", symbols: ["trash"], target: self, action: #selector(deletePage)),
        ]
        editor.onChange = { [weak self] in self?.reload() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: false)
        reload()
    }

    private func reload() {
        selectedIndex = min(selectedIndex, max(0, editor.pdf.pageCount - 1))
        collectionView.reloadData()
        let ip = IndexPath(item: selectedIndex, section: 0)
        if editor.pdf.pageCount > 0 {
            collectionView.selectItem(at: ip, animated: false, scrollPosition: [])
        }
    }

    @objc private func close() { dismiss(animated: true) }

    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return editor.pdf.pageCount
    }

    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "page", for: indexPath) as! PageCell
        if let page = editor.pdf.page(at: indexPath.item) {
            cell.imageView.image = page.thumbnail(of: CGSize(width: 268, height: 360), for: .cropBox)
        }
        cell.label.text = "\(indexPath.item + 1)"
        cell.isSelected = indexPath.item == selectedIndex
        return cell
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if selectedIndex == indexPath.item {
            // second tap jumps to the page
            onPick?(indexPath.item)
            dismiss(animated: true)
            return
        }
        selectedIndex = indexPath.item
    }

    override func collectionView(_ collectionView: UICollectionView, canMoveItemAt indexPath: IndexPath) -> Bool { return true }

    override func collectionView(_ collectionView: UICollectionView, moveItemAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        selectedIndex = destinationIndexPath.item
        editor.move(from: sourceIndexPath.item, to: destinationIndexPath.item)
    }

    @objc private func rotateLeft() { editor.rotate(selectedIndex, by: -90) }
    @objc private func rotateRight() { editor.rotate(selectedIndex, by: 90) }
    @objc private func duplicate() { editor.duplicate(selectedIndex); selectedIndex += 1; reload() }
    @objc private func blank() { editor.insertBlank(after: selectedIndex); selectedIndex += 1; reload() }

    @objc private func deletePage() {
        guard editor.pdf.pageCount > 1 else {
            toast("A PDF needs at least one page")
            return
        }
        let alert = UIAlertController(title: "Delete page \(selectedIndex + 1)?", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in self.editor.delete(self.selectedIndex) })
        present(alert, animated: true)
    }

    @objc private func addPDF() {
        // the pre-iOS 14 initializer still works and avoids linking UniformTypeIdentifiers on iOS 12
        let picker = UIDocumentPickerViewController(documentTypes: [kUTTypePDF as String], in: .import)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let other = PDFDocument(data: data), !other.isLocked else {
            toast("Couldn't read that PDF")
            return
        }
        let n = editor.insertDocument(other, after: selectedIndex)
        selectedIndex += 1
        reload()
        toast("Added \(n) page\(n == 1 ? "" : "s") from \(url.lastPathComponent)")
    }
}
