import XCTest

final class BrowserScriptingUITests: CalyxUITestCase {

    private var cmdCounter = 0

    private func paletteRun(_ query: String, buttonTitle: String = "OK") {
        openCommandPaletteViaMenu()
        let sf = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.searchField").firstMatch
        XCTAssertTrue(waitFor(sf), "palette search field not found")
        sf.typeText(query)
        Thread.sleep(forTimeInterval: 0.5)
        sf.typeKey(.enter, modifierFlags: [])
        let dlg = app.dialogs.firstMatch
        if dlg.waitForExistence(timeout: 5) {
            dlg.buttons[buttonTitle].click()
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Paste a command into the terminal via Cmd+V (bypasses IME), run it, read output from file.
    private func terminalExec(_ command: String) -> String {
        cmdCounter += 1
        let outFile = "/tmp/calyx-e2e-\(cmdCounter).txt"
        try? FileManager.default.removeItem(atPath: outFile)

        Thread.sleep(forTimeInterval: 1)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("\(command) > \(outFile) 2>&1", forType: .string)
        app.typeKey("v", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.return, modifierFlags: [])

        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.5)
            if FileManager.default.fileExists(atPath: outFile),
               let content = try? String(contentsOfFile: outFile, encoding: .utf8),
               !content.isEmpty {
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return (try? String(contentsOfFile: outFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(no output)"
    }

    func test_mcpToolsWorkEndToEnd() {
        // BrowserServer auto-starts, no enable step needed

        // 1. Open browser tab
        menuAction("File", item: "New Browser Tab")
        let dlg = app.dialogs.firstMatch
        XCTAssertTrue(dlg.waitForExistence(timeout: 5), "URL dialog missing")
        let tf = dlg.textFields.firstMatch
        if tf.waitForExistence(timeout: 2) {
            tf.click()
            tf.typeKey("a", modifierFlags: .command) // select all
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString("https://example.com", forType: .string)
            tf.typeKey("v", modifierFlags: .command) // paste
        }
        dlg.buttons["Open"].click()

        let toolbar = app.descendants(matching: .any)
            .matching(identifier: "calyx.browser.toolbar").firstMatch
        XCTAssertTrue(waitFor(toolbar, timeout: 15), "browser toolbar missing")
        Thread.sleep(forTimeInterval: 3)

        // 4. Switch back to terminal tab (Cmd+1)
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1)

        // 5. calyx browser list — get tab_id
        let list = terminalExec("calyx browser list")
        XCTAssertTrue(list.contains("example.com"), "browser list should contain example.com, got: \(list)")

        // Extract tab_id from JSON output
        let tabId: String = {
            guard let data = list.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tabs = json["tabs"] as? [[String: Any]],
                  let first = tabs.first,
                  let id = first["id"] as? String else { return "" }
            return id
        }()
        XCTAssertFalse(tabId.isEmpty, "should extract tab_id from list output")

        // 6. calyx browser get-text h1 --tab-id <id>
        let getText = terminalExec("calyx browser get-text h1 --tab-id \(tabId)")
        XCTAssertTrue(getText.contains("Example Domain"), "get-text should contain Example Domain, got: \(getText)")

        // 7. calyx browser snapshot --tab-id <id>
        let snap = terminalExec("calyx browser snapshot --tab-id \(tabId)")
        XCTAssertFalse(snap.isEmpty, "snapshot should not be empty")

        // 8. calyx browser get-html h1 --tab-id <id>
        let getHTML = terminalExec("calyx browser get-html h1 --tab-id \(tabId)")
        XCTAssertTrue(getHTML.contains("<h1"), "get-html should contain h1 tag, got: \(getHTML.prefix(200))")

        // 9. calyx browser eval (before any navigation changes the page)
        let eval = terminalExec("calyx browser eval \"document.title\" --tab-id \(tabId)")
        XCTAssertTrue(eval.contains("Example Domain"), "eval should return 'Example Domain', got: [\(eval)]")

        // 10. calyx browser click a --tab-id <id>
        let click = terminalExec("calyx browser click a --tab-id \(tabId)")
        XCTAssertTrue(click.contains("clicked"), "click should return 'clicked', got: \(click)")

        // 11. calyx browser navigate --tab-id <id> (go back to example.com after click navigated away)
        let nav = terminalExec("calyx browser navigate https://example.com --tab-id \(tabId)")
        XCTAssertTrue(nav.contains("Navigated"), "navigate should return 'Navigated', got: \(nav)")
        Thread.sleep(forTimeInterval: 3)

        // 12. calyx browser back --tab-id <id>
        let back = terminalExec("calyx browser back --tab-id \(tabId)")
        XCTAssertTrue(back.contains("back"), "back should return 'back', got: \(back)")

        // 13. calyx browser forward --tab-id <id>
        let forward = terminalExec("calyx browser forward --tab-id \(tabId)")
        XCTAssertTrue(forward.contains("forward"), "forward should return 'forward', got: \(forward)")

        // 14. calyx browser reload --tab-id <id>
        let reload = terminalExec("calyx browser reload --tab-id \(tabId)")
        XCTAssertTrue(reload.contains("Reloaded"), "reload should return 'Reloaded', got: \(reload)")
        Thread.sleep(forTimeInterval: 3)

        // 15. calyx browser screenshot --tab-id <id>
        let screenshot = terminalExec("calyx browser screenshot --tab-id \(tabId)")
        XCTAssertTrue(screenshot.contains("/tmp/") || screenshot.contains("path"), "screenshot should return file path, got: \(screenshot)")

        // 16. calyx browser wait --selector h1 --tab-id <id>
        let wait = terminalExec("calyx browser wait --selector h1 --tab-id \(tabId)")
        XCTAssertFalse(wait.contains("Error"), "wait should not error, got: \(wait)")

        // 17-22: Form interaction tests — navigate to a page with form elements
        let _ = terminalExec("calyx browser navigate https://httpbin.org/forms/post --tab-id \(tabId)")
        Thread.sleep(forTimeInterval: 3)

        // 18. fill (httpbin form has input[name=custname])
        let fill = terminalExec("calyx browser fill input --value hello --tab-id \(tabId)")
        XCTAssertTrue(fill.contains("filled"), "fill should return 'filled', got: \(fill)")

        // 19. type
        let typeCmd = terminalExec("calyx browser type world --tab-id \(tabId)")
        XCTAssertTrue(typeCmd.contains("typed"), "type should return 'typed', got: \(typeCmd)")

        // 20. press
        let press = terminalExec("calyx browser press Tab --tab-id \(tabId)")
        XCTAssertTrue(press.contains("pressed"), "press should return 'pressed', got: \(press)")

        // 21. check (httpbin form has checkboxes)
        let check = terminalExec("calyx browser check 'input[type=checkbox]' --tab-id \(tabId)")
        XCTAssertTrue(check.contains("checked"), "check should return 'checked', got: \(check)")

        // 22. uncheck
        let uncheck = terminalExec("calyx browser uncheck 'input[type=checkbox]' --tab-id \(tabId)")
        XCTAssertTrue(uncheck.contains("unchecked"), "uncheck should return 'unchecked', got: \(uncheck)")

        // 24. calyx browser open (opens new tab)
        let open = terminalExec("calyx browser open https://example.com")
        XCTAssertTrue(open.contains("tab_id"), "open should return tab_id, got: \(open)")
    }

    func test_newBrowserCommands() {
        // 1. Open browser tab
        menuAction("File", item: "New Browser Tab")
        let dlg = app.dialogs.firstMatch
        XCTAssertTrue(dlg.waitForExistence(timeout: 5), "URL dialog missing")
        let tf = dlg.textFields.firstMatch
        if tf.waitForExistence(timeout: 2) {
            tf.click()
            tf.typeKey("a", modifierFlags: .command)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString("https://example.com", forType: .string)
            tf.typeKey("v", modifierFlags: .command)
        }
        dlg.buttons["Open"].click()

        let toolbar = app.descendants(matching: .any)
            .matching(identifier: "calyx.browser.toolbar").firstMatch
        XCTAssertTrue(waitFor(toolbar, timeout: 15), "browser toolbar missing")
        Thread.sleep(forTimeInterval: 3)

        // 2. Switch to terminal tab
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1)

        // 3. Get tab_id
        let list = terminalExec("calyx browser list")
        XCTAssertTrue(list.contains("example.com"), "browser list should contain example.com, got: \(list)")
        let tabId: String = {
            guard let data = list.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tabs = json["tabs"] as? [[String: Any]],
                  let first = tabs.first,
                  let id = first["id"] as? String else { return "" }
            return id
        }()
        XCTAssertFalse(tabId.isEmpty, "should extract tab_id")

        // 4. Inject test fixtures
        let inject = terminalExec("calyx browser eval \"document.body.innerHTML += '<input id=\\\"test-input\\\" name=\\\"email\\\" placeholder=\\\"Enter email\\\" value=\\\"hello\\\"><a href=\\\"https://test.com\\\" id=\\\"test-link\\\">Test Link</a><div id=\\\"hidden-el\\\" style=\\\"display:none\\\">hidden</div><div id=\\\"scrollbox\\\" style=\\\"height:100px;overflow:scroll\\\"><div style=\\\"height:1000px\\\">tall</div></div>'\" --tab-id \(tabId)")
        XCTAssertFalse(inject.contains("Error"), "inject should not error, got: \(inject)")
        Thread.sleep(forTimeInterval: 1)

        // 5. get-attribute: href on test-link
        let attr1 = terminalExec("calyx browser get-attribute '#test-link' href --tab-id \(tabId)")
        XCTAssertTrue(attr1.contains("test.com"), "get-attribute href should contain test.com, got: \(attr1)")

        // 6. get-attribute: name on test-input
        let attr2 = terminalExec("calyx browser get-attribute '#test-input' name --tab-id \(tabId)")
        XCTAssertTrue(attr2.contains("email"), "get-attribute name should contain email, got: \(attr2)")

        // 7. get-links
        let links = terminalExec("calyx browser get-links --tab-id \(tabId)")
        XCTAssertTrue(links.contains("test.com"), "get-links should contain test.com, got: \(links.prefix(300))")
        XCTAssertTrue(links.contains("iana.org"), "get-links should contain iana.org, got: \(links.prefix(300))")

        // 8. get-inputs
        let inputs = terminalExec("calyx browser get-inputs --tab-id \(tabId)")
        XCTAssertTrue(inputs.contains("test-input"), "get-inputs should contain test-input, got: \(inputs.prefix(300))")
        XCTAssertTrue(inputs.contains("email"), "get-inputs should contain email, got: \(inputs.prefix(300))")

        // 9. is-visible: visible element
        let vis1 = terminalExec("calyx browser is-visible h1 --tab-id \(tabId)")
        XCTAssertTrue(vis1.contains("true"), "is-visible h1 should be true, got: \(vis1)")

        // 10. is-visible: hidden element
        let vis2 = terminalExec("calyx browser is-visible '#hidden-el' --tab-id \(tabId)")
        XCTAssertTrue(vis2.contains("false"), "is-visible hidden-el should be false, got: \(vis2)")

        // 11. is-visible: nonexistent element
        let vis3 = terminalExec("calyx browser is-visible '#nonexistent' --tab-id \(tabId)")
        XCTAssertTrue(vis3.contains("false"), "is-visible nonexistent should be false, got: \(vis3)")

        // 12. hover
        let hover = terminalExec("calyx browser hover '#test-link' --tab-id \(tabId)")
        XCTAssertTrue(hover.contains("hovered"), "hover should return hovered, got: \(hover)")

        // 13. scroll down (window)
        let scroll1 = terminalExec("calyx browser scroll down --tab-id \(tabId)")
        XCTAssertTrue(scroll1.contains("scrolled"), "scroll down should contain scrolled, got: \(scroll1)")
        XCTAssertTrue(scroll1.contains("window"), "scroll down should target window, got: \(scroll1)")

        // 14. scroll up with amount
        let scroll2 = terminalExec("calyx browser scroll up --amount 100 --tab-id \(tabId)")
        XCTAssertTrue(scroll2.contains("scrolled"), "scroll up should contain scrolled, got: \(scroll2)")
    }

}
