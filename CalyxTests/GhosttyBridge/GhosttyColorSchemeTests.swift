import AppKit
import Testing
import GhosttyKit
@testable import Calyx

@MainActor
@Suite("Ghostty Color Scheme Tests")
struct GhosttyColorSchemeTests {

    private func appearance(_ name: NSAppearance.Name) -> NSAppearance {
        NSAppearance(named: name)!
    }

    @Test func aquaMapsToLight() {
        #expect(GhosttyColorScheme.scheme(for: appearance(.aqua)) == GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    @Test func darkAquaMapsToDark() {
        #expect(GhosttyColorScheme.scheme(for: appearance(.darkAqua)) == GHOSTTY_COLOR_SCHEME_DARK)
    }

    @Test func vibrantDarkMapsToDark() {
        #expect(GhosttyColorScheme.scheme(for: appearance(.vibrantDark)) == GHOSTTY_COLOR_SCHEME_DARK)
    }

    @Test func highContrastDarkAquaMapsToDark() {
        #expect(GhosttyColorScheme.scheme(for: appearance(.accessibilityHighContrastDarkAqua)) == GHOSTTY_COLOR_SCHEME_DARK)
    }
}

@MainActor
private final class RecordingSchemeReceiver: GhosttyColorSchemeReceiving {
    private let log: SchemeCallLog
    private let name: String

    init(name: String, log: SchemeCallLog) {
        self.name = name
        self.log = log
    }

    func setColorScheme(_ scheme: ghostty_color_scheme_e) {
        log.calls.append((name, scheme))
    }
}

@MainActor
private final class SchemeCallLog {
    var calls: [(String, ghostty_color_scheme_e)] = []
}

@MainActor
@Suite("Ghostty Color Scheme Broadcaster Tests")
struct GhosttyColorSchemeBroadcasterTests {

    @Test func appSetterRunsOnceBeforeEveryReceiverWithSameScheme() {
        let log = SchemeCallLog()
        let receivers = [
            RecordingSchemeReceiver(name: "first", log: log),
            RecordingSchemeReceiver(name: "second", log: log),
            RecordingSchemeReceiver(name: "third", log: log),
        ]

        GhosttyColorSchemeBroadcaster.broadcast(
            GHOSTTY_COLOR_SCHEME_DARK,
            setAppScheme: { log.calls.append(("app", $0)) },
            receivers: receivers
        )

        #expect(log.calls.map(\.0) == ["app", "first", "second", "third"])
        #expect(log.calls.allSatisfy { $0.1 == GHOSTTY_COLOR_SCHEME_DARK })
    }

    @Test func lightSchemeReachesAppAndReceivers() {
        let log = SchemeCallLog()
        let receivers = [RecordingSchemeReceiver(name: "only", log: log)]

        GhosttyColorSchemeBroadcaster.broadcast(
            GHOSTTY_COLOR_SCHEME_LIGHT,
            setAppScheme: { log.calls.append(("app", $0)) },
            receivers: receivers
        )

        #expect(log.calls.map(\.0) == ["app", "only"])
        #expect(log.calls.allSatisfy { $0.1 == GHOSTTY_COLOR_SCHEME_LIGHT })
    }

    @Test func noReceiversStillSetsAppSchemeOnce() {
        let log = SchemeCallLog()

        GhosttyColorSchemeBroadcaster.broadcast(
            GHOSTTY_COLOR_SCHEME_DARK,
            setAppScheme: { log.calls.append(("app", $0)) },
            receivers: []
        )

        #expect(log.calls.map(\.0) == ["app"])
        #expect(log.calls.first?.1 == GHOSTTY_COLOR_SCHEME_DARK)
    }
}
