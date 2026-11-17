import XCTest
import Foundation
@testable import PureTone

final class LyricsFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, value in value })
        var status = 200; var value: Any = [:]
        if url.path == "/api/search/get" {
            value = ["code": 200, "result": ["songs": [
                ["id": 1, "name": "Example", "artists": [["name": "Singer"]], "duration": 180000],
                ["id": 2, "name": "Example", "artists": [["name": "Singer"]], "duration": 180000]
            ]]]
        } else if url.path == "/api/song/lyric/v1" {
            if query["id"] == "1" { status = 500 }
            else { value = ["code": 200, "lrc": ["lyric": "[00:01.00]Example lyric"]] }
        } else if url.path == "/api/get" { status = 404 }
        else if url.path == "/api/search" {
            value = [["trackName": "Example", "artistName": "Singer", "albumName": "Release", "duration": 180, "syncedLyrics": "[00:01.00]Example lyric"]]
        } else if url.path == "/search" { value = ["candidates": []] }
        else { status = 403 }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class LibraryAndLyricsTests: XCTestCase {
    private func track(id: String = UUID().uuidString, path: String = "Singer/Release/001-Example.flac", title: String = "Example", artist: String = "Singer") -> Track {
        Track(id: id, relativePath: path, title: title, artist: artist, album: "Release", duration: 180, sampleRate: 44_100, bitDepth: 24, channels: 2)
    }
    private func service() -> LyricsService {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LyricsFixtureProtocol.self]
        return LyricsService(session: URLSession(configuration: config))
    }
    func testPlotUsesTheSameLogFrequencyAndLinearDBCoordinates() {
        let scale = EQPlotScale(maximumFrequency: 20_000)
        XCTAssertEqual(scale.frequencyPosition(10), 0, accuracy: 1e-12)
        XCTAssertEqual(scale.frequencyPosition(20_000), 1, accuracy: 1e-12)
        let decade = scale.frequencyPosition(100) - scale.frequencyPosition(10)
        XCTAssertEqual(scale.frequencyPosition(1_000) - scale.frequencyPosition(100), decade, accuracy: 1e-12)
        XCTAssertEqual(scale.frequencyPosition(10_000) - scale.frequencyPosition(1_000), decade, accuracy: 1e-12)
        XCTAssertEqual(scale.frequencyPosition(400) - scale.frequencyPosition(200), scale.frequencyPosition(40) - scale.frequencyPosition(20), accuracy: 1e-12)
        XCTAssertEqual(scale.gainPosition(0), 0.5)
        XCTAssertEqual(scale.gainPosition(-12) - scale.gainPosition(0), scale.gainPosition(0) - scale.gainPosition(12), accuracy: 1e-12)
    }
    func testFLACUTF8CommentsRepairIdentityAndExposeEmbeddedLyrics() throws {
        func number(_ value: Int) -> Data { var n = UInt32(value).littleEndian; return withUnsafeBytes(of: &n) { Data($0) } }
        func string(_ value: String) -> Data { let bytes = Data(value.utf8); return number(bytes.count) + bytes }
        let entries = ["TITLE=测试の歌", "ARTIST=歌手", "ALBUM=专辑", "TRACKNUMBER=3/10", "LYRICS=[00:01.00]歌词"]
        var comments = string("Test fixture") + number(entries.count)
        for entry in entries { comments.append(string(entry)) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture.flac")
        let size = comments.count
        var data = Data("fLaC".utf8); data.append(contentsOf: [0x84, UInt8(size >> 16), UInt8((size >> 8) & 255), UInt8(size & 255)]); data.append(comments)
        try data.write(to: file)
        let tags = try AudioFileTags.read(file)
        let repaired = TrackIdentity.resolve(track(title: "001-Old - 123456789", artist: "未知歌手"), tags: tags)
        XCTAssertEqual(repaired.title, "测试の歌"); XCTAssertEqual(repaired.artist, "歌手"); XCTAssertEqual(repaired.trackNumber, 3)
        XCTAssertEqual(LyricsParser.lrc(tags.text("LYRICS")!).first?.start, 1)
        XCTAssertThrowsError(try AudioFileTags.comments(Data([255, 255, 255, 127])))
        XCTAssertEqual(TrackIdentity.cleanFilenameTitle("01. Example - 123456789"), "Example")
        XCTAssertEqual(TrackIdentity.cleanFilenameTitle("008-Example (Live)"), "Example (Live)")
    }
    func testMatchingRejectsOtherVersionsButManualSearchCanChooseThem() {
        let target = track()
        let base = Lyrics(source: "fixture", title: "Example", artist: "Singer", duration: 180, lines: LyricsParser.lrc("[00:01.00]Example"))
        XCTAssertGreaterThan(LyricsMatching.score(base, track: target), 0.8)
        var other = base; other.title = "Example (Live)"; other.titleAliases = ["Example"]
        XCTAssertEqual(LyricsMatching.score(other, track: target), 0)
        XCTAssertEqual(LyricsMatching.ranked([other], track: target, manual: false).count, 0)
        XCTAssertEqual(LyricsMatching.ranked([other], track: target, manual: true).count, 1)
        other = base; other.artist = "Another Singer"; other.duration = 240
        XCTAssertEqual(LyricsMatching.score(other, track: target), 0)
        other.duration = 180
        XCTAssertEqual(LyricsMatching.score(other, track: target), 0, "Substring overlap must not bind another singer")
        other = base; other.title = "Example (Cover)"
        XCTAssertGreaterThan(LyricsMatching.score(other, track: target), 0.8, "Same performer and duration can use a provider's optional Cover label")
        let unknown = track(artist: "未知歌手")
        XCTAssertEqual(LyricsMatching.score(base, track: unknown), 0, "An empty or unknown artist must not match all recordings")
    }
    func testProvidersSurviveBrokenCandidateAndLRCLIBExactMiss() async {
        let service = service(); let target = track()
        let netease = await service.source("网易云", track: target)
        XCTAssertEqual(netease.candidates.count, 1, netease.detail)
        XCTAssertEqual(netease.candidates.first?.quality, 1)
        let lrc = await service.source("LRCLIB", track: target)
        XCTAssertEqual(lrc.candidates.count, 1, lrc.detail)
        let qq = await service.source("QQ 音乐", track: target)
        XCTAssertTrue(qq.detail.contains("403"), qq.detail)
        let manual = await service.source("LRCLIB", track: track(title: "Incorrect stored tag"), keyword: "Singer Example")
        XCTAssertEqual(manual.candidates.count, 1)
    }
    @MainActor func testLyricsControllerAutoLoadsAndRetainsManualBinding() async throws {
        try Paths.prepare()
        let target = track(); let cache = Paths.lyrics.appendingPathComponent(target.id + ".json")
        defer { try? FileManager.default.removeItem(at: cache) }
        let controller = LyricsController(service: service())
        controller.load(target)
        for _ in 0..<100 { if !controller.loading { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(controller.current); XCTAssertEqual(controller.sourceReports.count, 4)
        let manual = Lyrics(source: "手动", title: "Alternate spelling", artist: "Singer", duration: 180, lines: LyricsParser.lrc("[00:01.00]Bound lyric"))
        controller.select(manual)
        let restored = LyricsController(service: service()); restored.load(target)
        for _ in 0..<100 { if !restored.loading { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(restored.current?.title, manual.title); XCTAssertEqual(restored.current?.pinned, true)
        XCTAssertTrue(restored.sourceReports.isEmpty)
    }
    @MainActor func testBatchPlaylistsRemovalAndDeletionStayConsistent() throws {
        try Paths.prepare()
        let folder = "BatchTest-\(UUID().uuidString)"
        let dbFile = Paths.support.appendingPathComponent(folder + ".sqlite")
        let db = try Database(url: dbFile); let library = LibraryStore(database: db)
        let root = Paths.music.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbFile.path + suffix) }
        }
        let a = track(path: folder + "/a.flac"), b = track(path: folder + "/b.flac"), c = track(path: folder + "/c.flac")
        for value in [a, b, c] { try Data(value.id.utf8).write(to: library.url(value)); try db.put(value, kind: "track", id: value.id) }
        library.reload()
        let first = Playlist(name: "First"), second = Playlist(name: "Second")
        library.save(first); library.save(second)
        library.addTracks([b.id, a.id, b.id, "missing"], to: first.id)
        library.addTracks([a.id, b.id, c.id], to: second.id)
        XCTAssertEqual(library.playlists.first { $0.id == first.id }?.trackIDs, [b.id, a.id])
        library.removeTracks([a.id], from: first.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.url(a).path))
        XCTAssertEqual(LibraryScope.playlist(first.id).tracks(in: library).map(\.id), [b.id])
        library.setFavorite([a.id, b.id], value: true)
        XCTAssertEqual(Set(library.tracks.filter(\.favorite).map(\.id)), [a.id, b.id])
        // Failure must roll back both playlist/index updates and staged original files.
        try db.execute("CREATE TRIGGER reject_track_delete BEFORE DELETE ON records WHEN OLD.kind='track' BEGIN SELECT RAISE(ABORT, 'test rollback'); END;")
        XCTAssertFalse(library.deleteTracks([a.id, b.id]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.url(a).path))
        XCTAssertEqual(library.tracks.count, 3)
        try db.execute("DROP TRIGGER reject_track_delete;")
        XCTAssertTrue(library.deleteTracks([a.id, b.id]))
        XCTAssertEqual(library.tracks.map(\.id), [c.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.url(a).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.url(c).path))
        XCTAssertTrue(library.playlists.first { $0.id == first.id }!.trackIDs.isEmpty)
        XCTAssertEqual(library.playlists.first { $0.id == second.id }?.trackIDs, [c.id])
    }
    func testLiveLyricsOnNativeURLSession() async {
        let service = LyricsService()
        for (title, artist, duration) in [("迷星叫", "MyGO!!!!!", 211.373), ("踊り子", "Vaundy", 229.328), ("劣等上等", "RAISE A SUILEN", 138.816)] {
            var sample = track(path: "Sample.flac", title: title, artist: artist); sample.duration = duration
            async let netease = service.source("网易云", track: sample)
            async let kugou = service.source("酷狗", track: sample)
            async let lrclib = service.source("LRCLIB", track: sample)
            async let qq = service.source("QQ 音乐", track: sample)
            let results = await [netease, kugou, lrclib, qq]
            for result in results { print("Live lyrics \(title) / \(result.source): \(result.detail); qualities=\(result.candidates.map(\.quality))") }
            XCTAssertTrue(results.contains { !$0.candidates.isEmpty }, results.map { "\(title) / \($0.source): \($0.detail)" }.joined(separator: "; "))
        }
    }
}
