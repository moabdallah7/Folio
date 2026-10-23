import SwiftUI
import AppKit
import PDFKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingFiles: [URL] = []
    var store: LibraryStore? {
        didSet { if let store, !pendingFiles.isEmpty { store.importURLs(pendingFiles); pendingFiles = [] } }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store?.persist()
        if store?.saveState == "Could not save" {
            let alert = NSAlert(); alert.messageText = "Your latest changes couldn’t be saved."
            alert.informativeText = "Keep Folio open to export a library backup or try saving again."
            alert.addButton(withTitle: "Keep Open"); alert.addButton(withTitle: "Quit Anyway")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
        }
        return .terminateNow
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if let store { store.importURLs(urls) } else { pendingFiles.append(contentsOf: urls) }
        sender.reply(toOpenOrPrint: .success)
    }
}

@main struct FolioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = LibraryStore()
    @AppStorage("appearance") private var appearance = "System"
    var body: some Scene {
        Window("Folio", id: "main") {
            ContentView(store: store)
                .preferredColorScheme(appearance == "System" ? nil : appearance == "Dark" ? .dark : .light)
                .onAppear { delegate.store = store; store.cloud.start(store) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.cloud.syncNow() }
        }
        .defaultSize(width: 1240, height: 820).windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Sheet", action: store.create).keyboardShortcut("n").disabled(!store.writable)
                Button("New Notebook…") { store.showNotebookManager = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Import Documents…", action: store.importDocuments).keyboardShortcut("o").disabled(!store.writable)
                Divider()
                Button("Save Now", action: store.persist).keyboardShortcut("s")
                Button("Save Version", action: store.saveVersion).keyboardShortcut("s", modifiers: [.command, .shift])
                Menu("Export") { ForEach(DocumentIO.Format.allCases) { format in Button(format.rawValue + "…") { store.export(format) } } }.disabled(store.current == nil)
                Button("Export PDF…") { store.export(.pdf) }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(store.current == nil)
                Button("Print…", action: printCurrent).keyboardShortcut("p").disabled(store.current == nil)
            }
            CommandGroup(after: .textEditing) {
                Divider()
                Button("Find in Sheet…") { NotificationCenter.default.post(name: .folioFind, object: false) }.keyboardShortcut("f")
                Button("Find and Replace…") { NotificationCenter.default.post(name: .folioFind, object: true) }.keyboardShortcut("f", modifiers: [.command, .shift, .option])
            }
            CommandMenu("Format") {
                Button("Bold") { format("bold") }.keyboardShortcut("b")
                Button("Italic") { format("italic") }.keyboardShortcut("i")
                Button("Heading") { format("heading") }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Bullet List") { format("list") }
                Button("Add Link…") { format("link") }.keyboardShortcut("k")
            }
            CommandMenu("Sheet") {
                Button("Duplicate Sheet") { if let id = store.selectedID { store.duplicate(id) } }.disabled(store.current == nil || !store.writable)
                Button(store.current?.trashed == true ? "Restore Sheet" : "Move to Trash") { if let id = store.selectedID { store.trash(id) } }.disabled(store.current == nil || !store.writable)
                Button("Undo Move to Trash", action: store.undoTrash)
                Button("Empty Trash…") { store.showEmptyTrashConfirmation = true }.disabled(store.count("Trash") == 0 || !store.writable)
                Divider()
                Button("Version History…") { store.showHistory = true }.disabled(store.current == nil)
                Button("Writing Goal…") { store.showGoal = true }.disabled(store.current == nil)
            }
        }
        Settings { WritingSettings(store: store) }
    }
    private func format(_ value: String) { NotificationCenter.default.post(name: .folioFormat, object: value) }
    private func printCurrent() {
        guard let sheet = store.current else { return }
        do {
            let data = try DocumentIO.exportData(sheet, format: .pdf)
            PDFDocument(data: data)?.printOperation(for: .shared, scalingMode: .pageScaleToFit, autoRotate: true)?.run()
        } catch { store.error = error.localizedDescription }
    }
}
