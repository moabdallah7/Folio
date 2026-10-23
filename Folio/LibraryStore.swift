import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO

@MainActor @Observable
final class LibraryStore {
    var sheets: [Sheet] = []
    var syncState = SyncState()
    let cloud = CloudSyncController()
    var notebooks = ["Drafts", "Journal", "Ideas"]
    var revisions: [Revision] = []
    var selectedID: UUID?
    var section = "All Writing"
    var query = ""
    var error: String?
    var notice: String?
    var saveState = "Saved on this Mac"
    var writable = true
    var sortOrder = "Modified"
    var showNotebookManager = false
    var showHistory = false
    var showGoal = false
    var showEmptyTrashConfirmation = false
    private var pendingSave: Task<Void, Never>?
    private var checkpointDates: [UUID: Date] = [:]
    private var repository: LibraryRepository
    private var lastTrashed: UUID?
    var libraryURL: URL { repository.url }
    var backupsURL: URL { repository.backupsURL }
    var current: Sheet? { sheets.first { $0.id == selectedID } }
    var currentRevisions: [Revision] { revisions.filter { $0.sheet.id == selectedID }.sorted { $0.date > $1.date } }
    var snapshot: LibraryFile { LibraryFile(sheets: sheets, notebooks: notebooks, revisions: revisions, selectedID: selectedID, section: section, sync: syncState) }

