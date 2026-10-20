import Foundation

enum NotificationSanitizer {

    private static let maxGraphemeClusters = 256

    static func sanitize(_ text: String) -> String {
        truncated(strip(text))
    }

    static func sanitizeRedactingSecrets(_ text: String) -> String {
        truncated(SecretRedactor.redact(strip(text)))
    }

    private static func strip(_ text: String) -> String {
        let withoutBidi = removingBidiOverrides(text)
        let withoutControls = removingControlCharactersExceptNewlineAndTab(withoutBidi)
        let withoutZeroWidth = removingZeroWidthCharacters(withoutControls)
        let newlinesNormalized = collapsingAndTrimmingNewlines(withoutZeroWidth)
        return newlinesNormalized.precomposedStringWithCanonicalMapping
    }

    private static func removingBidiOverrides(_ text: String) -> String {
        text.replacing(/[\u{202A}-\u{202E}\u{2066}-\u{2069}]/, with: "")
    }

    private static func removingControlCharactersExceptNewlineAndTab(_ text: String) -> String {
        text.unicodeScalars.filter(isAllowedScalar).map { String($0) }.joined()
    }

    private static func isAllowedScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value == 0x09 || value == 0x0A { return true }
        if value <= 0x1F { return false }
        if value == 0x7F { return false }
        if value >= 0x80 && value <= 0x9F { return false }
        return true
    }

    private static func removingZeroWidthCharacters(_ text: String) -> String {
        text.replacing(/[\u{200B}-\u{200F}\u{FEFF}]/, with: "")
    }

    private static func collapsingAndTrimmingNewlines(_ text: String) -> String {
        text.replacing(/\n{2,}/, with: "\n").trimmingCharacters(in: .newlines)
    }

    private static func truncated(_ text: String) -> String {
        guard text.count > maxGraphemeClusters else { return text }
        return String(text.prefix(maxGraphemeClusters))
    }
}
