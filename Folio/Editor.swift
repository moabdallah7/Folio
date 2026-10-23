import SwiftUI
import AppKit

extension Notification.Name {
    static let folioFormat = Notification.Name("folio.format")
    static let folioFind = Notification.Name("folio.find")
}

struct ManuscriptEditor: NSViewRepresentable {
    var sheet: Sheet
    var size: Double
    var typeface: String
    var editable: Bool
    var onChange: (String, Data?) -> Void
    var onError: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextView {
        let editor = NSTextView(frame: .zero)
        editor.isAutomaticQuoteSubstitutionEnabled = true
        editor.isAutomaticDashSubstitutionEnabled = true
        editor.isContinuousSpellCheckingEnabled = true; editor.isGrammarCheckingEnabled = true
        editor.allowsUndo = true; editor.drawsBackground = false; editor.importsGraphics = false
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.lineFragmentPadding = 0; editor.textContainerInset = NSSize(width: 0, height: 8)
        editor.delegate = context.coordinator; editor.usesFindBar = true
        editor.setAccessibilityLabel("Writing editor")
        context.coordinator.editor = editor
        context.coordinator.load(sheet, resetUndo: true)
        context.coordinator.applyAppearance()
        return editor
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView editor: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0,
              let container = editor.textContainer, let layout = editor.layoutManager else { return nil }
        // The document owns scrolling; the text view grows to fit every laid-out line.
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let bottom = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        return CGSize(width: width, height: max(160, ceil(bottom + editor.textContainerInset.height * 2)))
    }
    func updateNSView(_ editor: NSTextView, context: Context) {
        let coordinator = context.coordinator
        let oldID = coordinator.parent.sheet.id
        let oldMode = coordinator.parent.sheet.isRich
        let appearanceChanged = coordinator.parent.size != size || coordinator.parent.typeface != typeface
        if oldID != sheet.id, let editor = coordinator.editor { coordinator.positions[oldID] = editor.selectedRange() }
        coordinator.parent = self
        if oldID != sheet.id { coordinator.load(sheet, resetUndo: false) }
        else if coordinator.lastText != sheet.text || coordinator.lastRTF != sheet.richText || oldMode != sheet.isRich { coordinator.load(sheet, resetUndo: true) }
        if appearanceChanged { coordinator.applyAppearance(retheme: true) }
        coordinator.editor?.isEditable = editable
        coordinator.editor?.textColor = .labelColor
        coordinator.editor?.insertionPointColor = .labelColor
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ManuscriptEditor
        weak var editor: NSTextView?
        var positions: [UUID: NSRange] = [:]
        var undoManagers: [UUID: UndoManager] = [:]
        var lastText = ""
        var lastRTF: Data?
        private var applying = false
        private var previousSize = 19.0
        init(_ parent: ManuscriptEditor) {
            self.parent = parent; self.previousSize = parent.size; super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(format(_:)), name: .folioFormat, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(find(_:)), name: .folioFind, object: nil)
        }
        deinit { NotificationCenter.default.removeObserver(self) }
        func undoManager(for view: NSTextView) -> UndoManager? {
            if let manager = undoManagers[parent.sheet.id] { return manager }
            let manager = UndoManager(); manager.levelsOfUndo = 100; undoManagers[parent.sheet.id] = manager; return manager
        }
        func load(_ sheet: Sheet, resetUndo: Bool) {
            guard let editor else { return }
            applying = true; defer { applying = false }
            let manager = undoManager(for: editor)
            if editor.isRichText != sheet.isRich { editor.isRichText = sheet.isRich }
            if sheet.isRich { editor.textStorage?.setAttributedString(DocumentIO.body(sheet)) }
            else { editor.textStorage?.setAttributedString(NSAttributedString(string: sheet.text, attributes: DocumentIO.attributes(font: font()))) }
            lastText = sheet.text; lastRTF = sheet.richText
            applyAppearance()
            if resetUndo { manager?.removeAllActions() }
            let position = positions[sheet.id] ?? NSRange(location: 0, length: 0)
            let location = min(position.location, (sheet.text as NSString).length)
            editor.setSelectedRange(NSRange(location: location, length: min(position.length, (sheet.text as NSString).length - location)))
            if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
            editor.scrollRangeToVisible(editor.selectedRange())
        }
        func font() -> NSFont {
            switch parent.typeface {
            case "Mono": return .monospacedSystemFont(ofSize: parent.size, weight: .regular)
            case "Sans": return .systemFont(ofSize: parent.size)
            default: return NSFont(name: "NewYork-Regular", size: parent.size) ?? NSFont(name: "Georgia", size: parent.size) ?? .systemFont(ofSize: parent.size)
            }
        }
        func applyAppearance(retheme: Bool = false) {
            guard let editor else { return }
            let font = font()
            if !parent.sheet.isRich { editor.font = font }
            else if retheme, let storage = editor.textStorage {
                let full = NSRange(location: 0, length: storage.length)
                storage.enumerateAttribute(.font, in: full) { value, range, _ in
                    let previous = value as? NSFont ?? font
                    let scale = previous.pointSize / max(1, previousSize)
                    let resized = NSFontManager.shared.convert(font, toSize: min(72, max(10, parent.size * scale)))
                    storage.addAttribute(.font, value: NSFontManager.shared.convert(resized, toHaveTrait: NSFontManager.shared.traits(of: previous)), range: range)
                }
            }
            previousSize = parent.size
            editor.defaultParagraphStyle = DocumentIO.attributes(font: font)[.paragraphStyle] as? NSParagraphStyle
            editor.typingAttributes = DocumentIO.attributes(font: font)
            editor.textColor = .labelColor; editor.insertionPointColor = .labelColor; editor.isEditable = parent.editable
        }
        func textDidChange(_ notification: Notification) { publish() }
        func publish() {
            guard !applying, let editor, !editor.hasMarkedText() else { return }
            do {
                let data = parent.sheet.isRich ? try DocumentIO.rtf(editor.attributedString()) : nil
                lastText = editor.string; lastRTF = data
                parent.onChange(editor.string, data)
            } catch { parent.onError("Formatting could not be saved: \(error.localizedDescription)") }
        }
        private func replaceDocument(_ value: NSAttributedString, selection: NSRange, action: String) {
            guard let editor else { return }
            let before = NSAttributedString(attributedString: editor.attributedString()); let oldSelection = editor.selectedRange()
            undoManager(for: editor)?.registerUndo(withTarget: self) { target in target.replaceDocument(before, selection: oldSelection, action: action) }
            undoManager(for: editor)?.setActionName(action)
            applying = true
            editor.textStorage?.setAttributedString(value); editor.setSelectedRange(selection)
            applying = false; publish()
        }
        @objc func find(_ notification: Notification) {
            guard let editor else { return }
            editor.window?.makeFirstResponder(editor)
            let item = NSMenuItem(); item.tag = (notification.object as? Bool == true ? NSTextFinder.Action.showReplaceInterface : .showFindInterface).rawValue
            editor.performFindPanelAction(item)
        }
        @objc func format(_ notification: Notification) {
            guard let editor, parent.editable, let command = notification.object as? String else { return }
            editor.window?.makeFirstResponder(editor)
            var range = editor.selectedRange()
            if !parent.sheet.isRich {
                let source = editor.string as NSString
                if command == "heading" || command == "list" {
                    let lines = source.paragraphRange(for: range)
                    let selected = source.substring(with: lines)
                    let marker = command == "heading" ? "## " : "- "
                    let replacement = selected.components(separatedBy: "\n").enumerated().map { i, line in line.isEmpty && i > 0 ? line : marker + line }.joined(separator: "\n")
                    editor.insertText(replacement, replacementRange: lines)
                } else if command == "link" {
                    if let url = requestLink() { let selected = source.substring(with: range); editor.insertText("[\(selected.isEmpty ? "link" : selected)](\(url))", replacementRange: range) }
                } else {
                    let marker = command == "bold" ? "**" : command == "italic" ? "_" : "~~"
                    let selected = source.substring(with: range)
                    editor.insertText(marker + selected + marker, replacementRange: range)
                    editor.setSelectedRange(NSRange(location: range.location + marker.count, length: range.length))
                }
                return
            }
            if command == "list" {
                let source = editor.string as NSString
                let paragraph = source.paragraphRange(for: range)
                let copy = NSMutableAttributedString(attributedString: editor.attributedString())
                var positions: [Int] = []
                var index = paragraph.location
                repeat {
                    positions.append(index)
                    let next = NSMaxRange(source.paragraphRange(for: NSRange(location: index, length: 0)))
                    if next <= index { break }; index = next
                } while index < NSMaxRange(paragraph)
                var delta = 0
                for position in positions.reversed() {
                    if position + 2 <= source.length && source.substring(with: NSRange(location: position, length: 2)) == "• " {
                        copy.deleteCharacters(in: NSRange(location: position, length: 2)); delta -= 2
                    } else {
                        let attributes = position < copy.length ? copy.attributes(at: position, effectiveRange: nil) : DocumentIO.attributes(font: font())
                        copy.insert(NSAttributedString(string: "• ", attributes: attributes), at: position); delta += 2
                    }
                }
                replaceDocument(copy, selection: NSRange(location: paragraph.location, length: max(0, paragraph.length + delta)), action: "Bullet List")
                return
            }
            let copy = NSMutableAttributedString(attributedString: editor.attributedString())
            if command == "heading" { range = (editor.string as NSString).paragraphRange(for: range) }
            if command == "link" {
                guard range.length > 0 else { parent.onError("Select the words you want to turn into a link first."); return }
                guard let link = requestLink() else { return }; copy.addAttribute(.link, value: link, range: range)
            } else if command == "heading" {
                if range.length == 0 { editor.typingAttributes = DocumentIO.attributes(font: .systemFont(ofSize: parent.size * 1.35, weight: .semibold)); return }
                let current = copy.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? font()
                let newFont: NSFont = current.pointSize > parent.size * 1.2 ? font() : .systemFont(ofSize: parent.size * 1.35, weight: .semibold)
                copy.addAttribute(.font, value: newFont, range: range)
                let style = (copy.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                style.headerLevel = newFont.pointSize > parent.size * 1.2 ? 2 : 0
                copy.addAttribute(.paragraphStyle, value: style, range: range)
            } else {
                let trait: NSFontTraitMask = command == "bold" ? .boldFontMask : .italicFontMask
                if range.length == 0 {
                    let current = editor.typingAttributes[.font] as? NSFont ?? font()
                    editor.typingAttributes[.font] = NSFontManager.shared.traits(of: current).contains(trait) ? NSFontManager.shared.convert(current, toNotHaveTrait: trait) : NSFontManager.shared.convert(current, toHaveTrait: trait)
                    return
                }
                var allHaveTrait = true
                copy.enumerateAttribute(.font, in: range) { value, _, _ in if !NSFontManager.shared.traits(of: value as? NSFont ?? font()).contains(trait) { allHaveTrait = false } }
                copy.enumerateAttribute(.font, in: range) { value, run, _ in
                    let current = value as? NSFont ?? font()
                    copy.addAttribute(.font, value: allHaveTrait ? NSFontManager.shared.convert(current, toNotHaveTrait: trait) : NSFontManager.shared.convert(current, toHaveTrait: trait), range: run)
                }
            }
            replaceDocument(copy, selection: range, action: "Format Text")
        }
        private func requestLink() -> String? {
            let alert = NSAlert(); alert.messageText = "Add a Link"; alert.informativeText = "Enter an https://, http://, or mailto: address."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24)); field.placeholderString = "https://example.com"
            alert.accessoryView = field; alert.addButton(withTitle: "Add Link"); alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: value), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { parent.onError("Enter a valid web or email address."); return nil }
            return value
        }
    }
}
