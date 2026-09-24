//
//  MCPAppHostContextBuilderTests.swift
//  CalyxTests
//
//  MCPAppHostContextBuilder is pure (contract v2 §11.16): given an
//  Environment it produces the hostContext dictionary sent on
//  ui/initialize and, via diff, on every ui/notifications/host-context-changed.
//  The style variable KEY LIST is pinned by hand from the ext-apps SDK
//  v2.0.0 tag's src/spec.types.ts (McpUiStyleVariableKey), fetched and
//  counted directly from the tagged source, never sampled from an intended
//  implementation, and MUST stay exactly 76 entries matching that union
//  verbatim.
//
//  The output shape (toolInfo, theme, styles, displayMode,
//  availableDisplayModes, containerDimensions, locale, timeZone, platform,
//  deviceCapabilities) is pinned to the contract's own §11.16 JSON example,
//  which does not include userAgent or safeAreaInsets (Environment carries
//  no input for either), so their presence is not asserted here.
//

import XCTest
@testable import Calyx

final class MCPAppHostContextBuilderTests: XCTestCase {

    // Pinned verbatim from ext-apps v2.0.0 src/spec.types.ts's
    // McpUiStyleVariableKey union (76 members).
    private static let pinnedStyleVariableKeys: [String] = [
        "--color-background-primary",
        "--color-background-secondary",
        "--color-background-tertiary",
        "--color-background-inverse",
        "--color-background-ghost",
        "--color-background-info",
        "--color-background-danger",
        "--color-background-success",
        "--color-background-warning",
        "--color-background-disabled",
        "--color-text-primary",
        "--color-text-secondary",
        "--color-text-tertiary",
        "--color-text-inverse",
        "--color-text-ghost",
        "--color-text-info",
        "--color-text-danger",
        "--color-text-success",
        "--color-text-warning",
        "--color-text-disabled",
        "--color-border-primary",
        "--color-border-secondary",
        "--color-border-tertiary",
        "--color-border-inverse",
        "--color-border-ghost",
        "--color-border-info",
        "--color-border-danger",
        "--color-border-success",
        "--color-border-warning",
        "--color-border-disabled",
        "--color-ring-primary",
        "--color-ring-secondary",
        "--color-ring-inverse",
        "--color-ring-info",
        "--color-ring-danger",
        "--color-ring-success",
        "--color-ring-warning",
        "--font-sans",
        "--font-mono",
        "--font-weight-normal",
        "--font-weight-medium",
        "--font-weight-semibold",
        "--font-weight-bold",
        "--font-text-xs-size",
        "--font-text-sm-size",
        "--font-text-md-size",
        "--font-text-lg-size",
        "--font-heading-xs-size",
        "--font-heading-sm-size",
        "--font-heading-md-size",
        "--font-heading-lg-size",
        "--font-heading-xl-size",
        "--font-heading-2xl-size",
        "--font-heading-3xl-size",
        "--font-text-xs-line-height",
        "--font-text-sm-line-height",
        "--font-text-md-line-height",
        "--font-text-lg-line-height",
        "--font-heading-xs-line-height",
        "--font-heading-sm-line-height",
        "--font-heading-md-line-height",
        "--font-heading-lg-line-height",
        "--font-heading-xl-line-height",
        "--font-heading-2xl-line-height",
        "--font-heading-3xl-line-height",
        "--border-radius-xs",
        "--border-radius-sm",
        "--border-radius-md",
        "--border-radius-lg",
        "--border-radius-xl",
        "--border-radius-full",
        "--border-width-regular",
        "--shadow-hairline",
        "--shadow-sm",
        "--shadow-md",
        "--shadow-lg",
    ]

    private static func tool(name: String = "get_weather") -> MCPToolDefinition {
        try! MCPToolDefinition(raw: [
            "name": AnyCodable(name),
            "inputSchema": AnyCodable(["type": AnyCodable("object")])
        ])
    }

    private static func theme(lightBackground: String = "#ffffff", darkBackground: String = "#1e1e1e") -> MCPAppThemeInputs {
        MCPAppThemeInputs(
            lightBackground: color(lightBackground),
            lightForeground: color("#1d1d1f"),
            darkBackground: color(darkBackground),
            darkForeground: color("#f5f5f7"),
            accent: color("#0a64d6"),
            fontFamily: "JetBrains Mono",
            fontSize: 13
        )
    }

