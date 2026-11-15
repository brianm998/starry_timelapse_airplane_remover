import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// The security-scoped bookmarks a sandboxed star keeps for the folders it has been granted (`BookmarkStore`), with the system calls
/// replaced so that this runs unsandboxed.
@MainActor
final class FolderBookmarkStoreTests: XCTestCase {

    /// What the preferences file holds, which outlives a store.
    private final class Disk { var bookmarks: [String: Data] = [:] }

    /// What the file system is doing to the folders behind the bookmarks.
    private final class World {
        var gone: Set<String> = []
        var stale: Set<String> = []
        var movedTo: [String: String] = [:]
        var started: [String] = []
        var stopped: [String] = []
    }

    private func store(_ disk: Disk, _ world: World, sandboxed: Bool = true) -> BookmarkStore {
        BookmarkStore(
          system: BookmarkStore.System(
            isSandboxed: sandboxed,
            makeBookmark: { Data($0.path.utf8) },
            resolveBookmark: { data in
                let path = String(decoding: data, as: UTF8.self)
                if world.gone.contains(path) { throw CocoaError(.fileNoSuchFile) }
                if let moved = world.movedTo[path] { return (URL(fileURLWithPath: moved), true) }
                return (URL(fileURLWithPath: path), world.stale.contains(path))
            },
            startAccess: { world.started.append($0.path); return true },
            stopAccess: { world.stopped.append($0.path) }),
          load: { disk.bookmarks },
          store: { disk.bookmarks = $0 })
    }

    private let sky = URL(fileURLWithPath: "/data/sky")

    /// Saved in one launch, resolved in the next: a second store over the same file finds it, for the folder and for what is inside.
    func testSaveThenResolveAfterReload() {
        let disk = Disk(), world = World()
        store(disk, world).save(url: sky)

        let reloaded = store(disk, world)
        XCTAssertEqual(reloaded.resolve(path: "/data/sky"), .resolved(sky))
        XCTAssertEqual(reloaded.resolve(covering: "/data/sky/sub/config.json"), .resolved(sky))
        XCTAssertEqual(reloaded.resolve(covering: "/data/skyline"), .missing, "a folder whose name merely starts the same is not covered")

        reloaded.startAccess(covering: "/data/sky/sub/config.json")
        reloaded.startAccess(covering: "/data/sky")
        XCTAssertEqual(world.started, ["/data/sky"], "one start per folder, however many paths it covers")
        reloaded.stopAll()
        XCTAssertEqual(world.stopped, ["/data/sky"], "every start is balanced")
        XCTAssertEqual(reloaded.activeFolders, [])
    }

    /// A bookmark the system flags as out of date, or that resolves somewhere else because the folder was moved, is reported as stale
    /// and remade from where the folder is now.
    func testStaleBookmarkIsReportedAndRefreshed() {
        let disk = Disk(), world = World()
        store(disk, world).save(url: sky)

        world.stale = ["/data/sky"]
        XCTAssertEqual(store(disk, world).resolve(path: "/data/sky"), .stale(sky))
        XCTAssertEqual(Array(disk.bookmarks.keys), ["/data/sky"], "refreshed in place")

        world.stale = []
        world.movedTo = ["/data/sky": "/data/moved"]
        let moved = URL(fileURLWithPath: "/data/moved")
        XCTAssertEqual(store(disk, world).resolve(path: "/data/sky"), .stale(moved))
        XCTAssertEqual(Array(disk.bookmarks.keys), ["/data/moved"], "the bookmark follows the folder")
        world.movedTo = [:]
        XCTAssertEqual(store(disk, world).resolve(path: "/data/moved"), .resolved(moved))
    }

    /// Nothing saved, or the folder deleted: `.missing`, which is what makes the caller ask the user.  Never a throw or a crash.
    func testMissingOrDeletedFolderIsReportedNotThrown() {
        let disk = Disk(), world = World()
        let bookmarks = store(disk, world)
        XCTAssertEqual(bookmarks.resolve(path: "/data/sky"), .missing)
        XCTAssertEqual(bookmarks.resolve(covering: "/data/sky/a/config.json"), .missing)

        bookmarks.save(url: sky)
        world.gone = ["/data/sky"]
        XCTAssertEqual(store(disk, world).resolve(path: "/data/sky"), .missing)
        XCTAssertEqual(store(disk, world).startAccess(covering: "/data/sky/a"), .missing)
        XCTAssertEqual(world.started, [])
    }

    /// A nearer bookmark that is gone does not hide a live one further up: the parent's grant still covers the sequence.
    func testDeadNearerBookmarkFallsBackToLiveAncestor() {
        let disk = Disk(), world = World()
        let bookmarks = store(disk, world)
        bookmarks.save(url: URL(fileURLWithPath: "/data"))
        bookmarks.save(url: sky)
        world.gone = ["/data/sky"]
        XCTAssertEqual(store(disk, world).resolve(covering: "/data/sky/a"), .resolved(URL(fileURLWithPath: "/data")))

        world.gone = ["/data/sky", "/data"]
        XCTAssertEqual(store(disk, world).resolve(covering: "/data/sky/a"), .missing, "nothing live: the nearest one's outcome")
    }

    /// Only a sandboxed star makes bookmarks: unsandboxed there is nothing for them to add, and the preferences file is shared.
    func testNothingIsSavedWhenNotSandboxed() {
        let disk = Disk(), world = World()
        store(disk, world, sandboxed: false).save(url: sky)
        XCTAssertTrue(disk.bookmarks.isEmpty)
    }
}
