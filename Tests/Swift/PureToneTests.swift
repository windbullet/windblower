import XCTest
import FlyingFox
import CryptoKit
@testable import PureTone

final class PureToneTests: XCTestCase {
    func testQRCNonstandardDESFixture() throws {
        let fixture = "d6a2be95d64473721b73c97024a81f859f2f04e93a26567ed8718ee4ddba458d82f510fa4eedeed7"
        XCTAssertEqual(try LyricsCipher.qrc(fixture), "[1000,2000]Hello(1000,500)world(1500,500)")
    }
    func testSafeUploadPaths() throws {
        XCTAssertEqual(try FileIntegrity.safeRelative("歌手/专辑/曲目.flac"), "歌手/专辑/曲目.flac")
        for path in ["../music.flac", "/music.flac", "C:\\Music\\a.mp3", "a//b.mp3", "a/./b", "a/../b"] { XCTAssertThrowsError(try FileIntegrity.safeRelative(path)) }
    }
    func testGenuineWordTimingParsers() {
        let yrc = LyricsParser.timed("[1000,2000](1000,500,0)你(1500,500,0)好", format: "yrc")
        XCTAssertEqual(yrc.first?.text, "你好"); XCTAssertEqual(yrc.first?.words.count, 2)
        XCTAssertEqual(yrc.first?.words.last?.start, 1.5)
        let krc = LyricsParser.timed("[1000,2000]<0,500,0>你<500,500,0>好", format: "krc")
        XCTAssertEqual(krc.first?.words.last?.start, 1.5)
        let qrc = LyricsParser.timed("[1000,2000]你(1000,500)好(1500,500)", format: "qrc")
        XCTAssertEqual(qrc.first?.text, "你好"); XCTAssertEqual(qrc.first?.words.last?.end, 2)
    }
    func testLineLyricsNeverInventWordTimes() {
        let lines = LyricsParser.lrc("[00:01.00]第一行\n[00:03.50]第二行")
        XCTAssertEqual(lines.count, 2); XCTAssertEqual(lines[0].end, 3.5); XCTAssertTrue(lines[0].words.isEmpty)
        XCTAssertEqual(LyricsParser.lrc("普通文字")[0].start, nil)
    }
    func testEQResponseComesFromNativeKernel() {
        var eq = EQConfiguration(); eq.enabled = true; eq.bands = [EQBand(frequency: 1000, q: 1, gain: 6)]
        XCTAssertEqual(eq.response(at: 1000, rate: 48000), 6, accuracy: 1e-8)
        eq.enabled = false; XCTAssertEqual(eq.response(at: 1000, rate: 48000), 0)
    }
    func testRestoreRejectsInvalidEQ() throws {
        var eq = EQConfiguration(); try eq.validate()
        eq.bands = []; XCTAssertThrowsError(try eq.validate())
        eq = EQConfiguration(); eq.preamp = 25; XCTAssertThrowsError(try eq.validate())
        eq = EQConfiguration(); eq.bands[0].q = .nan; XCTAssertThrowsError(try eq.validate())
    }
    func testNyquistClampAndNarrowCurveUseAppliedDesign() {
        var eq = EQConfiguration(); eq.enabled = true
        eq.bands = [EQBand(kind: .notch, frequency: 19_997, q: 30)]
        XCTAssertTrue(eq.curveFrequencies(rate: 44_100).contains(19_997))
        let maximum = EQConfiguration.maximumFrequency(rate: 8_000)
        XCTAssertEqual(maximum, 3_984)
        XCTAssertEqual(eq.curveFrequencies(rate: 8_000).max(), maximum)
        var native = eq.native(rate: 8_000)
        XCTAssertEqual(native.bands.0.frequency, maximum)
        XCTAssertEqual(pt_eq_validate(&native, 8_000), 1)
    }
    @MainActor func testNativeUploadOffsetHashAndAtomicImport() async throws {
        try Paths.prepare()
        let folder = "PureToneTest-" + UUID().uuidString
        let dbURL = Paths.support.appendingPathComponent(folder + ".sqlite")
        let db = try Database(url: dbURL)
        let store = UploadStore(importer: ImportService(db: db), accessCode: "123456")
        let payload = Data("[00:01.00]原始歌词\n".utf8)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let relative = folder + "/歌手/曲目.lrc"
        func request(_ method: HTTPMethod, _ path: String, _ body: Data = Data(), offset: String? = nil) -> HTTPRequest {
            var headers: [HTTPHeader: String] = [.authorization: "Bearer 123456", .host: "localhost:8080", HTTPHeader("Origin"): "http://localhost:8080"]
            if let offset { headers[HTTPHeader("X-Upload-Offset")] = offset }
            return HTTPRequest(method: method, version: .http11, path: path, query: [], headers: headers, body: body)
        }
        let input = try JSONSerialization.data(withJSONObject: ["path": relative, "size": payload.count, "sha256": hash])
        let start = try await store.handle(request(.POST, "/api/uploads", input))
        let manifest = try JSONDecoder().decode(UploadManifest.self, from: try await start.bodyData)
        defer {
            try? FileManager.default.removeItem(at: Paths.music.appendingPathComponent(folder))
            for suffix in [".json", ".part", ".lrc"] { try? FileManager.default.removeItem(at: Paths.uploads.appendingPathComponent(manifest.id + suffix)) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.music.appendingPathComponent(relative).path))
        let rejected = try await store.handle(request(.PUT, "/api/uploads/" + manifest.id, payload, offset: "1"))
        XCTAssertEqual(rejected.statusCode, .conflict)
        _ = try await store.handle(request(.PUT, "/api/uploads/" + manifest.id, payload, offset: "0"))
        let completed = try await store.handle(request(.POST, "/api/uploads/" + manifest.id + "/complete"))
        let final = try JSONDecoder().decode(UploadManifest.self, from: try await completed.bodyData)
        XCTAssertTrue(final.completed)
        XCTAssertEqual(try Data(contentsOf: Paths.music.appendingPathComponent(relative)), payload)
    }
    @MainActor func testRemoteIOPlaybackAndActualRoute() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "original", withExtension: "flac"))
        let library = LibraryStore()
        let name = "PureTonePlaybackTest-" + UUID().uuidString + ".flac"
        let imported = try await library.importer.ingest(fixture, relative: name, move: false)
        let track = try XCTUnwrap(imported)
        let audio = AudioController(library: library)
        audio.configuration = EQConfiguration()
        defer {
            audio.stop()
            try? library.db.remove(kind: "track", id: track.id)
            try? library.db.remove(kind: "queue", id: "current")
            try? FileManager.default.removeItem(at: library.url(track))
        }
        audio.play([track], startingAt: track)
        for _ in 0..<200 {
            if audio.error != nil || audio.progress > 0.15 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(audio.error)
        XCTAssertFalse(audio.preparing)
        XCTAssertGreaterThan(audio.path.outputRate, 0)
        XCTAssertEqual(audio.path.clientRate, audio.path.outputRate)
        XCTAssertEqual(audio.path.remoteIORate, audio.path.outputRate)
        XCTAssertGreaterThan(audio.progress, 0.15, "RemoteIO must consume decoded PCM, not only prepare a player")
        var changed = EQConfiguration(); changed.enabled = true; changed.preamp = -12
        changed.bands = [EQBand(frequency: 1000, q: 1, gain: 6)]
        audio.configuration = changed
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if audio.error != nil || (!audio.transitioning && !audio.calibrating && audio.appliedConfiguration == changed) { break }
        }
        XCTAssertNil(audio.error)
        XCTAssertFalse(audio.calibrating)
        XCTAssertFalse(audio.transitioning, "Final calibrated revision must reach RemoteIO before reporting steady state")
        XCTAssertEqual(audio.appliedConfiguration, changed)
        audio.pause(); XCTAssertFalse(audio.playing)
    }
}