    /// Every literal passed here is a valid `#rrggbb`.
    private static func color(_ text: String) -> MCPAppHexColor {
        guard let color = MCPAppHexColor(text) else {
            preconditionFailure("test color literal \(text) is not #rrggbb")
        }
        return color
    }

    private func environment(
        toolRequestID: JSONRPCId? = .int(7),
        displayMode: String = "inline",
        availableDisplayModes: [String] = ["inline", "fullscreen", "pip"],
        containerDimensions: MCPAppDockLayout.ContainerDimensions = MCPAppDockLayout.ContainerDimensions(
            width: 480, height: 320, maxWidth: nil, maxHeight: nil
        ),
        theme: MCPAppThemeInputs = MCPAppHostContextBuilderTests.theme()
    ) -> MCPAppHostContextBuilder.Environment {
        MCPAppHostContextBuilder.Environment(
            toolRequestID: toolRequestID,
            tool: Self.tool(),
            isDarkTheme: false,
            displayMode: displayMode,
            availableDisplayModes: availableDisplayModes,
            containerDimensions: containerDimensions,
            locale: "en-US",
            timeZone: "America/Los_Angeles",
            appVersion: "0.42.0",
            theme: theme
        )
    }

    // MARK: - Pinned key list sanity (guards the fixture itself)

    func test_pinnedFixture_hasExactly76Keys_noDuplicates() {
        XCTAssertEqual(Self.pinnedStyleVariableKeys.count, 76)
        XCTAssertEqual(Set(Self.pinnedStyleVariableKeys).count, 76, "no duplicate keys in the pinned fixture")
    }

    // MARK: - Production key list matches the pinned fixture exactly

    func test_styleVariableKeys_matchesPinnedSDKFixtureExactly() {
        XCTAssertEqual(Set(MCPAppHostContextBuilder.styleVariableKeys), Set(Self.pinnedStyleVariableKeys))
        XCTAssertEqual(MCPAppHostContextBuilder.styleVariableKeys.count, 76)
    }

    // MARK: - Every style key present under styles.variables

    func test_buildHostContext_stylesVariables_containsEveryPinnedKey() throws {
        let context = MCPAppHostContextBuilder.buildHostContext(environment())
        let styles = try XCTUnwrap(context["styles"]?.objectValue)
        let variables = try XCTUnwrap(styles["variables"]?.objectValue)

        for key in Self.pinnedStyleVariableKeys {
            XCTAssertNotNil(variables[key], "missing style variable \(key)")
        }
    }

    // MARK: - Required top-level fields (contract §11.16 JSON example)

    func test_buildHostContext_includesAllRequiredTopLevelFields() throws {
        let context = MCPAppHostContextBuilder.buildHostContext(environment())

        for key in ["toolInfo", "theme", "styles", "displayMode", "availableDisplayModes",
                    "containerDimensions", "locale", "timeZone", "platform", "deviceCapabilities"] {
            XCTAssertNotNil(context[key], "hostContext missing required field \(key)")
        }
    }

    func test_buildHostContext_toolInfo_carriesRequestIDAndTool() throws {
        let context = MCPAppHostContextBuilder.buildHostContext(environment(toolRequestID: .int(7)))
        let toolInfo = try XCTUnwrap(context["toolInfo"]?.objectValue)

        XCTAssertEqual(toolInfo["id"]?.intValue, 7, "toolInfo.id is the JSON-RPC id of the tools/call request")
        let tool = try XCTUnwrap(toolInfo["tool"]?.objectValue)
        XCTAssertEqual(tool["name"]?.stringValue, "get_weather")
    }

    func test_buildHostContext_toolInfo_numericZeroID_isNotDroppedAsMissing() throws {
        // 0 is a valid JSONRPCId (contract-wide decision, Wire §1.3); the
        // builder must not treat it as "no id".
        let context = MCPAppHostContextBuilder.buildHostContext(environment(toolRequestID: .int(0)))
        let toolInfo = try XCTUnwrap(context["toolInfo"]?.objectValue)
        XCTAssertEqual(toolInfo["id"]?.intValue, 0)
    }

    func test_buildHostContext_locale_timeZone_displayMode_areEchoedVerbatim() throws {
        let context = MCPAppHostContextBuilder.buildHostContext(environment(displayMode: "fullscreen"))
        XCTAssertEqual(context["locale"]?.stringValue, "en-US")
        XCTAssertEqual(context["timeZone"]?.stringValue, "America/Los_Angeles")
        XCTAssertEqual(context["displayMode"]?.stringValue, "fullscreen")
    }

