import Foundation
import CloudKit

@MainActor final class MemoryCloud: SyncTransport {
    var user = "account-one"
    var records: [String: SyncRecord] = [:]
    var log: [(Int, SyncRecord)] = []
    var sequence = 0
    var offline = false
    var expireToken = false
    var failPage = false
    var saves = 0
    var beforeSave: (() -> Void)?
    var beforeFetch: (() -> Void)?
    func account() async throws -> String {
        if offline { throw CKError(.networkUnavailable) }; return user
    }
    func prepare(existingLibrary: Bool) async throws {}
    func fetch(since token: Data?) async throws -> SyncPage {
        beforeFetch?(); beforeFetch = nil
        if expireToken, token != nil { expireToken = false; throw SyncFailure.tokenExpired }
        if failPage, token != nil { failPage = false; throw CKError(.networkFailure) }
        let from = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let changes = log.filter { $0.0 > from }.prefix(2)
        let end = changes.last?.0 ?? sequence
        return SyncPage(records: changes.map(\.1), token: Data(String(end).utf8), moreComing: end < sequence)
    }
    func save(key: String, payload: SyncPayload, systemFields: Data?) async throws -> SyncRecord {
        beforeSave?(); beforeSave = nil
        if records[key]?.systemFields != systemFields { throw SyncFailure.conflict }
        saves += 1
        return put(key: key, payload: payload)
    }
    @discardableResult func put(key: String, payload: SyncPayload) -> SyncRecord {
        sequence += 1
        let record = SyncRecord(key: key, payload: payload, systemFields: Data(String(sequence).utf8))
        records[key] = record; log.append((sequence, record)); return record
    }
}

