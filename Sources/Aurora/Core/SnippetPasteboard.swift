import AppKit

/// 仅在剪贴板仍属于本次展开时恢复，保留所有数据类型及空剪贴板。作者：wwj。
final class SnippetPasteboard {
    private let board: NSPasteboard
    private let saved: [[NSPasteboard.PasteboardType: Data]]
    private var ownedChange: Int?

    init(_ board: NSPasteboard) {
        self.board = board
        saved = (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func write(_ text: String) -> Bool {
        board.clearContents()
        let succeeded = board.setString(text, forType: .string)
        ownedChange = board.changeCount
        guard succeeded else { restore(); return false }
        return true
    }

    func restore() {
        guard let ownedChange, board.changeCount == ownedChange else { return }
        board.clearContents()
        let items = saved.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }
}
