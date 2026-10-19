// DiffLayoutSettings.swift
// Calyx
//
// UserDefaults-backed diff view settings (layout preference, hide
// unchanged regions, ignore trim whitespace). Same "route every
// read/write through a private SettingsStore" shape as
// GitRefFilterSettings; see Calyx/Helpers/SettingsStore.swift for the
// test/production resolution rationale. Every setter posts
// `.diffLayoutSettingChanged` with the changed key under
// `changedKeyUserInfoKey`, so observers react only to the setting they own.

import CoreGraphics
import Foundation

/// The layout a diff tab actually renders.
enum DiffLayout: Sendable, Equatable {
    case inline
    case sideBySide
}

/// The persisted user choice (VS Code `renderSideBySide` +
/// `useInlineViewWhenSpaceIsLimited`).
enum DiffLayoutPreference: String, CaseIterable, Sendable {
    case automatic
    case inline
    case sideBySide

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .inline: return "Inline"
        case .sideBySide: return "Side by Side"
        }
    }

    /// Inline <-> side-by-side; `.automatic` counts as side-by-side.
    var toggledInline: DiffLayoutPreference {
        switch self {
        case .inline: return .sideBySide
        case .automatic, .sideBySide: return .inline
        }
    }
}

struct DiffLayoutSettings: Sendable {

    static let layoutPreferenceKey = "calyx.diff.layoutPreference"
    static let hideUnchangedRegionsKey = "calyx.diff.hideUnchangedRegions"
    static let ignoreTrimWhitespaceKey = "calyx.diff.ignoreTrimWhitespace"
    static let renderOverviewRulerKey = "calyx.diff.renderOverviewRuler"
    static let wordWrapKey = "calyx.diff.wordWrap"

    /// VS Code `renderSideBySideInlineBreakpoint`.
    static let sideBySideInlineBreakpoint: CGFloat = 900

    private static let settingsStore = SettingsStore()

    static func _testUseSuite(named name: String) {
        settingsStore.testUseSuite(named: name)
    }

    static func _testTeardownSuite(named name: String) {
        settingsStore.testTeardownSuite(named: name)
    }

    private static var store: UserDefaults {
        settingsStore.store
    }

    /// `.automatic` when nothing is saved or the saved raw value is unknown.
    static var preference: DiffLayoutPreference {
        get {
            guard let raw = store.string(forKey: layoutPreferenceKey),
                  let pref = DiffLayoutPreference(rawValue: raw)
            else {
                return .automatic
            }
            return pref
        }
        set {
            store.set(newValue.rawValue, forKey: layoutPreferenceKey)
            postChanged(key: layoutPreferenceKey)
        }
    }

    /// Default false (VS Code `hideUnchangedRegions.enabled`).
    static var hideUnchangedRegionsEnabled: Bool {
        get { store.object(forKey: hideUnchangedRegionsKey) as? Bool ?? false }
        set {
            store.set(newValue, forKey: hideUnchangedRegionsKey)
            postChanged(key: hideUnchangedRegionsKey)
        }
    }

    /// Default true (VS Code `ignoreTrimWhitespace`).
    static var ignoreTrimWhitespace: Bool {
        get { store.object(forKey: ignoreTrimWhitespaceKey) as? Bool ?? true }
        set {
            store.set(newValue, forKey: ignoreTrimWhitespaceKey)
            postChanged(key: ignoreTrimWhitespaceKey)
        }
    }

    /// Default true (VS Code `renderOverviewRuler`).
    static var renderOverviewRuler: Bool {
        get { store.object(forKey: renderOverviewRulerKey) as? Bool ?? true }
        set {
            store.set(newValue, forKey: renderOverviewRulerKey)
            postChanged(key: renderOverviewRulerKey)
        }
    }

    /// Default true (VS Code `diffEditor.wordWrap` inherits `on` here).
    static var wordWrap: Bool {
        get { store.object(forKey: wordWrapKey) as? Bool ?? true }
        set {
            store.set(newValue, forKey: wordWrapKey)
            postChanged(key: wordWrapKey)
        }
    }

    /// `.automatic` resolves to inline at or below the breakpoint
    /// (VS Code: `width <= breakpoint` -> inline).
    static func effectiveLayout(preference: DiffLayoutPreference, width: CGFloat) -> DiffLayout {
        switch preference {
        case .inline: return .inline
        case .sideBySide: return .sideBySide
        case .automatic: return width <= sideBySideInlineBreakpoint ? .inline : .sideBySide
        }
    }

    /// `userInfo` key of `.diffLayoutSettingChanged`: the defaults key that changed.
    static let changedKeyUserInfoKey = "key"

    private static func postChanged(key: String) {
        NotificationCenter.default.post(name: .diffLayoutSettingChanged, object: nil,
                                        userInfo: [changedKeyUserInfoKey: key])
    }
}
