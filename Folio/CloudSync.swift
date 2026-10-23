import Foundation
import CloudKit
import Observation

// Baselines and server change tags are committed in the same atomic file as writing.
// A successful upload acknowledges only the exact payload sent, never newer edits.
struct SyncPayload: Codable, Equatable {
    var version = 1
    var sheet: Sheet?
    var notebook: String?
    var deleted = false
    static func sheetKey(_ id: UUID) -> String { "sheet-" + id.uuidString }
    static func notebookKey(_ name: String) -> String { "book-" + Data(name.utf8).base64EncodedString() }
    var tombstone: Self { SyncPayload(notebook: notebook, deleted: true) }
}
struct SyncState: Codable, Equatable {
    var enabled = false
    var account: String?
    var baseline: [String: SyncPayload] = [:]
    var systemFields: [String: Data] = [:]
    var token: Data?
    var lastSync: Date?
}
struct SyncRecord {
    var key: String
    var payload: SyncPayload
    var systemFields: Data
}
struct SyncPage {
    var records: [SyncRecord]
    var token: Data
    var moreComing: Bool
}
enum SyncFailure: LocalizedError {
    case unavailable, accountChanged, conflict, tokenExpired, cloudReset, invalidData, localSave
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Sign in to iCloud in System Settings, then try again."
        case .accountChanged: return "Sync paused: this library belongs to a different iCloud account. Sign back in to the original account to resume. Your writing is still on this Mac."
        case .conflict: return "Another Mac saved changes. Folio will merge them on the next sync."
        case .tokenExpired: return "Refreshing the iCloud library…"
        case .cloudReset: return "The iCloud library was removed or changed outside Folio. Sync is paused to protect your writing. Export a backup before resetting cloud storage."
        case .invalidData: return "iCloud contains data this version of Folio cannot read. Update Folio before syncing."
        case .localSave: return "Sync paused because the local library could not be saved. Resolve the save error before syncing again."
        }
    }
}
@MainActor protocol SyncTransport {
    func account() async throws -> String
    func prepare(existingLibrary: Bool) async throws
    func fetch(since token: Data?) async throws -> SyncPage
    func save(key: String, payload: SyncPayload, systemFields: Data?) async throws -> SyncRecord
}

@MainActor final class CloudKitTransport: SyncTransport {
    private let container: CKContainer
    private let database: CKDatabase
    private let zone = CKRecordZone.ID(zoneName: "FolioLibrary", ownerName: CKCurrentUserDefaultName)
    init() {
        let identifier = Bundle.main.object(forInfoDictionaryKey: "FolioCloudContainer") as? String ?? "iCloud.com.folio.writing"
        container = CKContainer(identifier: identifier)
        database = container.privateCloudDatabase
    }
    func account() async throws -> String {
        guard try await container.accountStatus() == .available else { throw SyncFailure.unavailable }
        return try await container.userRecordID().recordName
    }
    func prepare(existingLibrary: Bool) async throws {
        do { _ = try await database.recordZone(for: zone) }
        catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            guard !existingLibrary else { throw SyncFailure.cloudReset }
            _ = try await database.save(CKRecordZone(zoneID: zone))
        }
    }
    func fetch(since token: Data?) async throws -> SyncPage {
        let cursor = try token.map { try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        do {
            let page = try await database.recordZoneChanges(inZoneWith: zone, since: cursor ?? nil, resultsLimit: 100)
            // Folio uses durable tombstone records. A hard deletion means external reset.
            guard page.deletions.isEmpty else { throw SyncFailure.cloudReset }
            let records = try page.modificationResultsByID.values.map { try decode($0.get().record) }
            return SyncPage(records: records, token: try NSKeyedArchiver.archivedData(withRootObject: page.changeToken, requiringSecureCoding: true), moreComing: page.moreComing)
        } catch let error as CKError where error.code == .changeTokenExpired { throw SyncFailure.tokenExpired }
    }
    func save(key: String, payload: SyncPayload, systemFields: Data?) async throws -> SyncRecord {
        let record: CKRecord
        if let systemFields {
            let decoder = try NSKeyedUnarchiver(forReadingFrom: systemFields)
            decoder.requiresSecureCoding = true
            defer { decoder.finishDecoding() }
            guard let restored = CKRecord(coder: decoder) else { throw SyncFailure.invalidData }
            record = restored
        } else { record = CKRecord(recordType: "FolioItem", recordID: CKRecord.ID(recordName: key, zoneID: zone)) }
        guard record.recordID.recordName == key, record.recordID.zoneID == zone else { throw SyncFailure.invalidData }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FolioCloud-" + UUID().uuidString)
        try JSONEncoder().encode(payload).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        record["payload"] = CKAsset(fileURL: url)
        do {
            let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            guard let saved = result.saveResults[record.recordID] else { throw SyncFailure.invalidData }
            return try decode(saved.get())
        } catch let error as CKError where error.code == .serverRecordChanged { throw SyncFailure.conflict }
    }
    private func decode(_ record: CKRecord) throws -> SyncRecord {
        guard record.recordType == "FolioItem", let asset = record["payload"] as? CKAsset, let url = asset.fileURL else { throw SyncFailure.invalidData }
        let payload = try JSONDecoder().decode(SyncPayload.self, from: Data(contentsOf: url))
        let key = record.recordID.recordName
        guard payload.version == 1 else { throw SyncFailure.invalidData }
        if key.hasPrefix("sheet-") {
            guard let id = UUID(uuidString: String(key.dropFirst(6))), payload.notebook == nil,
                  payload.deleted ? payload.sheet == nil : payload.sheet?.id == id else { throw SyncFailure.invalidData }
        } else {
            guard let name = payload.notebook, key == SyncPayload.notebookKey(name), !name.isEmpty, payload.sheet == nil else { throw SyncFailure.invalidData }
        }
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder); coder.finishEncoding()
        return SyncRecord(key: key, payload: payload, systemFields: coder.encodedData)
    }
}

