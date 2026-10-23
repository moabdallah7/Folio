import Foundation
import AppKit
import PDFKit

@main struct LibraryChecks {
    static var checks = 0
    static func check(_ value: Bool, _ message: String, line: Int = #line) {
        guard value else { fatalError("FAIL line \(line): \(message)") }; checks += 1
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FolioTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let repository = LibraryRepository(url: folder.appendingPathComponent("library.json"))
        check(try repository.load() == nil, "new library is absent")
        let legacy = Sheet(title: "مرحبا • Café", text: "First line\n\nUnicode ✨ and words.", favorite: true)
        var legacyFile = LibraryFile(sheets: [legacy]); legacyFile.version = 1
        try LibraryRepository.encode(legacyFile).write(to: repository.url)
        let store = LibraryStore(directory: folder)
        check(store.current?.id == legacy.id && !store.current!.isRich, "version 1 migration keeps Markdown and Unicode")
        store.persist()
        check(try repository.loadFile()?.version == 3, "migration writes version 3")
        check(try FileManager.default.contentsOfDirectory(at: store.backupsURL, includingPropertiesForKeys: nil).count == 1, "pre-upgrade backup exists")
        let unchanged = store.current!.modified
        store.update(legacy.id) { $0.title = legacy.title }
        check(store.current!.modified == unchanged, "selecting unchanged text does not alter modification date")
        check(store.addNotebook("Research"), "create notebook")
        check(!store.addNotebook("research") && !store.addNotebook("Trash"), "reject duplicate and reserved notebooks")
        store.error = nil
        store.navigate("Research"); store.create()
        let newID = store.selectedID!
        check(store.current!.isRich && store.current!.notebook == "Research", "new rich sheet is in notebook")
        store.update(newID) { $0.title = "My article"; $0.text = "One two three"; $0.wordGoal = 500 }
        store.saveVersion()
        store.update(newID) { $0.text = "Four five six seven" }
        let version = store.currentRevisions.first { $0.sheet.text == "One two three" }!
        store.restoreRevision(version)
        check(store.current!.text == "One two three" && store.current!.wordGoal == 500, "restore retains goal and writing")
        check(store.currentRevisions.contains { $0.sheet.text == "Four five six seven" }, "pre-restore writing retained")
        check(store.renameNotebook("Research", to: "Articles"), "rename notebook")
        check(store.current!.notebook == "Articles", "rename updates members")
        store.trash(newID); store.navigate("Trash")
        check(store.visible.contains { $0.id == newID }, "trash keeps sheet")
        store.removeNotebook("Articles"); check(store.sheets.first { $0.id == newID }!.notebook == "Drafts", "removal moves trashed members too")
        store.undoTrash(); check(store.current?.id == newID && !store.current!.trashed, "undo trash restores selection")
        store.navigate("Favorites"); check(store.visible.map(\.id) == [legacy.id], "favorites filter")
        store.navigate("All Writing"); store.query = "UNICODE"; check(store.visible.count == 1, "case-insensitive search")
        store.query = ""; store.duplicate(newID)
        check(store.current!.id != newID && store.current!.text == "One two three", "duplicate creates independent copy")
        let copyID = store.selectedID!
        store.update(copyID) { $0.text = "Autosaved change" }
        try await Task.sleep(for: .milliseconds(650))
        let reloaded = LibraryStore(directory: folder)
        check(reloaded.sheets.first { $0.id == copyID }?.text == "Autosaved change", "autosave survives reload")
        check(reloaded.selectedID == copyID && reloaded.current!.wordGoal == 500, "selection and goal survive reload")

        let visualFolder = folder.appendingPathComponent("VisualChecks")
        let visualStore = LibraryStore(directory: visualFolder)
        check(visualStore.addNotebook("Visual Ideas"), "visual notebook created")
        visualStore.create()
        let visualID = visualStore.selectedID!
        check(visualStore.current?.visualLayout == true, "visual sheet uses cover layout")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let coverURL = folder.appendingPathComponent("cover.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: coverURL)
        try visualStore.importCover(coverURL, for: visualID)
        visualStore.saveVersion()
        visualStore.setContent(visualID, text: "Words below my image", rtf: nil)
        visualStore.persist()
        let visualReload = LibraryStore(directory: visualFolder)
        check(visualReload.current?.coverImage != nil && visualReload.current?.text == "Words below my image", "cover and writing survive reload")
        let coverVersion = visualStore.currentRevisions.first { $0.sheet.coverImage != nil }!
        visualStore.removeCover(visualID)
        check(visualStore.current?.coverImage == nil, "cover can be removed")
        visualStore.restoreRevision(coverVersion)
        check(visualStore.current?.coverImage != nil, "version restoration recovers cover")
        visualStore.duplicate(visualID)
        check(visualStore.current?.coverImage == visualReload.current?.coverImage, "duplicate keeps cover")
        let visualBackup = try LibraryRepository.encode(visualStore.snapshot)
        let restoredVisual = try LibraryRepository.decode(visualBackup)
        check(restoredVisual.sheets.first { $0.id == visualID }?.coverImage != nil, "portable backup includes image")

        let bold = NSFontManager.shared.convert(DocumentIO.baseFont, toHaveTrait: .boldFontMask)
        let rich = NSMutableAttributedString(string: "Bold café\n", attributes: DocumentIO.attributes(font: bold))
        rich.append(NSAttributedString(string: "مرحبا world ✨", attributes: DocumentIO.attributes()))
        var richSheet = Sheet(title: "Rich Export", text: rich.string, editorMode: "rich")
        richSheet.richText = try DocumentIO.rtf(rich)
        check(DocumentIO.body(richSheet).string == rich.string, "RTF round-trip keeps Unicode")
        let richFont = DocumentIO.body(richSheet).attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        check(NSFontManager.shared.traits(of: richFont).contains(.boldFontMask), "RTF keeps bold")
        for format in DocumentIO.Format.allCases {
            let data = try DocumentIO.exportData(richSheet, format: format)
            let url = folder.appendingPathComponent("roundtrip." + format.ext)
            try data.write(to: url)
            check(!data.isEmpty, "\(format.rawValue) export writes data")
            if format == .docx {
                check(data.prefix(2) == Data("PK".utf8), "Word export is DOCX ZIP")
                let imported = try DocumentIO.importFile(url, notebook: "Drafts")
                check(imported.text.contains("Bold café") && imported.isRich, "Word import keeps text")
                let content = DocumentIO.body(imported)
                let range = (content.string as NSString).range(of: "Bold café")
                let font = content.attribute(.font, at: range.location, effectiveRange: nil) as! NSFont
                check(NSFontManager.shared.traits(of: font).contains(.boldFontMask), "Word keeps bold")
            }
            if format == .rtf { check(try DocumentIO.importFile(url, notebook: "Drafts").text.contains("مرحبا"), "RTF import keeps Arabic") }
            if format == .pdf { check(PDFDocument(data: data)?.pageCount == 1, "single-page PDF reads") }
        }
        let markdown = DocumentIO.markdown("## Heading\nA **bold** and _italic_ thought.\n[Link](https://example.com)")
        check(markdown.string == "Heading\nA bold and italic thought.\nLink", "Markdown renders heading, bold, italic, link")
        check(DocumentIO.toMarkdown(rich).contains("**Bold café**\n"), "rich to Markdown keeps bold inside its paragraph")
        check(DocumentIO.toMarkdown(markdown).hasPrefix("## Heading\n"), "heading level survives Markdown conversion")
        check(DocumentIO.toMarkdown(NSAttributedString(string: "An emoji ✨ 😀", attributes: DocumentIO.attributes())).hasSuffix("😀"), "Markdown conversion preserves surrogate pairs")
        let long = Sheet(title: "Long manuscript", text: String(repeating: "A full paragraph with a clear sentence and room to think.\n\n", count: 200) + "END-OF-MANUSCRIPT", editorMode: "rich")
        let pdf = PDFDocument(data: try DocumentIO.exportData(long, format: .pdf))!
        check(pdf.pageCount > 3 && pdf.string!.contains("END-OF-MANUSCRIPT"), "multipage PDF exports every paragraph")
        try Data("# Imported\n\nBody **bold**.".utf8).write(to: folder.appendingPathComponent("sample.md"))
        store.importURLs([folder.appendingPathComponent("sample.md"), folder.appendingPathComponent("missing.txt")])
        check(store.current?.title == "sample" && store.error != nil, "batch import retains successes and reports failures")
        store.error = nil; store.setMode(true)
        check(store.current!.isRich && store.current!.text.contains("Body bold."), "Markdown converts to rich text")
        store.setMode(false); check(!store.current!.isRich && store.current!.text.contains("**bold**"), "rich converts back to Markdown")
        var editedText = ""
        let editorSheet = Sheet(title: "Editor", text: "One two three", editorMode: "rich")
        let configuration = ManuscriptEditor(sheet: editorSheet, size: 19, typeface: "Serif", editable: true, onChange: { text, _ in editedText = text }, onError: { fatalError($0) })
        let coordinator = ManuscriptEditor.Coordinator(configuration)
        let editor = NSTextView(); editor.allowsUndo = true; editor.delegate = coordinator; coordinator.editor = editor
        coordinator.load(editorSheet, resetUndo: true)
        editor.setSelectedRange(NSRange(location: 0, length: 3))
        let undo = coordinator.undoManager(for: editor)!
        undo.beginUndoGrouping()
        coordinator.format(Notification(name: .folioFormat, object: "bold"))
        undo.endUndoGrouping()
        check(editedText == "One two three", "rich formatting preserves text")
        let formattedFont = editor.attributedString().attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        check(NSFontManager.shared.traits(of: formattedFont).contains(.boldFontMask), "editor bold applies a real font trait")
        undo.beginUndoGrouping()
        coordinator.format(Notification(name: .folioFormat, object: "list"))
        undo.endUndoGrouping()
        check(editor.string.hasPrefix("• One"), "rich bullet list inserts a bullet")
        let listedFont = editor.attributedString().attribute(.font, at: 2, effectiveRange: nil) as! NSFont
        check(NSFontManager.shared.traits(of: listedFont).contains(.boldFontMask), "bullet formatting preserves existing bold")
        undo.undo()
        check(editor.string == "One two three", "undo bullet list restores the original text")
        undo.undo()
        let undoneFont = editor.attributedString().attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        check(!NSFontManager.shared.traits(of: undoneFont).contains(.boldFontMask), "editor undo restores formatting")
        coordinator.load(editorSheet, resetUndo: true)
        check(editor.string == editorSheet.text, "editor reload does not crash undo registration")
        let archive = try LibraryRepository.encode(store.snapshot)
        let countBefore = store.sheets.count
        try store.mergeBackup(archive)
        check(store.sheets.count == countBefore * 2 && Set(store.sheets.map(\.id)).count == store.sheets.count, "backup recovery creates copies with unique IDs")
        check(store.sheets.contains { $0.title.contains("Recovered") }, "recovered conflicts are labeled")
        let trashID = store.selectedID!
        store.trash(trashID)
        let backupCount = try FileManager.default.contentsOfDirectory(at: store.backupsURL, includingPropertiesForKeys: nil).count
        store.emptyTrash()
        check(!store.sheets.contains { $0.id == trashID }, "empty trash removes only trashed sheets")
        check(try FileManager.default.contentsOfDirectory(at: store.backupsURL, includingPropertiesForKeys: nil).count > backupCount, "empty trash saves a recovery backup first")
        let competing = LibraryStore(directory: folder)
        store.update(store.selectedID!) { $0.title = "First writer wins" }; store.persist()
        competing.update(competing.selectedID!) { $0.title = "Unsaved second writer" }; competing.persist()
        check(competing.saveState == "Could not save" && competing.error != nil, "concurrent write conflict is surfaced")
        check(try repository.load()!.contains { $0.title == "First writer wins" }, "conflict does not overwrite disk")
        let corrupted = Data("broken library".utf8); try corrupted.write(to: repository.url)
        let blocked = LibraryStore(directory: folder); blocked.create(); blocked.persist()
        check(try !blocked.writable && Data(contentsOf: repository.url) == corrupted, "corrupt library is preserved")
        try blocked.mergeBackup(archive)
        check(blocked.writable && blocked.sheets.count == countBefore, "backup recovers blocked library")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let preserved = files.first { $0.lastPathComponent.hasPrefix("Preserved-") }!
        check(try Data(contentsOf: preserved) == corrupted, "recovery preserves damaged original")
        var future = store.snapshot; future.version = 999
        do { _ = try LibraryRepository.decode(LibraryRepository.encode(future)); fatalError("Accepted future library") }
        catch LibraryFailure.newerVersion { checks += 1 }
        try await syncChecks(in: folder)
        print("PASS: \(checks) checks covering migration, backups, recovery, notebooks, history, autosave, Unicode, RTF/DOCX/Markdown/PDF, pagination, partial imports, and write conflicts.")
    }
}
