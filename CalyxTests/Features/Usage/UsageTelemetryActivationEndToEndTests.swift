//
//  UsageTelemetryActivationEndToEndTests.swift
//  CalyxTests
//
//  R4b end to end: the reconciler with fake INPUTS ("both on, server on
//  port P", then tracking off) and the REAL effects, pointed at a
//  temporary path root: a settings file under `<root>/.claude/`, a
//  credential directory under `<root>/credential`, and a fixture ledger
//  over `<root>`. The real home, Application Support and
//  UserDefaults.standard are never involved.
//
//  What `remove` takes out is R4a's committed rule and is not restated
//  here: these tests only pin that install then remove restores the file
//  byte for byte, and that a file with other telemetry settings is left
//  byte-identical throughout.
//

import XCTest
@testable import Calyx

@MainActor
final class UsageTelemetryActivationEndToEndTests: XCTestCase {

    private let port = 41831

    private let recorder = UsagePublishRecorder()
    private var fixtureStorage: UsageWiringFixture?
    private var ledgers: [UsageLedger] = []
    private var holderStorage: UsageIngestCredentialHolder?
    private var inputsStorage: UsageTelemetryFakeInputs?

    override func setUp() async throws {
        try await super.setUp()
        fixtureStorage = try UsageWiringFixture.make(label: "UsageTelemetryActivationEndToEndTests")
        holderStorage = UsageIngestCredentialHolder()
        let inputs = UsageTelemetryFakeInputs()
        inputs.trackingOn = true
        inputs.ipcEnabled = true
        inputs.serverPort = port
        inputs.mayTouchAgentFiles = true
        inputsStorage = inputs
    }

    override func tearDown() async throws {
        await fixtureStorage?.shutDown(ledgers)
        ledgers = []
        fixtureStorage = nil
        holderStorage = nil
        inputsStorage = nil
        try await super.tearDown()
    }

    private func theFixture() throws -> UsageWiringFixture {
        try XCTUnwrap(fixtureStorage, "Fixture error: no fixture")
    }

    private func theInputs() throws -> UsageTelemetryFakeInputs {
        try XCTUnwrap(inputsStorage, "Fixture error: no inputs")
    }

    /// The fixture's root; a path that cannot exist when setUp failed
    /// (the test body does not run then).
    private var basePath: String { fixtureStorage?.basePath ?? "/nonexistent/UsageTelemetryActivationEndToEndTests" }

    // MARK: - Helpers

    private var claudeDirectory: String { basePath + "/.claude" }
    private var settingsPath: String { claudeDirectory + "/settings.json" }
    private var credentialDirectory: String { basePath + "/credential" }
    private var headersFilePath: String { credentialDirectory + "/usage-otel-credential.json" }
    /// G5: the `bin` directory the test's effect installs `calyx-usage-headers` into.
    private var binDirectory: String { basePath + "/bin" }

    /// The reconciler with the real effects over this test's root.
    private func makeActivation() throws -> UsageTelemetryActivation {
        let holder = try XCTUnwrap(holderStorage, "Fixture error: no holder")
        let ledger = try theFixture().makeLedger(recorder: recorder)
        ledgers.append(ledger)
        let credentialDirectory = self.credentialDirectory
        let settingsPath = self.settingsPath
        let binDirectory = self.binDirectory
        let effects = UsageTelemetryActivation.Effects(
            syncTracking: { await ledger.syncTracking() },
            loadCredential: { create, rotateForGeneration in
                try await holder.load(create: create, directory: credentialDirectory, rotateForGeneration: rotateForGeneration)
            },
            install: { port in
                let helperPath = try UsageHeadersHelperScript.install(toDirectory: binDirectory)
                return try ClaudeUsageTelemetryConfigManager.install(
                    port: port, helperPath: helperPath, settingsPath: settingsPath)
            },
            remove: { try ClaudeUsageTelemetryConfigManager.remove(settingsPath: settingsPath) })
        return UsageTelemetryActivation(inputs: try theInputs().inputs, effects: effects, onStatusChange: {})
    }

    private func writeSettings(_ text: String) throws -> Data {
        try FileManager.default.createDirectory(atPath: claudeDirectory, withIntermediateDirectories: true)
        let data = Data(text.utf8)
        try data.write(to: URL(fileURLWithPath: settingsPath))
        return data
    }

