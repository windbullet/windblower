import XCTest

final class LibraryUITests: XCTestCase {
    @MainActor func testMultiselectAndPlaylistPlusUseExistingLibrary() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixtures"]; app.launch()
        let multi = app.buttons["多选"]
        XCTAssertTrue(multi.waitForExistence(timeout: 15)); multi.tap()
        app.buttons["全选"].tap()
        XCTAssertTrue(app.staticTexts["已选 3 首"].exists)
        app.buttons["添加到歌单"].tap()
        let destination = app.buttons.containing(.staticText, identifier: "测试歌单").firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 5)); destination.tap()
        app.buttons["完成"].tap()
        app.staticTexts["歌单"].firstMatch.tap()
        app.staticTexts["测试歌单"].firstMatch.tap()
        let addButton = app.buttons["从曲库添加歌曲"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5)); addButton.tap()
        XCTAssertTrue(app.navigationBars["从曲库添加"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "已添加").count, 3)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Playlist with library picker"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["取消"].tap()
    }
    @MainActor func testEQChartDisplaysReadOnlyLogarithmicResponse() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launch()
        let equalizer = app.staticTexts["参数均衡器"].firstMatch
        XCTAssertTrue(equalizer.waitForExistence(timeout: 15)); equalizer.tap()
        XCTAssertTrue(app.staticTexts["精确调整，保持透明"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["scope"].exists)
        let chart = app.otherElements["eq-response-plot"]
        XCTAssertTrue(chart.exists)
        XCTAssertTrue(chart.label.contains("对数频率"))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Read-only logarithmic EQ"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