@MainActor @Observable final class CloudSyncController {
    private(set) var status = "Stored on this Mac"
    private(set) var busy = false
    private var loop: Task<Void, Never>?
    private var accountObserver: Task<Void, Never>?
    private var generation = 0
    private var retryAfter = Date.distantPast
    private var failures = 0
    private weak var store: LibraryStore?
    private var transport: (any SyncTransport)?
    static var available: Bool {
        #if FOLIO_CLOUD
        true
        #else
        false
        #endif
    }
    func start(_ store: LibraryStore) {
        guard self.store == nil else { return }
        self.store = store
        guard Self.available else { status = "iCloud setup required"; return }
        transport = CloudKitTransport()
        accountObserver = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
                guard let self else { return }
                self.generation += 1
                self.status = "iCloud account changed. Checking…"
                self.retryAfter = .distantPast
            }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if let self, let store = self.store, let transport = self.transport, store.syncState.enabled, Date() >= self.retryAfter {
                    await self.run(store: store, transport: transport)
                }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }
    func setEnabled(_ enabled: Bool) {
        guard let store, Self.available, store.writable else { return }
        generation += 1
        store.syncState.enabled = enabled; store.persist()
        status = enabled ? "Waiting to sync…" : "Sync off · writing kept on this Mac"
        if enabled { syncNow() }
    }
    func syncNow() {
        guard let store, let transport, store.syncState.enabled else { return }
        retryAfter = .distantPast
        Task { await run(store: store, transport: transport) }
    }
    // Also used by deterministic multi-device tests with an in-memory transport.
    func run(store: LibraryStore, transport: any SyncTransport) async {
        guard !busy, store.syncState.enabled, store.writable else { return }
        busy = true; defer { busy = false }
        status = "Syncing…"
        let session = generation
        func validate() throws {
            try Task.checkCancellation()
            guard session == generation, store.syncState.enabled else { throw CancellationError() }
        }
        do {
            store.persist()
            guard store.saveState == "Saved on this Mac" else { throw SyncFailure.localSave }
            let account = try await transport.account(); try validate()
            if let bound = store.syncState.account, bound != account { throw SyncFailure.accountChanged }
            store.syncState.account = account
            try store.commitSyncState()
            try await transport.prepare(existingLibrary: !store.syncState.baseline.isEmpty); try validate()
            var cursor = store.syncState.token
            var refresh = cursor == nil
            var incoming: [SyncRecord] = []
            var more = true
            while more {
                let page: SyncPage
                do { page = try await transport.fetch(since: cursor) }
                catch SyncFailure.tokenExpired {
                    guard !refresh else { throw SyncFailure.tokenExpired }
                    cursor = nil; incoming = []; refresh = true
                    continue
                }
                try validate()
                incoming.append(contentsOf: page.records)
                cursor = page.token
                more = page.moreComing
            }
            guard try await transport.account() == account else { throw SyncFailure.accountChanged }; try validate()
            if refresh, !Set(store.syncState.baseline.keys).isSubset(of: Set(incoming.map(\.key))) {
                throw SyncFailure.cloudReset
            }
            // Fetch all pages before merging, so notebook moves cannot arrive halfway.
            // The token and the full merge commit together; failures replay safely.
            let latest = Dictionary(incoming.map { ($0.key, $0) }, uniquingKeysWith: { _, newest in newest })
            store.mergeCloud(latest.values.sorted { $0.key < $1.key })
            store.syncState.token = cursor
            try store.commitSyncState()
            for key in store.pendingCloudValues().keys.sorted() {
                try validate()
                guard try await transport.account() == account else { throw SyncFailure.accountChanged }; try validate()
                guard let payload = store.pendingCloudValues()[key] else { continue }
                // Local edits made during awaits must be durable before sending.
                try store.commitSyncState()
                let saved = try await transport.save(key: key, payload: payload, systemFields: store.syncState.systemFields[key])
                try validate()
                store.syncState.baseline[key] = payload
                store.syncState.systemFields[key] = saved.systemFields
                try store.commitSyncState()
            }
            store.syncState.lastSync = Date(); try store.commitSyncState()
            status = store.pendingCloudValues().isEmpty ? "Up to date in iCloud" : "Changes waiting to sync"
            failures = 0; retryAfter = .distantPast
        } catch is CancellationError { /* Turning sync off never removes local writing. */ }
        catch {
            failures += 1
            let delay = (error as? CKError)?.retryAfterSeconds ?? min(300, pow(2, Double(min(failures, 8))))
            retryAfter = Date().addingTimeInterval(delay)
            if let error = error as? CKError, [.networkUnavailable, .networkFailure].contains(error.code) {
                status = "Offline · changes saved on this Mac"
            } else { status = error.localizedDescription }
        }
    }
    func localChanges() {
        if let store, Self.available, store.syncState.enabled, !busy, !store.pendingCloudValues().isEmpty {
            status = "Changes waiting to sync"
        }
    }
    func libraryWillReload() { generation += 1 }
}

