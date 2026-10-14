import AppKit
import ImageIO

@main
enum AttachmentTests {
    static var assertions = 0
    static let fm = FileManager.default

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func expectFailure(_ message: String, _ operation: () throws -> Void) {
        assertions += 1
        do { try operation(); fputs("FAIL: \(message)\n", stderr); exit(1) } catch { }
    }

    static func main() throws {
        let temporary = fm.temporaryDirectory.appendingPathComponent("Sloth-attachment-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let sources = temporary.appendingPathComponent("sources")
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)
        let store = AttachmentStore(directory: temporary.appendingPathComponent("notes"))
        let payload = Data("A file that must survive import.\n".utf8)
        let file = sources.appendingPathComponent("My [research] (draft).pdf")
        try payload.write(to: file)
        let attachment = try store.importFile(file)
        expect(attachment.displayName == "My [research] (draft).pdf", "Original display name is retained")
        expect(attachment.relativePath.hasPrefix("attachments/"), "Files live below the owned attachment directory")
        expect(attachment.url.pathExtension == "pdf", "Safe extension is retained")
        expect(!attachment.isImage, "PDF and ordinary files use a file card link")
        expect(attachment.markdown.hasPrefix("[My \\[research\\] (draft).pdf]"), "Markdown labels escape brackets")
        let copied = try Data(contentsOf: attachment.url)
        expect(copied == payload, "Import copies complete file bytes")
        expect(fm.fileExists(atPath: file.path), "Import does not move or delete its source")
        try Data("Changed source".utf8).write(to: file)
        let retained = try Data(contentsOf: attachment.url)
        expect(retained == payload, "Imported attachment is independent of its source")
        expect(store.resolve(attachment.relativePath) == attachment.url, "Owned link resolves after import")
        expectFailure("Export cannot overwrite an immutable attachment in its own store") {
            try store.exportMarkdown(text: "Do not overwrite the attachment", to: attachment.url)
        }
        let temporaryFiles = try fm.contentsOfDirectory(atPath: store.rootURL.path).filter { $0.hasPrefix(".sloth-copy-") }
        expect(temporaryFiles.isEmpty, "Successful import leaves no private staging files")
        let second = try store.importFile(file)
        expect(second.relativePath != attachment.relativePath, "Repeated imports have collision-free identities")
        expect(store.resolve("attachments/../notes.json") == nil, "Parent traversal is rejected")
        expect(store.resolve("attachments/%2e%2e/secret") == nil, "Encoded traversal is rejected")
        expect(store.resolve("/etc/passwd") == nil, "Absolute paths are rejected")
        expect(store.resolve("file:///etc/passwd") == nil, "File URLs are rejected")
        expect(store.resolve("attachments/subdir/file.pdf") == nil, "Nested unowned paths are rejected")
        expect(store.resolve("attachments/.") == nil, "Directory links are rejected")
        expect(store.resolve("attachments/missing.pdf") == nil, "Missing attachment resolves safely")
        expectFailure("Directories cannot be imported") { _ = try store.importFile(sources) }
        let sourceLink = sources.appendingPathComponent("source-link.pdf")
        try fm.createSymbolicLink(at: sourceLink, withDestinationURL: file)
        expectFailure("Source symlinks cannot be imported") { _ = try store.importFile(sourceLink) }
        let ownedLink = store.rootURL.appendingPathComponent("escape.pdf")
        try fm.createSymbolicLink(at: ownedLink, withDestinationURL: file)
        expect(store.resolve("attachments/escape.pdf") == nil, "Owned-directory symlink cannot escape to another file")
        let falseRoot = temporary.appendingPathComponent("false-root")
        try fm.createDirectory(at: falseRoot, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: falseRoot.appendingPathComponent("attachments"), withDestinationURL: sources)
        let falseStore = AttachmentStore(directory: falseRoot)
        expectFailure("An attachment-root symlink cannot receive files") { _ = try falseStore.importFile(file) }
        expect(falseStore.resolve("attachments/My [research] (draft).pdf") == nil, "An attachment-root symlink cannot resolve files")

        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 8, bitsPerPixel: 32)!
        bitmap.setColor(.red, atX: 0, y: 0)
        let png = bitmap.representation(using: .png, properties: [:])!
        let imageSource = sources.appendingPathComponent("small image.png")
        try png.write(to: imageSource)
        let importedImage = try store.importFile(imageSource)
        expect(importedImage.isImage, "A valid native image is recognized")
        expect(importedImage.markdown.hasPrefix("![small image.png]"), "Images produce Markdown image links")
        let pasted = try store.importPNGData(png)
        expect(pasted.isImage && pasted.url.pathExtension == "png", "Pasted PNG is stored as an image")
        expect(NSImage(contentsOf: pasted.url)?.isValid == true, "Pasted image remains readable")
        let nativeImage = NSImage(data: png)!
        let pastedNative = try store.importImage(nativeImage, name: "Screen [capture]")
        expect(pastedNative.markdown.hasPrefix("![Screen \\[capture\\]]"), "NSImage paste preserves escaped display label")
        expectFailure("Invalid image bytes do not enter the store") { _ = try store.importPNGData(payload) }
        let fakePNG = sources.appendingPathComponent("fake.png")
        try payload.write(to: fakePNG)
        let fake = try store.importFile(fakePNG)
        expect(!fake.isImage, "Image-looking filename does not make arbitrary data an image")

