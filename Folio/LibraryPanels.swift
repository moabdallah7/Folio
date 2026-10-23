import SwiftUI

struct NotebookManager: View {
    @Bindable var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var selected: String?
    @State private var rename = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your notebooks").font(.title2.bold())
            Text("Organize your writing into spaces of its own.").foregroundStyle(.secondary)
            HStack { TextField("New notebook name", text: $newName).onSubmit(add); Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.writable) }
            List(store.notebooks, id: \.self, selection: $selected) { name in HStack { Label(name, systemImage: "book"); Spacer(); Text("\(store.count(name)) sheets").foregroundStyle(.secondary) }.tag(name) }
                .onChange(of: selected) { _, value in rename = value ?? "" }
            if let selected, selected != "Drafts" {
                HStack {
                    TextField("Notebook name", text: $rename)
                    Button("Rename") { if store.renameNotebook(selected, to: rename) { self.selected = rename } }.disabled(!store.writable)
                    Button("Remove Notebook") { store.removeNotebook(selected); self.selected = nil }.disabled(!store.writable)
                }
                Text("Removing a notebook moves all its sheets to Drafts. No writing is deleted.").font(.caption).foregroundStyle(.secondary)
            } else { Text("Drafts is the default notebook and is always available.").font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 540, height: 450)
        .alert("Notebook", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }
    private func add() { if store.addNotebook(newName) { newName = "" } }
}

struct RevisionBrowser: View {
    @Bindable var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?
    private var chosen: Revision? { store.currentRevisions.first { $0.id == selected } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Version history").font(.title2.bold()); Spacer(); Button("Save Version", action: store.saveVersion).disabled(!store.writable) }
            Text("Folio keeps up to 50 versions per sheet. Restoring keeps a copy of your current writing.").font(.callout).foregroundStyle(.secondary)
            HSplitView {
                List(store.currentRevisions, selection: $selected) { revision in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(revision.date.formatted(date: .abbreviated, time: .shortened))
                        Text(revision.reason + " · \(revision.sheet.wordCount) words").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4).tag(revision.id)
                }.frame(minWidth: 240, idealWidth: 240)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(chosen?.sheet.displayTitle ?? "Select a version").font(.title3.bold())
                        Text(chosen?.sheet.text ?? "Versions are captured before edits, periodically as you write, and before format conversions or recovery.").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding()
                }.frame(minWidth: 320)
            }
            HStack { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Restore Selected Version") { if let chosen { store.restoreRevision(chosen) } }.disabled(chosen == nil || !store.writable) }
        }.padding(24).frame(width: 760, height: 530)
    }
}

struct GoalEditor: View {
    @Bindable var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var goal = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("A little progress, every day.").font(.title2.bold())
            Text("Set a word target for this sheet. Your progress appears below the editor.").foregroundStyle(.secondary)
            TextField("Word target", text: $goal).textFieldStyle(.roundedBorder)
            HStack {
                Button("Remove Goal") { if let id = store.selectedID { store.update(id) { $0.wordGoal = nil } }; dismiss() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { if let id = store.selectedID, let number = Int(goal), number > 0 { store.update(id) { $0.wordGoal = number } }; dismiss() }.keyboardShortcut(.defaultAction).disabled((Int(goal) ?? 0) <= 0 || (Int(goal) ?? 0) > 10_000_000 || !store.writable)
            }
        }.padding(28).frame(width: 450).onAppear { goal = store.current?.wordGoal.map(String.init) ?? "1000" }
    }
}

struct WritingSettings: View {
    @Bindable var store: LibraryStore
    @AppStorage("appearance") private var appearance = "System"
    @AppStorage("editorSize") private var size = 19.0
    @AppStorage("editorFont") private var font = "Serif"
    @State private var confirmReload = false
    var body: some View {
        Form {
            Section("Writing") {
                Picker("Appearance", selection: $appearance) { ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) } }
                Picker("Writing font", selection: $font) { ForEach(["Serif", "Sans", "Mono"], id: \.self) { Text($0) } }
                HStack { Text("Text size"); Slider(value: $size, in: 15...28, step: 1); Text("\(Int(size)) pt").monospacedDigit().frame(width: 45) }
            }
            Section("iCloud") {
                Label(store.cloud.status, systemImage: "icloud").font(.callout)
                if CloudSyncController.available {
                    Toggle("Sync this library", isOn: Binding(get: { store.syncState.enabled }, set: { store.cloud.setEnabled($0) }))
                        .disabled(!store.writable)
                    HStack {
                        Button("Sync Now") { store.cloud.syncNow() }.disabled(!store.syncState.enabled || store.cloud.busy)
                        if store.cloud.busy { ProgressView().controlSize(.small) }
                        if let date = store.syncState.lastSync { Text(date, style: .relative).font(.caption).foregroundStyle(.secondary); Text("ago").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("Syncs sheets, formatting, notebooks, favorites, goals, and Trash across your Macs using the same iCloud account. Folio checks while open. Backups and version history stay on each Mac.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("This build saves on your Mac. To activate iCloud, open the Folio iCloud scheme in Xcode and sign with an Apple Developer Program team. See iCloud Setup in the project.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Library & recovery") {
                LabeledContent("Storage", value: "On this Mac")
                HStack { Button("Export Backup…", action: store.exportBackup); Button("Import Backup…", action: store.importBackup) }
                HStack { Button("Show Library Folder", action: store.showLibraryFolder); Button("Reload Library…") { confirmReload = true } }
                Text("Folio keeps 20 recent library backups and up to 50 versions per sheet. Export a backup to keep a separate copy.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding().frame(width: 520, height: 610)
            .confirmationDialog("Reload the library from disk? Export a backup first if you have unsaved changes. Your current in-memory edits will be replaced.", isPresented: $confirmReload) {
                Button("Reload from Disk", role: .destructive) { store.reload() }
                Button("Export Backup First") { store.exportBackup() }
            }
    }
}