    init(directory: URL? = nil) {
        let testPath = UserDefaults.standard.string(forKey: "FolioLibraryPath")
        let base = directory ?? testPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Folio", isDirectory: true)
        repository = LibraryRepository(url: base.appendingPathComponent("library.json"))
        do {
            if let library = try repository.loadFile() { apply(library) }
            else { sheets = Self.examples; selectedID = sheets.first?.id; persist() }
        } catch {
            writable = false
            self.error = "Your library could not be opened. The original file is preserved. You can import a library backup from Settings to recover. \(error.localizedDescription)"
        }
    }
    private func apply(_ library: LibraryFile) {
        sheets = library.sheets
        syncState = library.sync ?? SyncState()
        notebooks = library.notebooks ?? ["Drafts", "Journal", "Ideas"]
        for name in sheets.map(\.notebook) where !notebooks.contains(name) { notebooks.append(name) }
        if !notebooks.contains("Drafts") { notebooks.insert("Drafts", at: 0) }
        revisions = library.revisions ?? []
        section = library.section ?? "All Writing"
        if !["All Writing", "Favorites", "Trash"].contains(section) && !notebooks.contains(section) { section = "All Writing" }
        selectedID = library.selectedID
        reconcileSelection()
    }
    var visible: [Sheet] {
        sheets.filter { sheet in
            let matches: Bool
            switch section {
            case "Trash": matches = sheet.trashed
            case "Favorites": matches = !sheet.trashed && sheet.favorite
            case "All Writing": matches = !sheet.trashed
            default: matches = !sheet.trashed && sheet.notebook == section
            }
            return matches && (query.isEmpty || sheet.title.localizedCaseInsensitiveContains(query) || sheet.text.localizedCaseInsensitiveContains(query))
        }.sorted {
            if sortOrder == "Title" { return $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
            if sortOrder == "Word Count" { return $0.wordCount == $1.wordCount ? $0.modified > $1.modified : $0.wordCount > $1.wordCount }
            return $0.modified > $1.modified
        }
    }
    func count(_ section: String) -> Int {
        sheets.filter { s in
            if section == "Trash" { return s.trashed }
            if section == "Favorites" { return !s.trashed && s.favorite }
            return !s.trashed && (section == "All Writing" || s.notebook == section)
        }.count
    }
    func reconcileSelection() {
        if !visible.contains(where: { $0.id == selectedID }) { selectedID = visible.first?.id }
    }
    func navigate(_ destination: String) { section = destination; reconcileSelection() }
    func selectNext(_ direction: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == selectedID } ?? 0
        selectedID = list[max(0, min(list.count - 1, index + direction))].id
    }
    func create() {
        guard writable else { return }
        query = ""
        let notebook = notebooks.contains(section) ? section : "Drafts"
        if section == "Trash" || section == "Favorites" { section = "All Writing" }
        let visual = notebook == "Visual Ideas" || sheets.contains { $0.notebook == notebook && $0.visualLayout == true }
        let sheet = Sheet(title: "", text: "", notebook: notebook, editorMode: "rich", visualLayout: visual ? true : nil)
        sheets.insert(sheet, at: 0); selectedID = sheet.id; changed()
    }
    func duplicate(_ id: UUID) {
        guard writable, var copy = sheets.first(where: { $0.id == id }) else { return }
        copy.id = UUID(); copy.title = copy.displayTitle + " copy"; copy.modified = Date(); copy.trashed = false
        sheets.insert(copy, at: 0); query = ""; section = copy.notebook; selectedID = copy.id; changed()
    }
    func checkpoint(_ sheet: Sheet, reason: String, force: Bool = false) {
        guard force || Date().timeIntervalSince(checkpointDates[sheet.id] ?? .distantPast) >= 300 else { return }
        if let latest = revisions.last(where: { $0.sheet.id == sheet.id }), latest.sheet.title == sheet.title, latest.sheet.text == sheet.text, latest.sheet.richText == sheet.richText, latest.sheet.coverImage == sheet.coverImage { return }
        revisions.append(Revision(sheet: sheet, reason: reason)); checkpointDates[sheet.id] = Date()
        let excess = revisions.filter { $0.sheet.id == sheet.id }.count - 50
        if excess > 0 {
            let ids = Set(revisions.filter { $0.sheet.id == sheet.id }.prefix(excess).map(\.id))
            revisions.removeAll { ids.contains($0.id) }
        }
    }
    func update(_ id: UUID, _ edit: (inout Sheet) -> Void) {
        guard writable, let index = sheets.firstIndex(where: { $0.id == id }) else { return }
        var edited = sheets[index]; edit(&edited)
        guard edited != sheets[index] else { return }
        if edited.text != sheets[index].text || edited.title != sheets[index].title || edited.richText != sheets[index].richText || edited.coverImage != sheets[index].coverImage { checkpoint(sheets[index], reason: "Before editing") }
        edited.modified = Date(); sheets[index] = edited; changed()
    }
    func chooseCover(_ id: UUID) {
        guard writable, let sheet = sheets.first(where: { $0.id == id }), !sheet.trashed else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Cover Image"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try importCover(url, for: id) }
        catch { self.error = error.localizedDescription }
    }
    func importCover(_ url: URL, for id: UUID) throws {
        guard writable, let sheet = sheets.first(where: { $0.id == id }), !sheet.trashed else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // Decode a thumbnail instead of retaining a full-resolution camera image.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1800,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw LibraryFailure.invalid("Choose a readable photo or image file.") }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw LibraryFailure.invalid("This image could not be saved.") }
        checkpoint(sheet, reason: "Before changing cover", force: true)
        update(id) { $0.coverImage = data; $0.visualLayout = true }
    }
    func removeCover(_ id: UUID) {
        guard let sheet = sheets.first(where: { $0.id == id }), writable, !sheet.trashed else { return }
        checkpoint(sheet, reason: "Before removing cover", force: true)
        update(id) { $0.coverImage = nil }
    }
    func setContent(_ id: UUID, text: String, rtf: Data?) { update(id) { $0.text = text; $0.richText = rtf } }
    func setMode(_ rich: Bool) {
        guard let sheet = current, !sheet.trashed, sheet.isRich != rich else { return }
        checkpoint(sheet, reason: "Before format conversion", force: true)
        do {
            if rich {
                let value = DocumentIO.markdown(sheet.text)
                let data = try DocumentIO.rtf(value)
                update(sheet.id) { $0.editorMode = "rich"; $0.text = value.string; $0.richText = data }
            } else {
                let text = DocumentIO.toMarkdown(DocumentIO.body(sheet))
                update(sheet.id) { $0.editorMode = "markdown"; $0.text = text; $0.richText = nil }
            }
        } catch { self.error = error.localizedDescription }
    }
    func saveVersion() {
        guard let sheet = current, writable else { return }
        checkpoint(sheet, reason: "Saved version", force: true); persist()
    }
    func restoreRevision(_ revision: Revision) {
        guard let index = sheets.firstIndex(where: { $0.id == revision.sheet.id }), writable else { return }
        checkpoint(sheets[index], reason: "Before restoring a version", force: true)
        // Keep organization and goal settings; restore writing and formatting only.
        update(revision.sheet.id) { $0.title = revision.sheet.title; $0.text = revision.sheet.text; $0.richText = revision.sheet.richText; $0.editorMode = revision.sheet.editorMode; $0.coverImage = revision.sheet.coverImage; $0.visualLayout = revision.sheet.visualLayout }
        persist(); showHistory = false
    }
    func trash(_ id: UUID) {
        guard writable, let sheet = sheets.first(where: { $0.id == id }) else { return }
        checkpoint(sheet, reason: "Before moving to trash", force: true)
        update(id) { $0.trashed.toggle() }; lastTrashed = sheet.trashed ? nil : id; reconcileSelection()
    }
    func undoTrash() { if let id = lastTrashed { update(id) { $0.trashed = false }; section = "All Writing"; query = ""; selectedID = id; lastTrashed = nil } }
    func emptyTrash() {
        guard writable else { return }
        do {
            try repository.archive(snapshot)
            let deleted = Set(sheets.filter(\.trashed).map(\.id))
            sheets.removeAll { deleted.contains($0.id) }
            revisions.removeAll { deleted.contains($0.sheet.id) }
            reconcileSelection(); persist()
            if saveState == "Saved on this Mac" { notice = "Trash emptied. A recovery backup was saved." }
        } catch { self.error = error.localizedDescription }
    }
    func addNotebook(_ input: String) -> Bool {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard writable else { return false }
        guard !name.isEmpty, name.count <= 60 else { error = "Use a notebook name between 1 and 60 characters."; return false }
        guard !(["All Writing", "Favorites", "Trash"] + notebooks).contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { error = "That notebook name is already in use."; return false }
        notebooks.append(name); navigate(name); changed(); return true
    }
    func renameNotebook(_ original: String, to input: String) -> Bool {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard writable, original != "Drafts", let index = notebooks.firstIndex(of: original) else { return false }
        if original == name { return true }
        guard !name.isEmpty, name.count <= 60, !(["All Writing", "Favorites", "Trash"] + notebooks).contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { error = "Choose a unique name between 1 and 60 characters."; return false }
        notebooks[index] = name
        for i in sheets.indices where sheets[i].notebook == original { sheets[i].notebook = name }
        if section == original { section = name }; changed(); return true
    }
    func removeNotebook(_ name: String) {
        guard writable, name != "Drafts" else { return }
        for index in sheets.indices where sheets[index].notebook == name { sheets[index].notebook = "Drafts" }
        notebooks.removeAll { $0 == name }; if section == name { navigate("Drafts") }; changed()
    }
    func changed() {
        saveState = "Saving…"; cloud.localChanges(); pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.persist()
        }
    }
    func persist() {
        guard writable else { return }
        pendingSave?.cancel()
        do { try repository.saveFile(snapshot); saveState = "Saved on this Mac"; cloud.localChanges() }
        catch { saveState = "Could not save"; self.error = error.localizedDescription }
    }
    func reload() {
        cloud.libraryWillReload()
        pendingSave?.cancel()
        do {
            guard let file = try repository.loadFile() else { throw LibraryFailure.invalid("The library file is missing. Import a backup to recover.") }
            apply(file); writable = true; saveState = "Saved on this Mac"; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func importDocuments() {
        guard writable else { return }
        let panel = NSOpenPanel(); panel.title = "Import Writing"; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ["txt", "md", "markdown", "rtf", "docx"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }
    func importURLs(_ urls: [URL]) {
        guard writable else { return }
        var failures: [String] = []; var imported: [Sheet] = []
        let notebook = notebooks.contains(section) ? section : "Drafts"
        for url in urls {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            do { imported.append(try DocumentIO.importFile(url, notebook: notebook)) }
            catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if !imported.isEmpty { sheets.insert(contentsOf: imported, at: 0); section = notebook; query = ""; selectedID = imported.first?.id; changed() }
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
    }
    func export(_ format: DocumentIO.Format = .markdown) {
        guard let sheet = current else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [format.type]; panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = sheet.displayTitle.replacingOccurrences(of: "/", with: "-") + "." + format.ext
        panel.title = "Export \(format.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try DocumentIO.exportData(sheet, format: format).write(to: url, options: .atomic); notice = "Exported \(url.lastPathComponent)" }
        catch { self.error = error.localizedDescription }
    }
    func exportBackup() {
        let panel = NSSavePanel(); panel.title = "Export Library Backup"; panel.nameFieldStringValue = "Folio-\(Date().formatted(.iso8601.year().month().day())).folio"
        panel.allowedContentTypes = [.data]; panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try LibraryRepository.encode(snapshot).write(to: url, options: .atomic); notice = "Library backup exported" }
        catch { self.error = error.localizedDescription }
    }
    func importBackup() {
        let panel = NSOpenPanel(); panel.title = "Import Library Backup"; panel.message = "Sheets are added as recovered copies. Your current writing is kept."
        panel.allowedContentTypes = [.data, .json]; panel.directoryURL = backupsURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try mergeBackup(Data(contentsOf: url)); notice = "Recovered writing added to your library" }
        catch { self.error = error.localizedDescription }
    }
    func mergeBackup(_ data: Data) throws {
        let backup = try LibraryRepository.decode(data)
        if !writable {
            let preserved = repository.url.deletingLastPathComponent().appendingPathComponent("Preserved-\(UUID().uuidString).json")
            if FileManager.default.fileExists(atPath: repository.url.path) { try FileManager.default.moveItem(at: repository.url, to: preserved) }
            repository = LibraryRepository(url: repository.url); writable = true
        }
        var mapping: [UUID: UUID] = [:]
        var imported: [Sheet] = []
        for var sheet in backup.sheets {
            let original = sheet.id
            if sheets.contains(where: { $0.id == sheet.id }) { sheet.id = UUID(); sheet.title = sheet.displayTitle + " (Recovered)" }
            mapping[original] = sheet.id; imported.append(sheet)
            if !notebooks.contains(sheet.notebook) { notebooks.append(sheet.notebook) }
        }
        for var revision in backup.revisions ?? [] {
            guard let id = mapping[revision.sheet.id] else { continue }
            revision.id = UUID(); revision.sheet.id = id; revisions.append(revision)
        }
        for name in backup.notebooks ?? [] where !notebooks.contains(name) { notebooks.append(name) }
        sheets.append(contentsOf: imported); section = "All Writing"; query = ""; selectedID = imported.first(where: { !$0.trashed })?.id; persist()
    }
    func showLibraryFolder() { NSWorkspace.shared.activateFileViewerSelecting([repository.url]) }
    static var examples: [Sheet] {
        [Sheet(title: "A little room to think", text: "There is something about a blank page.\n\nNot the pressure to fill it, but the possibility of what might arrive. A thought you didn’t know you had. A sentence that leads somewhere unexpected.\n\nFolio is a quiet place for that possibility. A home for your first drafts, passing thoughts, and the stories you keep coming back to.\n\nStart with a sentence\n\nIt doesn’t need to be the right one. Write a little, follow your curiosity, and let the shape of the piece reveal itself. You can make it beautiful later.\n\nKeep your world close\n\nCollect ideas in your library. Give a favorite piece a star. When you need a little more room, enter Focus mode and let everything else fall away.\n\nYour words are saved automatically on this Mac. When you’re ready, export a Markdown copy and take them anywhere.\n\nFor now, just begin.", notebook: "Drafts", favorite: true),
         Sheet(title: "The art of noticing", text: "The light moved across the kitchen table, slowly enough that I almost missed it.\n\nAn ordinary morning. A small reminder to pay attention.\n\nWhat did I notice today?", notebook: "Journal"),
         Sheet(title: "Things worth exploring", text: "A collection of beginnings.\n\n• A story told through the objects someone leaves behind\n• The places we return to in our minds\n• An essay about taking the long way home", notebook: "Ideas")]
    }
}
