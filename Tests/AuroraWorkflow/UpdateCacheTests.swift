import Foundation
import XCTest
@testable import Aurora

final class UpdateCacheTests: XCTestCase {
    func testInstalledVersionPrunesLegacyArtifactsWithoutRemovingNewerOrRunningBundles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = FileManager.default
        defer { try? manager.removeItem(at: root) }
        for version in ["1.5", "1.6", "1.7.0", "1.7.1", "1.8"] {
            let directory = root.appendingPathComponent(version)
            try manager.createDirectory(at: directory.appendingPathComponent("unpacked/Aurora.app"),
                                        withIntermediateDirectories: true)
            try Data().write(to: directory.appendingPathComponent("Aurora.zip"))
        }
        let note = root.appendingPathComponent("1.5/user-note.txt")
        try Data().write(to: note)
        let running = root.appendingPathComponent("1.6/unpacked/Aurora.app")
        let kept = root.appendingPathComponent("1.7.0")
        UpdateCache.prune(in: root, through: "1.7.1", keeping: kept, runningApp: running)
        XCTAssertTrue(manager.fileExists(atPath: note.path))
        XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent("1.5/unpacked").path))
        XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent("1.5/Aurora.zip").path))
        XCTAssertTrue(manager.fileExists(atPath: running.path))
        XCTAssertTrue(manager.fileExists(atPath: kept.appendingPathComponent("Aurora.zip").path))
        XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent("1.7.1").path))
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent("1.8/Aurora.zip").path))
    }

    func testMixedCleanupEmptiesExistingTrashBeforeMovingRecoverableFiles() {
        func item(_ id: String) -> StorageItem {
            StorageItem(id: id, title: "", detail: "", symbol: "", policy: .confirm, paths: [])
        }
        let selection = [item("cache"), item("trash"), item("logs")]
        XCTAssertEqual(StorageItem.cleanupOrder(selection).map(\.id), ["trash", "cache", "logs"])
    }
}
