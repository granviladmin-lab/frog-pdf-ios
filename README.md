# Frog PDF for iOS

Native PDF viewer and editor for iPad and iPhone, built with UIKit and PDFKit.
Runs on iOS 12 (2013 iPad Air) through current iPadOS.

- Opens PDFs in place from Files, iCloud Drive and other providers; "Open in Frog PDF" from any app
- Pen and highlighter (Apple Pencil draws while fingers scroll), text, boxes, white-out, signatures, photos, eraser
- Highlight / underline / strike out selected text, search, go to page
- Page grid: drag to reorder, rotate, duplicate, insert blank, add pages from another PDF, delete
- Undo/redo, keyboard shortcuts, dark mode, multiple windows and Split View on iPadOS 13+
- Edits save to the original file; share/print from the app

## Build

There's no Mac involved: GitHub Actions (`macos-15`) generates the Xcode project with XcodeGen
(`project.yml`), runs the unit and screenshot tests on an iPad simulator, and produces an unsigned
`FrogPDF.ipa` (artifact on every push; attached to a release for `v*` tags).

## Install with a free Apple ID

Sign and sideload the IPA with a tool such as Sideloader or PlumeImpactor, using your own Apple ID.
Apps signed with a free account expire after 7 days; re-sign to renew (your files are kept).
