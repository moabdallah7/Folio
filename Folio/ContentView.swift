import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var store: LibraryStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("editorSize") private var editorSize = 19.0
    @AppStorage("editorFont") private var editorFont = "Serif"
    @State private var focus = false
    @State private var typography = false
    @FocusState private var searchFocused: Bool
    @FocusState private var titleFocused: Bool
    private let accent = Color(red: 0.48, green: 0.40, blue: 0.28)
    private var paper: Color { scheme == .dark ? Color(red: 0.12, green: 0.12, blue: 0.115) : Color(red: 0.985, green: 0.98, blue: 0.963) }

    var body: some View {
        HSplitView {
            if !focus {
                sidebar.frame(minWidth: 175, idealWidth: 210, maxWidth: 240)
                sheetList.frame(minWidth: 225, idealWidth: 260, maxWidth: 310)
            }
            writingPane.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(paper)
        .tint(accent)
        .frame(minWidth: focus ? 660 : 960, minHeight: 620)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { toggleFocus() } label: { Image(systemName: focus ? "sidebar.left" : "sidebar.leading") }
                    .help(focus ? "Show Library" : "Focus Mode (⇧⌘F)")
                    .accessibilityLabel(focus ? "Show library" : "Enter focus mode")
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            ToolbarItem(placement: .principal) {
                Text(focus ? "Folio · Focus" : "Folio").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }.sharedBackgroundVisibility(.hidden)
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: store.create) { Image(systemName: "square.and.pencil") }.help("New Sheet (⌘N)").accessibilityLabel("New sheet")
                Button { typography.toggle() } label: { Image(systemName: "textformat") }
                    .help("Writing Appearance").accessibilityLabel("Writing appearance")
                    .popover(isPresented: $typography) { WritingSettings(store: store) }
                Menu {
                    ForEach(DocumentIO.Format.allCases) { format in Button(format.rawValue + "…") { store.export(format) } }
                } label: { Image(systemName: "square.and.arrow.up") }.help("Export Document").accessibilityLabel("Export document").disabled(store.current == nil)
                Menu {
                    Button("Import Documents…", action: store.importDocuments)
                    Button("Manage Notebooks…") { store.showNotebookManager = true }
                    Divider()
                    Button("Version History…") { store.showHistory = true }.disabled(store.current == nil)
                    Button("Writing Goal…") { store.showGoal = true }.disabled(store.current == nil)
                    Divider()
                    Button("Export Library Backup…", action: store.exportBackup)
                    Button("Import Library Backup…", action: store.importBackup)
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Library actions")
            }
        }
        .background {
            Button("") { if focus { toggleFocus() }; searchFocused = true }.keyboardShortcut("f", modifiers: [.command, .option]).hidden()
        }
        .alert("Folio needs your attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .onChange(of: store.selectedID) { _, _ in
            titleFocused = store.current?.title.isEmpty == true && store.current?.trashed == false
        }
        .confirmationDialog("Empty Trash? Removed sheets will leave the library. Folio saves a recovery backup first.", isPresented: $store.showEmptyTrashConfirmation, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive, action: store.emptyTrash)
        }
        .sheet(isPresented: $store.showNotebookManager) { NotebookManager(store: store) }
        .sheet(isPresented: $store.showHistory) { RevisionBrowser(store: store) }
        .sheet(isPresented: $store.showGoal) { GoalEditor(store: store) }
        .onChange(of: store.query) { _, _ in store.reconcileSelection() }
        .overlay(alignment: .top) {
            if let notice = store.notice {
                Text(notice).font(.callout).padding(12).glassEffect().padding(.top, 8)
                    .task(id: notice) { try? await Task.sleep(for: .seconds(3)); if store.notice == notice { store.notice = nil } }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in store.persist() }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "book.closed.fill").font(.system(size: 22, weight: .light)).foregroundStyle(accent)
                Text("folio").font(.system(size: 29, weight: .semibold, design: .serif)).tracking(-1.2)
            }.padding(.horizontal, 22).padding(.top, 28).padding(.bottom, 34)
            Text("LIBRARY").font(.system(size: 10, weight: .semibold)).tracking(1.8).foregroundStyle(.tertiary).padding(.horizontal, 24).padding(.bottom, 12)
            navRow("All Writing", icon: "tray.full")
            navRow("Favorites", icon: "star")
            HStack {
                Text("NOTEBOOKS").font(.system(size: 10, weight: .semibold)).tracking(1.8).foregroundStyle(.secondary)
                Spacer()
                Button { store.showNotebookManager = true } label: { Image(systemName: "plus") }.buttonStyle(.plain).accessibilityLabel("Manage notebooks")
            }.padding(.horizontal, 24).padding(.top, 32).padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 0) { ForEach(store.notebooks, id: \.self) { name in
                    navRow(name, icon: name == "Drafts" ? "doc.text" : name == "Ideas" ? "lightbulb" : name == "Visual Ideas" ? "photo.on.rectangle" : "book")
                } }
            }
            Spacer(minLength: 12)
            navRow("Trash", icon: "trash").contextMenu { Button("Empty Trash…", role: .destructive) { store.showEmptyTrashConfirmation = true }.disabled(store.count("Trash") == 0 || !store.writable) }
            Divider().padding(.horizontal, 22).padding(.vertical, 16)
            HStack(spacing: 7) { Image(systemName: store.syncState.enabled ? "icloud" : "internaldrive"); Text(store.syncState.enabled ? "iCloud" : "On this Mac") }.font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 24).padding(.bottom, 23).help(store.cloud.status)
        }
        .background(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.ultraThinMaterial))
    }
    private func navRow(_ name: String, icon: String) -> some View {
        Button { store.navigate(name) } label: {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 20).foregroundStyle(store.section == name ? accent : .secondary)
                Text(name).font(.system(size: 13, weight: store.section == name ? .medium : .regular))
                Spacer()
                Text("\(store.count(name))").font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
            }.padding(.horizontal, 12).padding(.vertical, 11)
                .background(store.section == name ? accent.opacity(scheme == .dark ? 0.22 : 0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 1)
            .accessibilityAddTraits(store.section == name ? .isSelected : [])
            .dropDestination(for: String.self) { identifiers, _ in
                guard store.notebooks.contains(name), store.writable else { return false }
                var moved = false
                for value in identifiers { if let id = UUID(uuidString: value), store.sheets.contains(where: { $0.id == id }) { store.update(id) { $0.notebook = name }; moved = true } }
                store.reconcileSelection(); return moved
            }
    }
    private var sheetList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(store.section).font(.system(size: 20, weight: .semibold, design: .serif)).lineLimit(2)
                Spacer()
                Menu { Picker("Sort by", selection: $store.sortOrder) { ForEach(["Modified", "Title", "Word Count"], id: \.self) { Text($0) } } } label: { Image(systemName: "arrow.up.arrow.down") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Sort documents")
            }.padding(.horizontal, 22).padding(.top, 32).padding(.bottom, 20)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search your writing", text: $store.query).textFieldStyle(.plain).focused($searchFocused)
                if !store.query.isEmpty { Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search") }
            }.font(.system(size: 12)).padding(10).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 16).padding(.bottom, 18)
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(store.visible) { sheet in
                        Button { store.selectedID = sheet.id } label: { sheetRow(sheet) }.buttonStyle(.plain)
                            .accessibilityLabel(sheet.displayTitle)
                            .accessibilityValue("\(sheet.notebook), \(sheet.wordCount) words")
                            .accessibilityAddTraits(store.selectedID == sheet.id ? .isSelected : [])
                            .draggable(sheet.id.uuidString)
                            .contextMenu {
                                Button("Duplicate Sheet") { store.duplicate(sheet.id) }
                                Button(sheet.favorite ? "Remove Favorite" : "Add to Favorites") { store.update(sheet.id) { $0.favorite.toggle() } }
                                Menu("Move to Notebook") { ForEach(store.notebooks, id: \.self) { notebook in Button(notebook) { store.update(sheet.id) { $0.notebook = notebook } } } }
                                Divider()
                                Button(sheet.trashed ? "Restore Sheet" : "Move to Trash") { store.trash(sheet.id) }
                            }
                    }
                    if store.visible.isEmpty {
                        VStack(spacing: 10) { Image(systemName: store.query.isEmpty ? "doc" : "magnifyingglass").font(.title2); Text(store.query.isEmpty ? "No sheets here yet" : "No matching sheets").font(.callout) }.foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }.padding(.horizontal, 10)
            }.focusable().onMoveCommand { direction in if direction == .down { store.selectNext(1) }; if direction == .up { store.selectNext(-1) } }
            HStack { Text("\(store.visible.count) sheets"); Spacer(); Button(action: store.create) { Image(systemName: "plus") }.buttonStyle(.plain).help("New Sheet").accessibilityLabel("New sheet") }.font(.system(size: 11)).foregroundStyle(.secondary).padding(20)
        }.background(scheme == .dark ? Color.white.opacity(0.015) : Color.white.opacity(0.38))
    }
    private func sheetRow(_ sheet: Sheet) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(sheet.displayTitle).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 0)
                if sheet.favorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(accent) }
            }
            Text(sheet.text.isEmpty ? "Your next beginning…" : sheet.text.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).lineSpacing(3)
            HStack(spacing: 6) { Text(sheet.notebook); Text("·"); Text("\(sheet.wordCount) words") }.font(.system(size: 10)).foregroundStyle(.tertiary)
        }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(store.selectedID == sheet.id ? accent.opacity(scheme == .dark ? 0.19 : 0.085) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(store.selectedID == sheet.id ? accent.opacity(0.12) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
    }
    private var writingPane: some View {
        VStack(spacing: 0) {
            if let sheet = store.current {
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 11))
                    Menu(sheet.notebook) { ForEach(store.notebooks, id: \.self) { notebook in Button(notebook) { store.update(sheet.id) { $0.notebook = notebook } } } }.menuStyle(.borderlessButton).fixedSize()
                    Spacer()
                    Menu(sheet.isRich ? "Rich Text" : "Markdown") {
                        Button("Rich Text") { store.setMode(true) }
                        Button("Markdown") { store.setMode(false) }
                    }.menuStyle(.borderlessButton).fixedSize().disabled(sheet.trashed || !store.writable)
                    Button { store.chooseCover(sheet.id) } label: { Image(systemName: "photo.badge.plus") }.buttonStyle(.plain).help("Add Cover Image").accessibilityLabel("Add cover image").disabled(sheet.trashed || !store.writable)
                    Button { store.showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }.buttonStyle(.plain).help("Version History").accessibilityLabel("Version history")
                    if sheet.trashed { Button("Restore") { store.trash(sheet.id) }.buttonStyle(.borderless) }
                    else { Button { store.update(sheet.id) { $0.favorite.toggle() } } label: { Image(systemName: sheet.favorite ? "star.fill" : "star") }.buttonStyle(.plain).foregroundStyle(sheet.favorite ? accent : .secondary).accessibilityLabel(sheet.favorite ? "Remove favorite" : "Add favorite") }
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 34).padding(.top, 27)
                GeometryReader { geometry in
                    let margin = max(32.0, (geometry.size.width - 820) / 2)
                    ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 20) {
                        if sheet.visualLayout == true || sheet.coverImage != nil { coverArea(sheet) }
                        Text(sheet.trashed ? "IN TRASH" : "\(sheet.notebook.uppercased())  /  \(sheet.modified.formatted(.dateTime.month(.wide).day()).uppercased())")
                            .font(.system(size: 9, weight: .medium)).tracking(2).foregroundStyle(.tertiary)
                        TextField("Untitled", text: Binding(get: { store.sheets.first { $0.id == sheet.id }?.title ?? "" }, set: { value in store.update(sheet.id) { $0.title = value } }), axis: .vertical)
                            .font(.system(size: 35, weight: .medium, design: .serif)).tracking(-0.8).textFieldStyle(.plain).fixedSize(horizontal: false, vertical: true).focused($titleFocused).disabled(sheet.trashed || !store.writable)
                        Rectangle().fill(accent.opacity(0.24)).frame(width: 38, height: 1).padding(.top, 1).padding(.bottom, 2)
                        if sheet.text.isEmpty && sheet.visualLayout == true { Text("Start with a thought, a story, or something you noticed…").font(.system(size: 16, design: .serif)).foregroundStyle(.tertiary).allowsHitTesting(false) }
                        ManuscriptEditor(sheet: sheet, size: editorSize, typeface: editorFont, editable: !sheet.trashed && store.writable, onChange: { text, data in store.setContent(sheet.id, text: text, rtf: data) }, onError: { store.error = $0 })
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, margin).padding(.top, 36).padding(.bottom, 60)
                        .frame(minHeight: geometry.size.height, alignment: .top)
                    }.defaultScrollAnchor(.top)
                        .id(sheet.id)
                }
                footer(sheet)
            } else {
                Spacer()
                Image(systemName: "leaf").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(accent).padding(.bottom, 12)
                Text("Room for a new thought.").font(.system(size: 28, design: .serif))
                Text("Choose a sheet, or begin something new.").foregroundStyle(.secondary).padding(.top, 3)
                Button("New Sheet", action: store.create).buttonStyle(.glass).padding(.top, 20)
                Spacer()
            }
        }.background(paper)
    }
    @ViewBuilder private func coverArea(_ sheet: Sheet) -> some View {
        if let data = sheet.coverImage, let image = NSImage(data: data) {
            VStack(alignment: .leading, spacing: 10) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Cover image")
                if !sheet.trashed && store.writable {
                    HStack(spacing: 16) {
                        Button("Change image…") { store.chooseCover(sheet.id) }
                        Button("Remove image") { store.removeCover(sheet.id) }
                    }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(.bottom, 12)
        } else if !sheet.trashed {
            Button { store.chooseCover(sheet.id) } label: {
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.plus").font(.system(size: 30, weight: .ultraLight))
                    Text("Add a cover image").font(.system(size: 18, design: .serif))
                    Text("A little inspiration. Your words below.").font(.system(size: 12)).foregroundStyle(.tertiary)
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 210)
                    .background(accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(accent.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
            }.buttonStyle(.plain).disabled(!store.writable).padding(.bottom, 12)
        }
    }
    private func footer(_ sheet: Sheet) -> some View {
        HStack {
            HStack(spacing: 6) { Circle().fill(store.saveState == "Saved on this Mac" ? Color.green.opacity(0.6) : Color.orange).frame(width: 4, height: 4); Text(store.saveState == "Saved on this Mac" ? "Saved" : store.saveState).lineLimit(1) }.font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer(minLength: 12)
            GlassEffectContainer {
                HStack(spacing: 2) {
                    formatButton("bold", marker: "bold", help: "Bold (⌘B)")
                    formatButton("italic", marker: "italic", help: "Italic (⌘I)")
                    formatButton("textformat.size", marker: "heading", help: "Heading")
                    formatButton("list.bullet", marker: "list", help: "Bullet List")
                    formatButton("link", marker: "link", help: "Add Link")
                    Divider().frame(height: 14).padding(.horizontal, 5)
                    Button { toggleFocus() } label: { Image(systemName: focus ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").frame(width: 28, height: 28) }.help("Toggle Focus Mode").accessibilityLabel("Toggle focus mode")
                }.buttonStyle(.plain).font(.system(size: 12)).padding(5).glassEffect(.regular, in: .capsule)
            }
            Spacer(minLength: 12)
            Button { store.showGoal = true } label: {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(sheet.wordGoal.map { "\(sheet.wordCount) / \($0) words" } ?? "\(sheet.wordCount) words · \(max(1, Int(ceil(Double(sheet.wordCount) / 200)))) min")
                    if let goal = sheet.wordGoal, goal > 0 { ProgressView(value: min(1, Double(sheet.wordCount) / Double(goal))).frame(width: 90) }
                }.font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }.buttonStyle(.plain).help("Writing Goal").accessibilityLabel("Writing goal, \(sheet.wordCount) words")
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }
    private func formatButton(_ symbol: String, marker: String, help: String) -> some View {
        Button { NotificationCenter.default.post(name: .folioFormat, object: marker) } label: { Image(systemName: symbol).frame(width: 28, height: 28) }.help(help).accessibilityLabel(help).disabled(store.current?.trashed == true || !store.writable)
    }
    private func toggleFocus() { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { focus.toggle() } }
}
