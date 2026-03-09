// CalyxUITestCase.swift
// CalyxUITests
//
// Base class for all Calyx XCUITests with common helpers.

import XCTest

class CalyxUITestCase: XCTestCase {
    var app: XCUIApplication!
    private var sessionTempDir: String?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(en)"]

        let tempDir = NSTemporaryDirectory() + "CalyxUITests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: tempDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        sessionTempDir = tempDir
        app.launchEnvironment["CALYX_UITEST_SESSION_DIR"] = tempDir
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        if let dir = sessionTempDir {
            try? FileManager.default.removeItem(atPath: dir)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    func waitFor(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval = 5) {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        wait(for: [expectation], timeout: timeout)
    }

    func menuAction(_ menuName: String, item: String) {
        app.menuBars.menuBarItems[menuName].click()
        app.menuBars.menuItems[item].click()
    }

    func createNewTabViaMenu() {
        menuAction("File", item: "New Tab")
    }

    func closeTabViaMenu() {
        menuAction("File", item: "Close Tab")
    }

    func toggleSidebarViaMenu() {
        menuAction("View", item: "Toggle Sidebar")
    }

    func openCommandPaletteViaMenu() {
        menuAction("View", item: "Command Palette")
    }

    func countElements(matching prefix: String, excludingSuffix: String? = nil) -> Int {
        let predicate: NSPredicate
        if let suffix = excludingSuffix {
            predicate = NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier ENDSWITH %@", prefix, suffix)
        } else {
            predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        }
        return app.descendants(matching: .any)
            .matching(predicate)
            .count
    }

    func countTabBarTabs() -> Int {
        // Match exactly "calyx.tabBar.tab.<UUID>" and nothing else (no .closeButton suffix)
        let uuidPattern = "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
        let predicate = NSPredicate(format: "identifier MATCHES %@", "calyx\\.tabBar\\.tab\\.\(uuidPattern)")
        return app.descendants(matching: .any)
            .matching(predicate)
            .count
    }
}
