import Foundation
import Darwin

struct Sheet: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var text: String
    var notebook: String = "Drafts"
    var favorite = false
    var trashed = false
    var modified = Date()
    // Optional fields keep version 1 libraries readable without losing content.
    var richText: Data? = nil
    var editorMode: String? = nil
    var wordGoal: Int? = nil
    var coverImage: Data? = nil
    var visualLayout: Bool? = nil
    var isRich: Bool { editorMode == "rich" }
    var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count }
    var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title }
}

struct Revision: Identifiable, Codable, Equatable {
    var id = UUID()
    var date = Date()
    var sheet: Sheet
    var reason: String
}

struct LibraryFile: Codable, Equatable {
    var version = 3
    var sheets: [Sheet]
    var notebooks: [String]? = nil
    var revisions: [Revision]? = nil
    var selectedID: UUID? = nil
    var section: String? = nil
    var sync: SyncState? = nil
}

enum LibraryFailure: LocalizedError {
    case newerVersion, changedOnDisk, invalid(String)
    var errorDescription: String? {
        switch self {
        case .newerVersion: return "This library was created by a newer version of Folio. Update Folio before opening it."
        case .changedOnDisk: return "The library changed outside this window. Export a backup of your current work, then use Reload Library to open the newer file. Folio has not overwritten either copy."
        case .invalid(let reason): return reason
        }
    }
}

final class LibraryRepository {
    let url: URL
    private var baseline: Data?
    private var lastBackup: Date = .distantPast
    init(url: URL) { self.url = url }
    var backupsURL: URL { url.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true) }
    static func decode(_ data: Data) throws -> LibraryFile {
        let library = try JSONDecoder().decode(LibraryFile.self, from: data)
        guard (1...3).contains(library.version) else { throw LibraryFailure.newerVersion }
        guard Set(library.sheets.map(\.id)).count == library.sheets.count else { throw LibraryFailure.invalid("The library contains duplicate document identifiers.") }
        return library
    }
    func loadFile() throws -> LibraryFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { baseline = nil; return nil }
        let data = try Data(contentsOf: url)
        let result = try Self.decode(data)
        baseline = data
        return result
    }
    func load() throws -> [Sheet]? { try loadFile()?.sheets }
    static func encode(_ library: LibraryFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(library)
    }
    func archive(_ library: LibraryFile) throws {
        try FileManager.default.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        let name = "Library-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).folio"
        try Self.encode(library).write(to: backupsURL.appendingPathComponent(name), options: .atomic)
    }
    func save(_ sheets: [Sheet]) throws { try saveFile(LibraryFile(sheets: sheets)) }
    func saveFile(_ library: LibraryFile) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent("library.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LibraryFailure.invalid("Could not lock the library for saving.") }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw LibraryFailure.invalid("Another Folio process is saving this library. Try Save Now again.") }
        let existing = manager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard existing == baseline else { throw LibraryFailure.changedOnDisk }
        let data = try Self.encode(library)
        guard data != existing else { return }
        if let existing, Date().timeIntervalSince(lastBackup) >= 300 {
            _ = try Self.decode(existing)
            try manager.createDirectory(at: backupsURL, withIntermediateDirectories: true)
            let name = "Library-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).folio"
            try existing.write(to: backupsURL.appendingPathComponent(name), options: .atomic)
            lastBackup = Date()
        }
        try data.write(to: url, options: .atomic)
        baseline = data
        // Keep twenty recent valid snapshots. Backups are separate from the active library.
        if let backups = try? manager.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: [.creationDateKey]) {
            for old in backups.filter({ $0.pathExtension == "folio" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(20) { try? manager.removeItem(at: old) }
        }
    }
}
