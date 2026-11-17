import XCTest
import Foundation
@testable import PureTone

final class FileAccessTests: XCTestCase {
    func testRelativePathsResolveSandboxAliasesAndPreserveUnicode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real/Music", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let relative = "MyGO!!!!!/迷跡波/013-栞 100% #?.flac"
        let file = real.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: file)
        XCTAssertEqual(try FileIntegrity.relativePath(file, beneath: alias), relative)
        XCTAssertEqual(try FileIntegrity.relativePath(alias.appendingPathComponent(relative), beneath: real), relative)
        XCTAssertNotEqual(String(file.path.dropFirst(alias.path.count + 1)), relative,
                          "Legacy character-count slicing corrupts paths with differently spelled roots")
        XCTAssertThrowsError(try FileIntegrity.relativePath(root.appendingPathComponent("real/Music-elsewhere/a.flac"), beneath: real))
        XCTAssertThrowsError(try FileIntegrity.relativePath(real, beneath: real))
    }

    @MainActor func testLegacyPathRecoveryVerifiesHashAndPlaysWithoutReimport() async throws {
        try Paths.prepare()
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "original", withExtension: "flac"))
        let folder = "FileRecovery-\(UUID().uuidString)"
        let dbFile = Paths.support.appendingPathComponent(folder + ".sqlite")
        let db = try Database(url: dbFile); let library = LibraryStore(database: db)
        let relative = folder + "/MyGO!!!!!/迷跡波/013-栞.flac"
        let imported = try await library.importer.ingest(fixture, relative: relative, move: false)
        var track = try XCTUnwrap(imported)
        let originalURL = library.url(track)
        let audio = AudioController(library: library); audio.configuration = EQConfiguration()
        defer {
            audio.stop()
            try? FileManager.default.removeItem(at: Paths.music.appendingPathComponent(folder))
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbFile.path + suffix) }
        }
        // Place a same-name, different-content file first. Recovery must reject it.
        let wrong = Paths.music.appendingPathComponent(folder + "/Wrong/013-栞.flac")
        try FileManager.default.createDirectory(at: wrong.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not the original".utf8).write(to: wrong)
        track.relativePath = String(relative.dropFirst(6)); track.favorite = true
        try db.put(track, kind: "track", id: track.id)
        let playlist = Playlist(name: "Kept", trackIDs: [track.id]); library.save(playlist); library.reload()
        let recovered = try await library.importer.resolveLocalTrack(track, candidates: [wrong, originalURL])
        XCTAssertEqual(recovered.relativePath, relative); XCTAssertTrue(recovered.favorite)
        XCTAssertEqual(try FileIntegrity.sha256(originalURL), track.id)
        XCTAssertEqual(library.playlists.first?.trackIDs, [track.id])
        // Reintroduce the bad record and play an already-restored queue snapshot.
        // The controller must repair before opening the native decoder.
        try db.put(track, kind: "track", id: track.id); library.reload()
        audio.play([track], startingAt: track)
        for _ in 0..<120 {
            if audio.error != nil || audio.progress > 0.1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(audio.error, audio.path.lastError)
        XCTAssertGreaterThan(audio.progress, 0.1)
        XCTAssertEqual(audio.path.localFile, relative)
        XCTAssertGreaterThan(audio.path.localFileBytes, 0)
        XCTAssertTrue(audio.path.fileReadStatus.contains("664c6143"))
        XCTAssertEqual(audio.calibrationRequests, 0)
        XCTAssertEqual(library.tracks.first?.relativePath, relative)
        XCTAssertEqual(try FileIntegrity.sha256(originalURL), track.id)
    }

    @MainActor func testMissingAndInvalidFLACReportTheFailingStage() async throws {
        try Paths.prepare()
        let folder = "FileErrors-\(UUID().uuidString)"
        let root = Paths.music.appendingPathComponent(folder)
        let dbFile = Paths.support.appendingPathComponent(folder + ".sqlite")
        let db = try Database(url: dbFile); let library = LibraryStore(database: db)
        let audio = AudioController(library: library); audio.configuration = EQConfiguration()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            audio.stop(); try? FileManager.default.removeItem(at: root)
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbFile.path + suffix) }
        }
        let missing = root.appendingPathComponent("missing.flac")
        XCTAssertNil(pt_decoder_open(missing.path))
        let missingError = String(cString: pt_last_error())
        XCTAssertTrue(missingError.contains("FLAC open failed"), missingError)
        XCTAssertTrue(missingError.contains("errno=2"), missingError)
        let invalid = root.appendingPathComponent("invalid.flac")
        try Data([0x66, 0x4c, 0x61, 0x43, 0x00, 0x00]).write(to: invalid)
        XCTAssertNil(pt_decoder_open(invalid.path))
        let invalidError = String(cString: pt_last_error())
        XCTAssertTrue(invalidError.contains("FLAC metadata invalid or incomplete"), invalidError)
        XCTAssertNotEqual(invalidError, missingError)
        let track = Track(id: String(repeating: "a", count: 64), relativePath: folder + "/missing.flac",
                          title: "Missing", artist: "Fixture", album: "Fixture", duration: 1,
                          sampleRate: 48_000, bitDepth: 24, channels: 2)
        try db.put(track, kind: "track", id: track.id); library.reload()
        audio.play([track], startingAt: track)
        for _ in 0..<80 {
            if audio.error != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(audio.error?.contains("找不到本机原文件") == true, audio.error ?? "no error")
        XCTAssertEqual(audio.path.lastError, audio.error?.components(separatedBy: "\n").dropFirst().joined(separator: "\n"))
        XCTAssertEqual(audio.path.clientRate, 0)
        XCTAssertEqual(audio.path.localFileBytes, 0)
    }
}