    private func settingsBytes() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: settingsPath))
    }

    private func settingsObject() throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: settingsBytes()) as? [String: Any])
    }

    /// Runs `command` with /bin/sh and returns its standard output.
    private func runShell(_ command: String, environment: [String: String]? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        if let environment { process.environment = environment }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return data
    }

    /// A user's settings file: their own `env` member and hooks, in the
    /// layout they wrote it.
    private let userSettings = """
        {
          "env": {
            "MY_VAR": "mine"
          },
          "hooks": {
            "Stop": []
          },
          "model": "opus"
        }

        """

    // MARK: - Both on, then tracking off

    func test_bothOn_writesTheBlockForThePort_withAHelperThatPrintsTheCredentialFile() async throws {
        _ = try writeSettings(userSettings)
        let activation = try makeActivation()

        await activation.reconcile()

        XCTAssertEqual(activation.status, .installed(port: 41831))
        let root = try settingsObject()
        let env = try XCTUnwrap(root["env"] as? [String: Any])
        XCTAssertEqual(env["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"] as? String, "http://127.0.0.1:41831/usage/v1/metrics")
        XCTAssertEqual(env["CLAUDE_CODE_ENABLE_TELEMETRY"] as? String, "1")
        XCTAssertEqual(env["MY_VAR"] as? String, "mine")
        XCTAssertEqual(root["model"] as? String, "opus")
        let helper = try XCTUnwrap(root["otelHeadersHelper"] as? String)
        // G5: the quoted helper path and the port; no token in the settings file (J17).
        XCTAssertEqual(helper, "\"\(binDirectory)/calyx-usage-headers\" 41831")

        // The helper prints exactly the credential file, which exists
        // with mode 0600 and carries the token the route accepts, when a
        // live endpoint file for that port sits next to it.
        let headers = try Data(contentsOf: URL(fileURLWithPath: headersFilePath))
        try IPCWakeTestCrypto.writeEndpointFile(
            directory: credentialDirectory, port: 41831, token: String(repeating: "0123456789abcdef", count: 4),
            keyBytes: IPCWakeTestCrypto.randomKeyBytes())
        let helperEnvironment = [
            "HOME": basePath + "/emptyhome", "PATH": "/usr/bin:/bin",
            "CALYX_ENDPOINT_FILE": credentialDirectory + "/agent-endpoint.json",
        ]
        XCTAssertEqual(try runShell(helper, environment: helperEnvironment), headers)
        let attributes = try FileManager.default.attributesOfItem(atPath: headersFilePath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let holder = try XCTUnwrap(holderStorage)
        let credential = try XCTUnwrap(holder.credential, "the route's holder has the credential")
        XCTAssertEqual(credential.headersFilePath, headersFilePath)
        XCTAssertTrue(String(decoding: headers, as: UTF8.self).contains(credential.token))
    }

    func test_bothOn_thenTrackingOff_restoresTheSettingsFileByteForByte() async throws {
        let original = try writeSettings(userSettings)
        let activation = try makeActivation()
        await activation.reconcile()
        XCTAssertNotEqual(try settingsBytes(), original, "Fixture error: the block was not written")

        try theInputs().trackingOn = false
        await activation.reconcile()

        XCTAssertEqual(activation.status, .removed)
        XCTAssertEqual(try settingsBytes(), original)
    }

    func test_bothOn_thenIPCOff_restoresTheSettingsFileByteForByte() async throws {
        let original = try writeSettings(userSettings)
        let activation = try makeActivation()
        await activation.reconcile()

        try theInputs().ipcEnabled = false
        await activation.reconcile()

        XCTAssertEqual(activation.status, .removed)
        XCTAssertEqual(try settingsBytes(), original)
    }

    // The server stops (not running): the block stays exactly as written.
    func test_serverStops_leavesTheWrittenBlockUntouched() async throws {
        _ = try writeSettings(userSettings)
        let activation = try makeActivation()
        await activation.reconcile()
        let installed = try settingsBytes()

        try theInputs().serverPort = nil
        await activation.reconcile()

        XCTAssertEqual(try settingsBytes(), installed)
        XCTAssertEqual(activation.status, .installed(port: 41831))
    }

    // MARK: - Another collector's telemetry settings

    func test_otherTelemetrySettings_areLeftByteIdentical_onAndOff() async throws {
        let original = try writeSettings("""
            {
              "env": {
                "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": "http://collector.example:4318/v1/metrics"
              }
            }

            """)
        let activation = try makeActivation()

        await activation.reconcile()
        XCTAssertEqual(activation.status, .blocked(keys: ["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"]))
        XCTAssertEqual(try settingsBytes(), original)

        try theInputs().trackingOn = false
        await activation.reconcile()
        XCTAssertEqual(activation.status, .removed)
        XCTAssertEqual(try settingsBytes(), original)
    }

    // MARK: - Claude Code not set up

    func test_noClaudeDirectory_isClaudeNotFound_andCreatesNoSettings() async throws {
        let activation = try makeActivation()

        await activation.reconcile()

        XCTAssertEqual(activation.status, .claudeNotFound)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeDirectory))
    }

    // Tracking off from the start with no credential: nothing is created.
    func test_trackingOff_createsNoCredential_andNoSettings() async throws {
        try theInputs().trackingOn = false
        try theFixture().tracking.set(false)
        let activation = try makeActivation()

        await activation.reconcile()

        XCTAssertEqual(activation.status, .removed)
        XCTAssertNil(holderStorage?.credential)
        XCTAssertFalse(FileManager.default.fileExists(atPath: credentialDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeDirectory))
    }

    // MARK: - Tracking never on, settings reached through a symbolic link

    /// The dotfiles layout: `<root>/.claude/settings.json` is a symbolic
    /// link to `<root>/dotfiles/settings.json`, the user's own file
    /// (their `env` keys and hooks, no Calyx members, mode 0644, a fixed
    /// modification time).
    private var dotfilesDirectory: String { basePath + "/dotfiles" }
    private var dotfilesSettingsPath: String { dotfilesDirectory + "/settings.json" }
    private let fixedModificationDate = Date(timeIntervalSince1970: 1_600_000_000)

    private let dotfilesSettings = """
        {
          "env": {
            "EDITOR": "nvim",
            "DISABLE_AUTOUPDATER": "1"
          },
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "afplay /System/Library/Sounds/Glass.aiff" } ] }
            ]
          },
          "permissions": { "allow": ["Bash(git status)"] }
        }

        """

    private struct LinkedSettingsSnapshot: Equatable {
        let linkDestination: String
        let linkIsSymbolicLink: Bool
        let targetBytes: Data
        let targetMode: Int?
        let targetModificationDate: Date?
        let claudeListing: [String]
        let dotfilesListing: [String]
    }

    private func writeLinkedSettings() throws {
        let manager = FileManager.default
        try manager.createDirectory(atPath: dotfilesDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(atPath: claudeDirectory, withIntermediateDirectories: true)
        try Data(dotfilesSettings.utf8).write(to: URL(fileURLWithPath: dotfilesSettingsPath))
        try manager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644), .modificationDate: fixedModificationDate],
            ofItemAtPath: dotfilesSettingsPath)
        try manager.createSymbolicLink(atPath: settingsPath, withDestinationPath: dotfilesSettingsPath)
    }

    private func linkedSettingsSnapshot() throws -> LinkedSettingsSnapshot {
        let manager = FileManager.default
        let linkAttributes = try manager.attributesOfItem(atPath: settingsPath)
        let targetAttributes = try manager.attributesOfItem(atPath: dotfilesSettingsPath)
        return LinkedSettingsSnapshot(
            linkDestination: try manager.destinationOfSymbolicLink(atPath: settingsPath),
            linkIsSymbolicLink: (linkAttributes[.type] as? FileAttributeType) == .typeSymbolicLink,
            targetBytes: try Data(contentsOf: URL(fileURLWithPath: dotfilesSettingsPath)),
            targetMode: (targetAttributes[.posixPermissions] as? NSNumber)?.intValue,
            targetModificationDate: targetAttributes[.modificationDate] as? Date,
            claudeListing: try manager.contentsOfDirectory(atPath: claudeDirectory).sorted(),
            dotfilesListing: try manager.contentsOfDirectory(atPath: dotfilesDirectory).sorted())
    }

    /// Two reconciles with the real effects leave the linked file and both
    /// directories exactly as they were, the status `.removed`, and no
    /// credential.
    private func assertLinkedSettingsUntouched(
        trackingOn: Bool, ipcEnabled: Bool, serverPort: Int?, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try theFixture().tracking.set(trackingOn)
        let inputs = try theInputs()
        inputs.trackingOn = trackingOn
        inputs.ipcEnabled = ipcEnabled
        inputs.serverPort = serverPort
        try writeLinkedSettings()
        let before = try linkedSettingsSnapshot()
        XCTAssertTrue(before.linkIsSymbolicLink, "Fixture error", file: file, line: line)
        XCTAssertEqual(before.linkDestination, dotfilesSettingsPath, "Fixture error", file: file, line: line)
        XCTAssertEqual(before.targetMode, 0o644, "Fixture error", file: file, line: line)
        XCTAssertEqual(before.targetModificationDate, fixedModificationDate, "Fixture error", file: file, line: line)
        XCTAssertEqual(before.claudeListing, ["settings.json"], "Fixture error", file: file, line: line)
        XCTAssertEqual(before.dotfilesListing, ["settings.json"], "Fixture error", file: file, line: line)
        let activation = try makeActivation()

        await activation.reconcile()
        await activation.reconcile()

        XCTAssertEqual(try linkedSettingsSnapshot(), before, file: file, line: line)
        XCTAssertEqual(activation.status, .removed, file: file, line: line)
        XCTAssertNil(holderStorage?.credential, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: headersFilePath), file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: credentialDirectory), file: file, line: line)
    }

    func test_trackingNeverOn_linkedSettings_ipcOnServerRunning_areLeftExactlyAsTheyWere() async throws {
        try await assertLinkedSettingsUntouched(trackingOn: false, ipcEnabled: true, serverPort: port)
    }

    func test_trackingNeverOn_linkedSettings_ipcOff_areLeftExactlyAsTheyWere() async throws {
        try await assertLinkedSettingsUntouched(trackingOn: false, ipcEnabled: false, serverPort: port)
    }

    func test_trackingNeverOn_linkedSettings_serverNotRunning_areLeftExactlyAsTheyWere() async throws {
        try await assertLinkedSettingsUntouched(trackingOn: false, ipcEnabled: true, serverPort: nil)
    }
}