        // Use a real PDF page, not arbitrary bytes with a .pdf extension:
        // ImageIO can read a PDF and used to incorrectly classify it as an image.
        let pdfURL = sources.appendingPathComponent("A genuine document.pdf")
        var page = CGRect(x: 0, y: 0, width: 100, height: 100)
        let consumer = CGDataConsumer(url: pdfURL as CFURL)!
        let context = CGContext(consumer: consumer, mediaBox: &page, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 10, y: 10, width: 80, height: 80))
        context.endPDFPage()
        context.closePDF()
        let pdfBytes = try Data(contentsOf: pdfURL)
        expect(pdfBytes.starts(with: Data("%PDF".utf8)), "PDF regression fixture contains a real PDF document")
        let pdfImageSource = CGImageSourceCreateWithURL(pdfURL as CFURL, nil)
        expect(pdfImageSource.flatMap { CGImageSourceGetType($0) as String? } == "com.adobe.pdf", "PDF fixture exercises ImageIO document decoding")
        let importedPDF = try store.importFile(pdfURL)
        expect(!importedPDF.isImage, "A real PDF is classified as a document attachment")
        expect(importedPDF.markdown.hasPrefix("[A genuine document.pdf]"), "PDF attachment uses a file-card link instead of image Markdown")
        let disguisedPDF = sources.appendingPathComponent("document-disguised-as-image.png")
        try pdfBytes.write(to: disguisedPDF)
        expect(!AttachmentStore.isImage(at: disguisedPDF), "PDF detection uses contents even with a misleading image extension")

        let sourceText = "# Research\n\n\(attachment.markdown)\n\(importedImage.markdown)\n\(attachment.markdown)\n[Website](https://example.com/a)\n"
        let references = store.references(in: sourceText)
        expect(references.count == 4, "Escaped labels and image references parse correctly")
        expect(references.first?.label == attachment.displayName, "Escaped label is decoded for display")
        expect(references.filter(\.isImage).count == 1, "Image references retain their Markdown type")
        let fancy = "![x](<images/a b.png>)\n[p](images/a%20b.png)\n[t](images/a.png \"title\")\n[p](images/a(b).png)"
        expect(store.references(in: fancy).map(\.path) == ["images/a b.png", "images/a b.png", "images/a.png", "images/a(b).png"], "Angle paths, URL escapes, titles, and parentheses parse")
        expect(store.references(in: "`[x](attachments/not-real.pdf)`\n```md\n![x](attachments/missing.png)\n```\n\\[no](attachments/escaped.pdf)").isEmpty, "Code examples and escaped links are ignored")

        let exportDirectory = temporary.appendingPathComponent("export")
        try fm.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let destination = exportDirectory.appendingPathComponent("Research.md")
        try store.exportMarkdown(text: sourceText, to: destination)
        let exportedText = try String(contentsOf: destination, encoding: .utf8)
        expect(exportedText == sourceText, "Markdown export retains the exact source")
        let exportedFiles = try fm.contentsOfDirectory(atPath: exportDirectory.appendingPathComponent("attachments").path)
        expect(exportedFiles.count == 2, "Export includes only the distinct referenced attachments")
        let exportedData = try Data(contentsOf: exportDirectory.appendingPathComponent(attachment.relativePath))
        expect(exportedData == payload, "Exported file is portable and complete")
        try store.exportMarkdown(text: sourceText + "\nUpdated", to: destination)
        let reexported = try String(contentsOf: destination, encoding: .utf8)
        expect(reexported.hasSuffix("Updated"), "Repeated export can reuse identical existing assets")
        let collisionURL = exportDirectory.appendingPathComponent(attachment.relativePath)
        try Data("A different file".utf8).write(to: collisionURL)
        expectFailure("Export rejects same-name files with different content") { try store.exportMarkdown(text: sourceText, to: destination) }
        let unchanged = try String(contentsOf: destination, encoding: .utf8)
        expect(unchanged == reexported, "Failed export leaves the existing note intact")
        let conflictData = try Data(contentsOf: collisionURL)
        expect(conflictData == Data("A different file".utf8), "Failed export leaves conflicting attachments intact")
        expectFailure("Missing owned attachments cause an actionable export failure") { try store.exportMarkdown(text: "![missing](attachments/missing.png)", to: destination) }
        let exportLinkDir = temporary.appendingPathComponent("export-link")
        try fm.createDirectory(at: exportLinkDir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: exportLinkDir.appendingPathComponent("attachments"), withDestinationURL: sources)
        expectFailure("Export never follows a destination attachment symlink") { try store.exportMarkdown(text: sourceText, to: exportLinkDir.appendingPathComponent("note.md")) }

        let importedStore = AttachmentStore(directory: temporary.appendingPathComponent("imported-notes"))
        let externalText = "# Import\n![Photo](<small image.png>)\n![Again](small%20image.png)\n[Source](https://example.com/image.png)\n"
        let importedText = try importedStore.importMarkdown(text: externalText, relativeTo: sources)
        let importedReferences = importedStore.references(in: importedText)
        expect(importedReferences.count == 3, "Import retains image and remote links")
        expect(importedReferences[0].path == importedReferences[1].path, "Repeated external references share a copied attachment")
        expect(importedStore.resolve(importedReferences[0].path) != nil, "External local image is now self-contained")
        expect(importedText.contains("https://example.com/image.png"), "Remote URLs remain untouched")
        let beforeFailure = try fm.contentsOfDirectory(atPath: importedStore.rootURL.path).count
        expectFailure("Markdown traversal cannot read outside the selected folder") {
            _ = try importedStore.importMarkdown(text: "[escape](../notes/notes.json)", relativeTo: sources)
        }
        expectFailure("Markdown symlinks cannot read outside the selected folder") {
            _ = try importedStore.importMarkdown(text: "[escape](source-link.pdf)", relativeTo: sources)
        }
        expectFailure("Missing import attachment fails without a partial note") {
            _ = try importedStore.importMarkdown(text: "[Missing](missing.pdf)\n![Copied first](small%20image.png)", relativeTo: sources)
        }
        let afterFailure = try fm.contentsOfDirectory(atPath: importedStore.rootURL.path).count
        expect(beforeFailure == afterFailure, "Failed Markdown import rolls back newly copied files")
        print("Passed \(assertions) attachment assertions.")
    }
}
