import XCTest

final class LauncherLayoutTests: XCTestCase {
    private func launch(signedIn: Bool, optionsResponse: String? = nil, gameFilesURL: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        let root = NSTemporaryDirectory() + "horizon-native-" + UUID().uuidString
        app.launchEnvironment = ["PREVIEW_SIGNED_IN": signedIn ? "1" : "0",
            "HORIZON_HOME": root + "/game", "HORIZON_LAUNCHER_HOME": root + "/launcher",
            "XDG_DATA_HOME": root + "/data", "XDG_CONFIG_HOME": root + "/config",
            "HORIZON_LAUNCHER_TRASH": root + "/trash", "HORIZON_LAUNCHER_CLIPBOARD": root + "/clipboard",
            "HORIZON_LAUNCHER_DESKTOP": root + "/desktop", "HORIZON_LAUNCHER_NO_SELF_UPDATE": "1", "HORIZON_NO_AUDIO": "1"]
        if let optionsResponse { app.launchEnvironment["PREVIEW_OPTIONS_RESPONSE"] = optionsResponse }
        if let gameFilesURL {
            app.launchEnvironment["PREVIEW_MISSING_FILES"] = "1"
            app.launchEnvironment["PREVIEW_GAME_FILES_URL"] = gameFilesURL
        }
        app.launch()
        XCTAssertTrue(app.buttons["launcher-play-button"].waitForExistence(timeout: 15))
        return app
    }
    func testFirstRunAutomaticallyDownloadsAndEnablesPlay() throws {
        guard let url = ProcessInfo.processInfo.environment["HORIZON_DOWNLOAD_FIXTURE_URL"] else {
            throw XCTSkip("Requires the loopback download fixture")
        }
        let app = launch(signedIn: false, gameFilesURL: url)
        let play = app.buttons["launcher-play-button"]
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        let ready = NSPredicate(format: "enabled == true AND label == 'Play'")
        expectation(for: ready, evaluatedWith: play)
        waitForExpectations(timeout: 20)
        XCTAssertFalse(app.staticTexts["Game files needed"].exists)
        XCTAssertFalse(app.alerts["Launcher UI preview"].exists, "Setup must not launch the game")
    }

    func testFirstRunDownloadFailureKeepsRetryAndManualFallbackAvailable() throws {
        guard let url = ProcessInfo.processInfo.environment["HORIZON_DOWNLOAD_FIXTURE_URL"] else {
            throw XCTSkip("Requires the loopback download fixture")
        }
        let app = launch(signedIn: false, gameFilesURL: url + "?fail=1")
        let failure = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '503'")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["launcher-play-button"].isEnabled)
        XCTAssertTrue(app.buttons["launcher-download-game-files"].isEnabled)
        app.buttons["Use a download link instead"].tap()
        XCTAssertTrue(app.staticTexts["Link"].firstMatch.waitForExistence(timeout: 5))
    }

    func testOversizedAutomaticArchiveStopsBeforeImport() throws {
        guard let url = ProcessInfo.processInfo.environment["HORIZON_DOWNLOAD_FIXTURE_URL"] else {
            throw XCTSkip("Requires the loopback download fixture")
        }
        let app = launch(signedIn: false, gameFilesURL: url + "?oversized=1")
        let failure = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '2 GiB'")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["launcher-play-button"].isEnabled)
        XCTAssertTrue(app.buttons["launcher-download-game-files"].isEnabled)
    }

    func testPhoneLayoutAndSignedInIdentity() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(signedIn: true)
        XCTAssertFalse(app.staticTexts["Jump back in"].exists)
        XCTAssertFalse(app.staticTexts["Meadow Valley"].exists)
        XCTAssertFalse(app.buttons["launcher-nav-worlds"].exists)
        XCTAssertFalse(app.buttons["launcher-nav-servers"].exists)
        let play = app.buttons["launcher-play-button"]
        XCTAssertTrue(play.isHittable)
        XCTAssertLessThanOrEqual(play.frame.maxX, app.frame.maxX)
        XCTAssertGreaterThanOrEqual(play.frame.minX, 0)
        XCTAssertGreaterThanOrEqual(play.frame.height, 44)
        app.buttons["launcher-account-button"].tap()
        XCTAssertTrue(app.staticTexts["Microsoft account"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Change Offline Name"].exists)
        app.buttons["Done"].tap()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Native-launcher"; shot.lifetime = .keepAlways; add(shot)
    }
    func testOfflineNameEditing() {
        let app = launch(signedIn: false)
        app.buttons["launcher-account-button"].tap()
        let edit = app.buttons["Change Offline Name"]
        let field = app.textFields["offline-player-name"]
        func openEditor() {
            XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
            XCTAssertTrue(field.waitForExistence(timeout: 5))
        }
        openEditor()
        field.doubleTap(); field.typeText("TrailRider")
        XCTAssertEqual(field.value as? String, "TrailRider")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["TrailRider"].firstMatch.waitForExistence(timeout: 5))

        openEditor()
        XCTAssertEqual(field.value as? String, "TrailRider")
        field.tap(); field.typeText("_x")
        app.buttons["Cancel"].tap()

        openEditor()
        XCTAssertEqual(field.value as? String, "TrailRider")
        field.doubleTap(); field.typeText("Bad Name")
        XCTAssertEqual(field.value as? String, "Bad Name")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["offline-player-name-error"].waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Bad Name")
        app.buttons["Cancel"].tap()
        openEditor()
        XCTAssertEqual(field.value as? String, "TrailRider")
        app.buttons["Cancel"].tap()
    }
    func testSettingsShowFailureAndRetry() {
        let app = launch(signedIn: false, optionsResponse: "error")
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Game files"].waitForExistence(timeout: 8))
        app.swipeUp()
        XCTAssertTrue(app.buttons["settings-retry"].waitForExistence(timeout: 8))
    }

