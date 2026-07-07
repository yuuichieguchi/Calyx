// CalyxUITestCase.swift
// CalyxUITests
//
// Base class for all Calyx XCUITests with common helpers.

import XCTest

class CalyxUITestCase: XCTestCase {
    var app: XCUIApplication!
    private var sessionTempDir: String?

    /// Override in subclasses to add extra launch arguments (e.g. UserDefaults overrides).
    var additionalLaunchArguments: [String] { [] }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(en)"] + additionalLaunchArguments

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

    /// Fixed scratch directory the team lead reads screenshots from by
    /// hand after a run -- NOT a general-purpose artifact location, so
    /// don't add unrelated files here. ONE level under `/tmp`,
    /// deliberately -- field-verified (not assumed) that this depth
    /// succeeds where a deeper, nested scratchpad path does not: the
    /// sandboxed runner failed an equivalent nested `mkdir` under the
    /// scratchpad with `NSCocoaErrorDomain Code=513 "Operation not
    /// permitted"`, while a one-level `/tmp/<name>` directory (the same
    /// depth `SessionBrowserAttachKillE2ETests`'s own per-test `homeDir`
    /// already succeeds at creating, see that file's `setUp()`) works.
    static let uiShotDir = "/tmp/cxshots"

    /// Saves a full-screen `XCUIScreen` screenshot (not a single
    /// element's, so window chrome/toolbar icons are visible exactly as
    /// a human eyeballing the result would see them) named `name`, via
    /// BOTH of two independent channels: (a) an `XCTAttachment`/`add(_:)`
    /// on the current test -- always succeeds, lands in the run's
    /// `.xcresult` regardless of sandboxing -- and (b) a raw PNG file
    /// under `uiShotDir`, a plain one-level `/tmp` path a human can open
    /// directly without extracting it from the `.xcresult` bundle first.
    /// (b) is a best-effort supplement, not a substitute for (a): if the
    /// write fails for any reason, this logs the failure and falls back
    /// to the attachment alone rather than failing the test over a
    /// diagnostic-only write.
    func saveScreenshot(name: String) {
        let screenshot = XCUIScreen.main.screenshot()

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let filePath = "\(Self.uiShotDir)/\(name).png"
        do {
            try FileManager.default.createDirectory(atPath: Self.uiShotDir, withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: filePath))
            print("[saveScreenshot] \"\(name)\": attached to test result AND wrote \(filePath)")
        } catch {
            print(
                "[saveScreenshot] \"\(name)\": attached to test result, but failed to " +
                "write \(filePath) (\(error)) -- see the test's XCTAttachment instead."
            )
        }
    }
}