    func test_buildHostContext_availableDisplayModes_echoedVerbatim() throws {
        let context = MCPAppHostContextBuilder.buildHostContext(environment(availableDisplayModes: ["inline", "fullscreen"]))
        let modes = try XCTUnwrap(context["availableDisplayModes"]?.arrayValue).compactMap { $0.stringValue }
        XCTAssertEqual(modes, ["inline", "fullscreen"])
    }

    func test_buildHostContext_platform_isDesktop() throws {
        let context = MCPAppHostContextBuilder.buildHostContext(environment())
        XCTAssertEqual(context["platform"]?.stringValue, "desktop")
    }

    func test_buildHostContext_containerDimensions_reflectsEnvironmentValue() throws {
        let dims = MCPAppDockLayout.ContainerDimensions(width: 480, height: 320, maxWidth: nil, maxHeight: nil)
        let context = MCPAppHostContextBuilder.buildHostContext(environment(containerDimensions: dims))
        let out = try XCTUnwrap(context["containerDimensions"]?.objectValue)
        XCTAssertEqual(out["width"]?.doubleValue, 480)
        XCTAssertEqual(out["height"]?.doubleValue, 320)
    }

    func test_buildHostContext_inlineDockDimensions_areAFixedWidthAndHeightWithoutMaximums() throws {
        let dims = MCPAppDockLayout.containerDimensions(
            mode: "inline", dockSize: CGSize(width: 320, height: 600), windowSize: CGSize(width: 1200, height: 800),
            tabTerminalRect: CGRect(x: 0, y: 0, width: 1200, height: 760), contentTopInset: 28
        )
        let context = MCPAppHostContextBuilder.buildHostContext(environment(containerDimensions: dims))
        let out = try XCTUnwrap(context["containerDimensions"]?.objectValue)

        XCTAssertEqual(out["width"]?.doubleValue, 320)
        XCTAssertEqual(out["height"]?.doubleValue, 572)
        XCTAssertNil(out["maxWidth"], "a fixed width is reported without maxWidth")
        XCTAssertNil(out["maxHeight"], "a fixed height is reported without maxHeight")
    }

    func test_buildHostContext_theme_reflectsIsDarkTheme() throws {
        let context = MCPAppHostContextBuilder.buildHostContext(environment())
        XCTAssertEqual(context["theme"]?.stringValue, "light")
    }

    // MARK: - Partial diffs

    func test_diff_onlyChangedTopLevelKeysAreIncluded() {
        let previous = MCPAppHostContextBuilder.buildHostContext(environment(displayMode: "inline"))
        let next = MCPAppHostContextBuilder.buildHostContext(environment(displayMode: "fullscreen"))

        let diff = MCPAppHostContextBuilder.diff(previous: previous, next: next)

        XCTAssertEqual(Set(diff.keys), ["displayMode"])
    }

    func test_diff_noChanges_isEmpty() {
        let context = MCPAppHostContextBuilder.buildHostContext(environment())
        let diff = MCPAppHostContextBuilder.diff(previous: context, next: context)
        XCTAssertTrue(diff.isEmpty)
    }

    func test_diff_multipleChangedKeys_allIncluded() {
        let previous = MCPAppHostContextBuilder.buildHostContext(environment(displayMode: "inline", availableDisplayModes: ["inline", "fullscreen", "pip"]))
        let next = MCPAppHostContextBuilder.buildHostContext(environment(displayMode: "fullscreen", availableDisplayModes: ["inline", "fullscreen"]))

        let diff = MCPAppHostContextBuilder.diff(previous: previous, next: next)

        XCTAssertEqual(Set(diff.keys), ["displayMode", "availableDisplayModes"])
    }

    // MARK: - Style variables come from the theme inputs

    func test_styleVariables_reflectThemeInputs() throws {
        let context = MCPAppHostContextBuilder.buildHostContext(environment(
            theme: Self.theme(lightBackground: "#fafafa", darkBackground: "#101418")
        ))
        let variables = try XCTUnwrap(context["styles"]?["variables"]?.objectValue)

        XCTAssertEqual(variables["--color-background-primary"]?.stringValue, "light-dark(#fafafa, #101418)",
                       "the primary background is the light and dark background inputs")
        XCTAssertEqual(variables["--font-mono"]?.stringValue?.hasPrefix("\"JetBrains Mono\""), true,
                       "the monospace font is the ghostty font family")
        XCTAssertEqual(variables["--font-text-md-size"]?.stringValue, "13px", "the base text size is the ghostty font size")
    }
}
