import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let sqlite = directory.appendingPathComponent("clipboard.sqlite3")
let legacy = directory.appendingPathComponent("clipboard.json")
func make(_ i: Int, pinned: Bool = false, image: String? = nil) -> ClipItem {
    let text = "item \(i) " + String(repeating: "数据", count: 500) + " Ömega-\(i)\0end"
    return ClipItem(kind: image == nil ? .text : .image, text: text, imageFile: image,
                    date: Date(timeIntervalSince1970: Double(i)), pinned: pinned, source: "fixture",
                    sourceBundle: "local.fixture", byteCount: text.utf8.count)
}
func check(_ message: String, _ assertion: @autoclosure () throws -> Bool) rethrows {
    let passed = try assertion()
    precondition(passed, message)
    print("PASS: \(message)")
}
let old = (1...9).reversed().map { make($0, pinned: $0 == 1, image: $0 == 2 ? "sample.png" : nil) }
let original = try JSONEncoder().encode(old)
try original.write(to: legacy)
do {
    let db = try ClipboardHistoryStore(url: sqlite)
    try db.migrateLegacy(from: legacy)
    try check("JSON migrates transactionally with attachment metadata",
              db.stats().count == 9 && !FileManager.default.fileExists(atPath: legacy.path)
                && db.item(id: old[7].id)?.imageFile == "sample.png")
    let recent = try db.recent()
    try check("five complete hot records in saved-time order", db.recent().map(\.id) == Array(old.prefix(5)).map(\.id)
              && recent[0].text == old[0].text)
    let page1 = try db.page(query: "", filter: .all, pinnedFirst: false, limit: 3, offset: 0)
    let page2 = try db.page(query: "", filter: .all, pinnedFirst: false, limit: 3, offset: 3)
    check("cold pages are disjoint and contain summaries, not bodies",
          page1.map(\.id) == Array(old.prefix(3)).map(\.id) && page2.map(\.id) == old[3...5].map(\.id)
              && (page1 + page2).allSatisfy { $0.text.isEmpty && !$0.preview.isEmpty })
    let reader = try ClipboardHistoryStore(url: sqlite, readOnly: true)
    try check("read-only background connection sees committed WAL and can search full text",
              reader.page(query: "öMEGA-3", filter: .text, pinnedFirst: true, limit: 9, offset: 0).map(\.id) == [old[6].id])
    var rejectedWrite = false
    do { _ = try reader.clear(keepPinned: false) } catch { rejectedWrite = true }
    try check("read-only connection rejects mutations", rejectedWrite && db.stats().count == 9)
    let hit = try db.page(query: "öMEGA-3", filter: .text, pinnedFirst: true, limit: 30, offset: 0)
    try check("search finds Unicode match past preview; cold item returns full body including NUL",
              hit.map(\.id) == [old[6].id] && db.item(id: old[6].id)?.text == old[6].text)
    try check("pins can be browsed independently of the hot five",
              db.page(query: "", filter: .pinned, pinnedFirst: true, limit: 9, offset: 0).map(\.id) == [old[8].id])
    var duplicate = old[6]
    duplicate.date = Date(timeIntervalSince1970: 10)
    duplicate.source = "recopied"
    let recorded = try db.record(duplicate, dedupe: true, limit: 20)
    try check("cold dedupe promotes same UUID and increments copies",
              recorded.duplicate && db.recent(keeping: recent).first?.id == duplicate.id
                && db.item(id: duplicate.id)?.copies == 2 && db.stats().count == 9)
    let removed = try db.record(make(11), dedupe: false, limit: 9)
    try check("one overflow evicts only oldest unpinned; committed attachment returned",
              removed.removed.count == 1 && removed.removed[0].image == "sample.png"
                && db.item(id: old[8].id) != nil && db.stats().count == 9)
    var edited = try db.item(id: old[5].id)!
    edited.text = "edited cold body"
    edited.byteCount = edited.text.utf8.count
    edited.date = Date(timeIntervalSince1970: 12)
    try db.update(edited)
    try check("editing cold record is durable, preserves identity and updates order", db.recent().first?.text == edited.text)
}
do {
    let db = try ClipboardHistoryStore(url: sqlite)
    try check("reopen keeps old dates and data; no TTL trimming", db.stats().count == 9 && db.stats().pinned == 1
              && db.recent().first?.text == "edited cold body")
    _ = try db.clear(keepPinned: true)
    try check("manual clear unpinned preserves pin", db.stats().count == 1 && db.stats().pinned == 1)
    _ = try db.clear(keepPinned: false)
    try original.write(to: legacy) // simulate an old source file left by failed cleanup after commit
    try db.migrateLegacy(from: legacy)
    try check("manual clear all survives restart/migration retry", db.stats().count == 0 && db.recent().isEmpty)
}
do {
    let db = try ClipboardHistoryStore(url: sqlite)
    for i in 1...6 { _ = try db.record(make(i, pinned: true), dedupe: false, limit: 5) }
    _ = try db.record(make(7), dedupe: false, limit: 5)
    try check("pinned overflow never evicts pinned entries", db.stats().count == 6 && db.stats().pinned == 6)
    let attrs = try FileManager.default.attributesOfItem(atPath: sqlite.path)
    check("private database permissions", attrs[.posixPermissions] as? Int == 0o600)
}
let broken = directory.appendingPathComponent("broken.json")
let bytes = Data("not-a-json-array".utf8)
try bytes.write(to: broken)
let failedDB = try ClipboardHistoryStore(url: directory.appendingPathComponent("failed.sqlite3"))
var migrationFailed = false
do { try failedDB.migrateLegacy(from: broken) } catch { migrationFailed = true }
try check("failed migration leaves original untouched", migrationFailed && Data(contentsOf: broken) == bytes
          && failedDB.stats().count == 0)
