import XCTest
@testable import Calyx

final class NotificationSanitizerTests: XCTestCase {

    func test_strips_bidi_overrides() {
        let input = "Hello\u{202A}World\u{202E}!"
        let result = NotificationSanitizer.sanitize(input)
        XCTAssertEqual(result, "HelloWorld!")
    }

    func test_strips_bidi_isolates() {
        let input = "\u{2066}test\u{2069}"
        let result = NotificationSanitizer.sanitize(input)
        XCTAssertEqual(result, "test")
    }

    func test_strips_control_chars_but_keeps_newline_and_tab() {
        let input = "Hello\tWorld\nLine2\u{01}\u{02}\u{7F}"
        let result = NotificationSanitizer.sanitize(input)
        XCTAssertEqual(result, "Hello\tWorld\nLine2")
    }

    func test_strips_c1_control_chars() {
        let input = "test\u{80}\u{9F}end"
        let result = NotificationSanitizer.sanitize(input)
        XCTAssertEqual(result, "testend")
    }

    func test_strips_zero_width_chars() {
        let input = "Hello\u{200B}World\u{FEFF}!"
        let result = NotificationSanitizer.sanitize(input)
        XCTAssertEqual(result, "HelloWorld!")
    }

    func test_nfc_normalization() {
        let decomposed = "e\u{0301}"
        let result = NotificationSanitizer.sanitize(decomposed)
        XCTAssertEqual(result, "\u{00E9}")
    }

    func test_truncation_at_256_grapheme_clusters() {
        let long = String(repeating: "a", count: 300)
        let result = NotificationSanitizer.sanitize(long)
        XCTAssertEqual(result.count, 256)
    }

    func test_newline_collapsing() {
        let input = "Hello\n\n\nWorld"
        let result = NotificationSanitizer.sanitize(input)
        XCTAssertEqual(result, "Hello\nWorld")
    }

    func test_strips_leading_trailing_newlines() {
        let input = "\n\nHello\n\n"
        let result = NotificationSanitizer.sanitize(input)
        XCTAssertEqual(result, "Hello")
    }

    func test_plain_text_unchanged() {
        let input = "Normal notification text"
        let result = NotificationSanitizer.sanitize(input)
        XCTAssertEqual(result, input)
    }

    func test_empty_string() {
        let result = NotificationSanitizer.sanitize("")
        XCTAssertEqual(result, "")
    }

    func test_emoji_preserved() {
        let input = "Build complete 🎉"
        let result = NotificationSanitizer.sanitize(input)
        XCTAssertEqual(result, "Build complete 🎉")
    }

    func test_sanitizeRedactingSecrets_zeroWidthSplitSecret_redacted() {
        let result = NotificationSanitizer.sanitizeRedactingSecrets("export API_\u{200B}KEY=abc123")
        XCTAssertEqual(result, "export API_KEY=[redacted]")
    }

    func test_sanitizeRedactingSecrets_githubTokenStraddlingCap_tokenBodyAbsentAndCapped() {
        let tokenBody = "iK2ZWeqhFWCEPyYngFb51yBMWXaSCrUZoL8g"
        let input = String(repeating: "x", count: 230) + " ghp_" + tokenBody
        let result = NotificationSanitizer.sanitizeRedactingSecrets(input)
        XCTAssertFalse(result.contains(String(tokenBody.prefix(12))))
        XCTAssertLessThanOrEqual(result.count, 256)
    }

    func test_sanitizeRedactingSecrets_jwtStraddlingCap_headerAndPayloadAbsent() {
        let jwtHeader = "eyJ" + "hbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        let jwtPayload = "eyJ" + "zdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ"
        let jwtSignature = "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        let fillerCount = 245 - (jwtHeader.count + jwtPayload.count + 2) - 1
        let input = String(repeating: "x", count: fillerCount) + " \(jwtHeader).\(jwtPayload).\(jwtSignature)"
        let result = NotificationSanitizer.sanitizeRedactingSecrets(input)
        XCTAssertFalse(result.contains(jwtHeader))
        XCTAssertFalse(result.contains(jwtPayload))
        XCTAssertLessThanOrEqual(result.count, 256)
    }

    func test_sanitizeRedactingSecrets_manyShortSecretsNearCap_capped() {
        let input = String(repeating: "TOKEN=x ", count: 31)
        let result = NotificationSanitizer.sanitizeRedactingSecrets(input)
        XCTAssertTrue(result.contains("TOKEN=[redacted]"))
        XCTAssertLessThanOrEqual(result.count, 256)
    }
}