extension LibraryStore {
    func cloudValues() -> [String: SyncPayload] {
        var values = Dictionary(uniqueKeysWithValues: sheets.map { (SyncPayload.sheetKey($0.id), SyncPayload(sheet: $0)) })
        for name in notebooks { values[SyncPayload.notebookKey(name)] = SyncPayload(notebook: name) }
        for (key, baseline) in syncState.baseline where values[key] == nil { values[key] = baseline.tombstone }
        return values
    }
    func pendingCloudValues() -> [String: SyncPayload] {
        cloudValues().filter { syncState.baseline[$0.key] != $0.value }
    }
    func commitSyncState() throws {
        persist()
        guard saveState == "Saved on this Mac" else { throw SyncFailure.localSave }
    }
    func mergeCloud(_ records: [SyncRecord]) {
        for record in records {
            let base = syncState.baseline[record.key]
            let local = cloudValues()[record.key]
            let remote = record.payload
            if local != remote && remote != base {
                if local == base || local == nil {
                    applyCloud(remote, key: record.key)
                } else if record.key.hasPrefix("sheet-") {
                    // Preserve both divergent manuscripts, including edit-vs-delete races.
                    if var copy = local?.sheet {
                        copy.id = UUID(); copy.title = copy.displayTitle + " (Conflict copy)"; copy.trashed = false
                        sheets.append(copy)
                        notice = "Edits from two Macs overlapped. Both versions were kept; look for ‘Conflict copy’."
                    } else if remote.sheet != nil {
                        notice = "A sheet edited on another Mac was kept instead of being permanently removed."
                    }
                    applyCloud(remote, key: record.key)
                }
                // Concurrent notebook add/remove keeps the local choice; writing stays intact.
            }
            syncState.baseline[record.key] = remote
            syncState.systemFields[record.key] = record.systemFields
        }
        for name in sheets.map(\.notebook) where !notebooks.contains(name) { notebooks.append(name) }
        if !notebooks.contains("Drafts") { notebooks.insert("Drafts", at: 0) }
        if !["All Writing", "Favorites", "Trash"].contains(section) && !notebooks.contains(section) { section = "All Writing" }
        reconcileSelection()
    }
    private func applyCloud(_ payload: SyncPayload, key: String) {
        if key.hasPrefix("sheet-"), let id = UUID(uuidString: String(key.dropFirst(6))) {
            if let index = sheets.firstIndex(where: { $0.id == id }) {
                checkpoint(sheets[index], reason: "Before iCloud update", force: true)
                if let sheet = payload.sheet, !payload.deleted { sheets[index] = sheet }
                else { sheets.remove(at: index) }
            } else if let sheet = payload.sheet, !payload.deleted { sheets.append(sheet) }
        } else if let name = payload.notebook {
            if payload.deleted { notebooks.removeAll { $0 == name } }
            else if !notebooks.contains(name) { notebooks.append(name) }
        }
    }
}
