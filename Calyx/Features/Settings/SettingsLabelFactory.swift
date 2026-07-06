//
//  SettingsLabelFactory.swift
//  Calyx
//
//  Single construction path for Settings description labels. NSTextField(
//  labelWithString:) defaults lineBreakMode to .byClipping; setting only
//  maximumNumberOfLines = 0 afterwards does not change that default, so a
//  long description still clips instead of wrapping. This factory sets
//  both properties together so every pane's description labels wrap.
//

import AppKit

@MainActor
enum SettingsLabelFactory {
    static func descriptionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 13)
        return label
    }
}