    func testGameSettingsAreEditable() {
        let app = launch(signedIn: false)
        app.tabBars.buttons["Settings"].tap()
        app.swipeUp()
        let autoJump = app.switches["setting-autoJump"]
        for _ in 0..<5 where !autoJump.isHittable { app.swipeUp() }
        XCTAssertTrue(autoJump.waitForExistence(timeout: 8))
        let old = autoJump.value as? String
        autoJump.tap()
        XCTAssertNotEqual(autoJump.value as? String, old)
        app.tabBars.buttons["Play"].tap()
        app.tabBars.buttons["Settings"].tap()
        for _ in 0..<5 where !autoJump.isHittable { app.swipeUp() }
        XCTAssertNotEqual(autoJump.value as? String, old)
    }

    func testWorldAndServerPagesAreAvailableFromPlay() {
        let app = launch(signedIn: false)
        app.swipeUp()
        let worlds = app.buttons["launcher-worlds"]
        XCTAssertTrue(worlds.waitForExistence(timeout: 8))
        worlds.tap()
        XCTAssertTrue(app.buttons["import-world"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["new-world-button"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.swipeUp()
        app.buttons["launcher-servers"].tap()
        XCTAssertTrue(app.staticTexts["Saved servers"].waitForExistence(timeout: 8))
    }

    func testTouchEditorShowsAndSavesControls() {
        let app = launch(signedIn: false)
        app.tabBars.buttons["Settings"].tap()
        let open = app.buttons["touch-editor-open"]
        for _ in 0..<5 where !open.isHittable { app.swipeUp() }
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        open.tap()
        XCTAssertTrue(app.otherElements["touch-layout-preview"].waitForExistence(timeout: 8))
        let opacity = app.sliders["touch-opacity"]
        for _ in 0..<3 where !opacity.isHittable { app.swipeUp() }
        XCTAssertTrue(opacity.exists)
        opacity.adjust(toNormalizedSliderPosition: 0.5)
        let save = app.buttons["touch-save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(open.waitForExistence(timeout: 8))
    }

    func testNativeTabBarHasOnlyThreeDestinationsAndNavigates() {
        let app = launch(signedIn: false)
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertEqual(bar.buttons.count, 3)
        XCTAssertFalse(bar.buttons["Worlds"].exists)
        XCTAssertFalse(bar.buttons["Servers"].exists)
        XCTAssertFalse(app.otherElements["launcher-floating-dock"].exists)
        XCTAssertFalse(app.staticTexts["All Worlds"].exists)
        XCTAssertFalse(app.staticTexts["Jump back in"].exists)
        for page in ["Packs", "Settings", "Play"] {
            let button = bar.buttons[page]
            XCTAssertTrue(button.isHittable); button.tap()
            XCTAssertTrue(bar.buttons[page].isSelected)
        }
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Native three-tab navigation"; image.lifetime = .keepAlways; add(image)
    }

    func testAccountControlIsCircularAndLibraryRoutesAreAbsent() {
        let app = launch(signedIn: true)
        let avatar = app.buttons["launcher-account-button"]
        XCTAssertTrue(avatar.isHittable)
        XCTAssertEqual(avatar.frame.width, avatar.frame.height, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(avatar.frame.width, 44)
        XCTAssertLessThanOrEqual(avatar.frame.width, 54)
        XCTAssertFalse(app.buttons["launcher-nav-worlds"].exists)
        XCTAssertFalse(app.buttons["launcher-nav-servers"].exists)
        XCTAssertFalse(app.staticTexts["Jump back in"].exists)
        XCTAssertFalse(app.staticTexts["All Worlds"].exists)
        XCTAssertFalse(app.buttons["new-world-button"].exists)
        avatar.tap()
        XCTAssertTrue(app.staticTexts["Microsoft account"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Change Offline Name"].exists)
    }

}