extension LibraryChecks {
    @MainActor static func syncChecks(in root: URL) async throws {
        func device(_ name: String) -> LibraryStore {
            let store = LibraryStore(directory: root.appendingPathComponent(name))
            store.sheets = []; store.notebooks = ["Drafts"]; store.syncState.enabled = true; store.persist()
            return store
        }
        let server = MemoryCloud()
        let a = device("mac-a"), b = device("mac-b")
        let ac = CloudSyncController(), bc = CloudSyncController()
        let sheet = Sheet(title: "Cloud manuscript", text: "Original", richText: Data("rtf payload".utf8), editorMode: "rich", wordGoal: 100)
        let id = sheet.id, key = SyncPayload.sheetKey(id)
        a.sheets = [sheet]; _ = a.addNotebook("Empty notebook"); a.persist()
        await ac.run(store: a, transport: server)
        check(server.records[key]?.payload.sheet == sheet && ac.status == "Up to date in iCloud", "initial upload preserves all sheet fields")
        await bc.run(store: b, transport: server)
        check(b.sheets == [sheet] && b.notebooks.contains("Empty notebook"), "second device downloads paginated sheets and empty notebooks")
        check(b.syncState.account == "account-one" && b.syncState.token != nil, "account and cursor committed")
        let reloaded = LibraryStore(directory: root.appendingPathComponent("mac-b"))
        check(reloaded.syncState == b.syncState && reloaded.sheets == b.sheets, "sync metadata survives restart atomically with writing")

        server.offline = true
        a.update(id) { $0.text = "Offline edit" }; a.persist()
        await ac.run(store: a, transport: server)
        check(!a.pendingCloudValues().isEmpty && ac.status.contains("Offline"), "offline edits stay queued")
        check(LibraryStore(directory: root.appendingPathComponent("mac-a")).sheets.first?.text == "Offline edit", "offline writing survives restart")
        server.offline = false
        await ac.run(store: a, transport: server); await bc.run(store: b, transport: server)
        check(b.sheets.first?.text == "Offline edit", "offline changes upload after reconnect")

        a.update(id) { $0.text = "Mac A edits" }; b.update(id) { $0.text = "Mac B edits" }
        await ac.run(store: a, transport: server); await bc.run(store: b, transport: server); await ac.run(store: a, transport: server)
        check(Set(a.sheets.map(\.text)) == Set(["Mac A edits", "Mac B edits"]) && a.sheets.sorted { $0.id.uuidString < $1.id.uuidString } == b.sheets.sorted { $0.id.uuidString < $1.id.uuidString }, "concurrent writing preserves both versions and converges")
        check(b.sheets.contains { $0.title.contains("Conflict copy") } && b.notice != nil, "conflict is labeled and surfaced")
        let count = b.sheets.count
        server.expireToken = true
        await bc.run(store: b, transport: server)
        check(b.sheets.count == count && bc.status == "Up to date in iCloud", "expired cursor full refresh does not duplicate conflicts")

        a.update(id) { $0.favorite = true; $0.wordGoal = 250 }
        await ac.run(store: a, transport: server); await bc.run(store: b, transport: server)
        check(b.sheets.first { $0.id == id }?.favorite == true && b.sheets.first { $0.id == id }?.wordGoal == 250, "favorites and goals synchronize")
        a.trash(id); await ac.run(store: a, transport: server); await bc.run(store: b, transport: server)
        check(b.sheets.first { $0.id == id }?.trashed == true, "trash synchronizes without destroying writing")
        a.emptyTrash(); await ac.run(store: a, transport: server); await bc.run(store: b, transport: server)
        check(!b.sheets.contains { $0.id == id } && server.records[key]?.payload.deleted == true, "permanent removal leaves durable tombstone")
        await ac.run(store: a, transport: server); await bc.run(store: b, transport: server)
        check(!a.sheets.contains { $0.id == id } && !b.sheets.contains { $0.id == id }, "tombstones prevent resurrection")

        let remaining = a.sheets.first!.id
        b.update(remaining) { $0.text = "Edited during deletion" }
        a.trash(remaining); a.emptyTrash(); await ac.run(store: a, transport: server); await bc.run(store: b, transport: server)
        check(b.sheets.contains { $0.text == "Edited during deletion" && $0.id != remaining && !$0.trashed }, "edit versus deletion preserves edited conflict copy")
        await ac.run(store: a, transport: server)
        check(a.sheets == b.sheets, "edit versus deletion converges")

        _ = a.addNotebook("Before rename"); let moved = a.sheets.first!.id
        a.update(moved) { $0.notebook = "Before rename" }
        await ac.run(store: a, transport: server); await bc.run(store: b, transport: server)
        _ = a.renameNotebook("Before rename", to: "After rename")
        await ac.run(store: a, transport: server); await bc.run(store: b, transport: server)
        check(b.notebooks.contains("After rename") && !b.notebooks.contains("Before rename") && b.sheets.first!.notebook == "After rename", "notebook rename and sheet moves synchronize across pages")
        a.removeNotebook("After rename")
        await ac.run(store: a, transport: server); await bc.run(store: b, transport: server)
        check(!b.notebooks.contains("After rename") && b.sheets.first!.notebook == "Drafts", "notebook deletion moves writing to Drafts")

        a.update(moved) { $0.text = "Sent version" }
        server.beforeSave = { a.update(moved) { $0.text = "Typed during upload" } }
        await ac.run(store: a, transport: server)
        check(a.pendingCloudValues()[SyncPayload.sheetKey(moved)]?.sheet?.text == "Typed during upload", "upload acknowledgment never discards later edits")
        await ac.run(store: a, transport: server); await bc.run(store: b, transport: server)
        check(b.sheets.first!.text == "Typed during upload", "later edits reach another device")

        a.update(moved) { $0.text = "Local race" }
        server.beforeSave = {
            var remote = server.records[SyncPayload.sheetKey(moved)]!.payload
            remote.sheet!.text = "Remote race"
            server.put(key: SyncPayload.sheetKey(moved), payload: remote)
        }
        await ac.run(store: a, transport: server)
        check(ac.status.contains("Another Mac"), "optimistic server conflict is retriable")
        await ac.run(store: a, transport: server)
        check(a.sheets.contains { $0.text == "Local race" } && a.sheets.contains { $0.text == "Remote race" }, "server race preserves both edits on retry")

        let saves = server.saves
        server.user = "different-account"
        await ac.run(store: a, transport: server)
        check(ac.status.contains("different iCloud account") && server.saves == saves, "account switch cannot upload library to different account")
        server.user = "account-one"
        a.syncState.enabled = false; a.update(moved) { $0.text = "Paused edit" }
        await ac.run(store: a, transport: server)
        check(server.saves == saves && !a.pendingCloudValues().isEmpty, "disabling sync preserves queued local work")
        a.syncState.enabled = true

        let cursor = b.syncState.token
        let before = b.sheets
        server.failPage = true
        await bc.run(store: b, transport: server)
        check(b.syncState.token == cursor && b.sheets == before, "failed fetch does not advance cursor or apply partial changes")
        await bc.run(store: b, transport: server)
        check(b.sheets.contains { $0.text == "Remote race" }, "retry fetch recovers remote changes")

        let competing = LibraryStore(directory: root.appendingPathComponent("mac-a"))
        competing.update(moved) { $0.text = "External writer" }; competing.persist()
        let countBeforeSaveFailure = server.saves
        await ac.run(store: a, transport: server)
        check(ac.status.contains("local library could not be saved") && server.saves == countBeforeSaveFailure, "failed local save prevents cloud upload")

        let fresh = device("mac-failed-pages")
        let fc = CloudSyncController()
        server.failPage = true
        await fc.run(store: fresh, transport: server)
        check(fresh.syncState.token == nil && fresh.sheets.isEmpty, "failure after first fetch page commits no partial library")
        await fc.run(store: fresh, transport: server)
        check(!fresh.sheets.isEmpty, "full paginated fetch retries cleanly")
        let priorSaves = server.saves
        server.beforeFetch = { server.user = "switched-during-fetch" }
        await fc.run(store: fresh, transport: server)
        check(fc.status.contains("different iCloud account") && server.saves == priorSaves, "account identity is rechecked after fetching")
        server.user = "account-one"

        let clean = device("mac-reset")
        let cc = CloudSyncController()
        await cc.run(store: clean, transport: server)
        clean.syncState.token = nil
        server.log = []; server.records = [:]
        await cc.run(store: clean, transport: server)
        check(cc.status.contains("removed or changed") && !clean.sheets.isEmpty, "cloud reset pauses instead of silently replacing cloud data")
    }
}
