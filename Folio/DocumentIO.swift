import AppKit
import CoreText
import UniformTypeIdentifiers

@MainActor enum DocumentIO {
    enum Format: String, CaseIterable, Identifiable {
        case markdown = "Markdown", plain = "Plain Text", rtf = "Rich Text", docx = "Word Document", pdf = "PDF"
        var id: String { rawValue }
        var ext: String { switch self { case .markdown: "md"; case .plain: "txt"; case .rtf: "rtf"; case .docx: "docx"; case .pdf: "pdf" } }
        var type: UTType { UTType(filenameExtension: ext) ?? .plainText }
    }
    static let baseFont = NSFont(name: "Georgia", size: 18) ?? NSFont.systemFont(ofSize: 18)
    static func attributes(font: NSFont? = nil) -> [NSAttributedString.Key: Any] {
        let font = font ?? baseFont
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacing = 5
        return [.font: font, .paragraphStyle: style, .foregroundColor: NSColor.labelColor]
    }
    static func body(_ sheet: Sheet) -> NSAttributedString {
        if sheet.isRich, let data = sheet.richText,
           let result = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil), result.string == sheet.text { return result }
        return sheet.isRich ? NSAttributedString(string: sheet.text, attributes: attributes()) : markdown(sheet.text)
    }
    static func rtf(_ value: NSAttributedString) throws -> Data {
        let copy = NSMutableAttributedString(attributedString: value)
        copy.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 0, length: copy.length))
        return try copy.data(from: NSRange(location: 0, length: copy.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }
    static func markdown(_ source: String) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        var code = false
        let lines = source.components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            if raw.hasPrefix("```") { code.toggle(); continue }
            var line = raw
            var font = baseFont
            var headingLevel = 0
            if code { font = .monospacedSystemFont(ofSize: 16, weight: .regular) }
            else {
                let hashes = line.prefix(while: { $0 == "#" }).count
                if (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") {
                    headingLevel = hashes
                    line = String(line.dropFirst(hashes + 1))
                    font = .systemFont(ofSize: max(19, 32 - Double(hashes) * 3), weight: .semibold)
                }
            }
            let styled = NSMutableAttributedString(string: line, attributes: attributes(font: font))
            if headingLevel > 0 {
                let style = attributes(font: font)[.paragraphStyle] as! NSMutableParagraphStyle
                style.headerLevel = headingLevel
                styled.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: styled.length))
            }
            if !code {
                for (pattern, trait) in [(#"\*\*(.+?)\*\*"#, NSFontTraitMask.boldFontMask), (#"(?<!\w)_(.+?)_(?!\w)"#, .italicFontMask), (#"(?<!\*)\*([^*\n]+)\*(?!\*)"#, .italicFontMask)] {
                    if let regex = try? NSRegularExpression(pattern: pattern) {
                        for match in regex.matches(in: styled.string, range: NSRange(location: 0, length: styled.length)).reversed() {
                            let value = NSMutableAttributedString(attributedString: styled.attributedSubstring(from: match.range(at: 1)))
                            value.enumerateAttribute(.font, in: NSRange(location: 0, length: value.length)) { original, range, _ in
                                value.addAttribute(.font, value: NSFontManager.shared.convert(original as? NSFont ?? font, toHaveTrait: trait), range: range)
                            }
                            styled.replaceCharacters(in: match.range, with: value)
                        }
                    }
                }
                if let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\((https?://[^\s)]+|mailto:[^\s)]+)\)"#) {
                    for match in regex.matches(in: styled.string, range: NSRange(location: 0, length: styled.length)).reversed() {
                        let title = (styled.string as NSString).substring(with: match.range(at: 1))
                        let url = (styled.string as NSString).substring(with: match.range(at: 2))
                        let link = NSMutableAttributedString(string: title, attributes: attributes(font: font))
                        link.addAttribute(.link, value: url, range: NSRange(location: 0, length: link.length))
                        styled.replaceCharacters(in: match.range, with: link)
                    }
                }
            }
            output.append(styled)
            if index < lines.count - 1 { output.append(NSAttributedString(string: "\n", attributes: attributes())) }
        }
        return output
    }
    static func toMarkdown(_ value: NSAttributedString) -> String {
        var output = ""
        let source = value.string as NSString
        var offset = 0
        while offset < value.length {
            let paragraph = source.paragraphRange(for: NSRange(location: offset, length: 0))
            var end = NSMaxRange(paragraph)
            while end > paragraph.location && [10, 13, 0x2028, 0x2029].contains(source.character(at: end - 1)) { end -= 1 }
            let body = NSRange(location: paragraph.location, length: end - paragraph.location)
            let header = (value.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?.headerLevel ?? 0
            if header > 0 { output += String(repeating: "#", count: min(header, 6)) + " " }
            value.enumerateAttributes(in: body) { attributes, range, _ in
                var text = source.substring(with: range)
                guard !text.isEmpty else { return }
                let leading = String(text.prefix(while: { $0.isWhitespace }))
                let trailing = String(text.reversed().prefix(while: { $0.isWhitespace }).reversed())
                text = text.trimmingCharacters(in: .whitespaces)
                if text.isEmpty { output += source.substring(with: range); return }
                let traits = (attributes[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
                if traits.contains(.italicFontMask) { text = "_" + text + "_" }
                if traits.contains(.boldFontMask) && header == 0 { text = "**" + text + "**" }
                if let link = attributes[.link] { text = "[\(text)](\(link))" }
                output += leading + text + trailing
            }
            output += source.substring(with: NSRange(location: end, length: NSMaxRange(paragraph) - end))
            offset = NSMaxRange(paragraph)
        }
        return output
    }
    static func importFile(_ url: URL, notebook: String) throws -> Sheet {
        let ext = url.pathExtension.lowercased()
        var sheet = Sheet(title: url.deletingPathExtension().lastPathComponent, text: "", notebook: notebook)
        if ["rtf", "docx"].contains(ext) {
            let data = try Data(contentsOf: url)
            let type: NSAttributedString.DocumentType = ext == "rtf" ? .rtf : .officeOpenXML
            let content = try NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil)
            sheet.text = content.string
            sheet.editorMode = "rich"
            sheet.richText = try rtf(content)
        } else if ["txt", "md", "markdown"].contains(ext) {
            var encoding = String.Encoding.utf8
            sheet.text = try String(contentsOf: url, usedEncoding: &encoding)
            sheet.editorMode = ext == "txt" ? "rich" : "markdown"
        } else { throw LibraryFailure.invalid("Unsupported file: \(url.lastPathComponent). Choose TXT, Markdown, RTF, or DOCX.") }
        return sheet
    }
    static func exportData(_ sheet: Sheet, format: Format) throws -> Data {
        if format == .plain { return Data((sheet.displayTitle + "\n\n" + sheet.text).utf8) }
        if format == .markdown { return Data(("# " + sheet.displayTitle + "\n\n" + (sheet.isRich ? toMarkdown(body(sheet)) : sheet.text)).utf8) }
        let document = NSMutableAttributedString(string: sheet.displayTitle + "\n\n", attributes: attributes(font: .systemFont(ofSize: 28, weight: .bold)))
        document.append(body(sheet))
        document.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 0, length: document.length))
        if format == .pdf { return try pdf(document, title: sheet.displayTitle) }
        return try document.data(from: NSRange(location: 0, length: document.length), documentAttributes: [
            .documentType: format == .docx ? NSAttributedString.DocumentType.officeOpenXML : .rtf,
            .paperSize: NSSize(width: 595, height: 842), .leftMargin: 56, .rightMargin: 56, .topMargin: 56, .bottomMargin: 56
        ])
    }
    static func pdf(_ text: NSAttributedString, title: String) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: title] as CFDictionary) else { throw LibraryFailure.invalid("Could not create the PDF.") }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: CGRect(x: 56, y: 65, width: 483, height: 721), transform: nil)
        var offset = 0, page = 1
        repeat {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let number = NSAttributedString(string: "\(page)", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.gray])
            context.textPosition = CGPoint(x: 291, y: 30)
            CTLineDraw(CTLineCreateWithAttributedString(number), context)
            context.endPDFPage()
            let count = CTFrameGetVisibleStringRange(frame).length
            guard count > 0 || text.length == 0 else { throw LibraryFailure.invalid("A paragraph could not fit on the PDF page. Reduce its text size and try again.") }
            offset += count; page += 1
        } while offset < text.length
        context.closePDF()
        return data as Data
    }
}
