import XCTest
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
}
