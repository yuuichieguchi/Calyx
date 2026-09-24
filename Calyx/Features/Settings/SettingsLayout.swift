//
//  SettingsLayout.swift
//  Calyx
//
//  The metrics and building blocks every Settings pane is laid out with:
//  the pane width and inset, the vertical gap between a pane's items, the
//  gap inside a label + control row and between buttons, the section
//  title and separator, and the 11pt status text of the AI Agent IPC
//  section. `SettingsWindowController` and `MCPServersSettingsView` both
//  build from here, so no pane carries its own spacing.
//

import AppKit

@MainActor
enum SettingsLayout {

    /// Fixed width for every pane so switching tabs only ever changes the
    /// window's height, matching standard macOS Settings behavior.
    static let paneWidth: CGFloat = 560
    /// Inset of a pane's content from every edge of the window.
    static let paneContentInset: CGFloat = 24
    /// Width available to a pane's content.
    static let contentWidth: CGFloat = paneWidth - 2 * paneContentInset
    /// Vertical gap between consecutive items of a pane: heading,
    /// description, rows, separators, and the lines inside a section.
    static let itemSpacing: CGFloat = 18
    /// Gap between a row's label and its control.
    static let controlSpacing: CGFloat = 12
    /// Gap between buttons in one row.
    static let buttonSpacing: CGFloat = 8
    /// Status and detail text under a row (the AI Agent IPC status).
    static let statusFont = NSFont.systemFont(ofSize: 11)

    /// A vertical, leading-aligned stack with `itemSpacing`.
    static func column(_ views: [NSView] = []) -> NSStackView {
        let stack = NSStackView()
        for view in views {
            stack.addArrangedSubview(view)
        }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = itemSpacing
        return stack
    }

    static func sectionTitleLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        return label
    }

    static func sectionDivider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }

    /// A label followed by its control.
    static func controlRow(label: String, control: NSView) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = controlSpacing
        stack.alignment = .centerY
        let text = NSTextField(labelWithString: label)
        text.setContentHuggingPriority(.required, for: .horizontal)
        stack.addArrangedSubview(text)
        stack.addArrangedSubview(control)
        return stack
    }

    /// Buttons in one row, left-aligned: a trailing empty view takes the
    /// remaining width.
    static func buttonRow(_ buttons: [NSView]) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = buttonSpacing
        row.alignment = .centerY
        for button in buttons {
            row.addArrangedSubview(button)
        }
        row.addArrangedSubview(NSView())
        return row
    }

    /// A rounded push button.
    static func button(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        return button
    }

    /// A wrapping status label at the content width. Set its text with
    /// `statusText(_:)`.
    static func statusLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = statusFont
        label.preferredMaxLayoutWidth = contentWidth
        return label
    }

    /// Renders `text`'s lines with the first line in `.labelColor` and
    /// every further line in `.secondaryLabelColor`, so a detail is
    /// visually distinguishable from the summary it follows.
    /// `NSTextField.attributedStringValue` does not fall back to the
    /// field's own `font`, so every segment (including the `"\n"`
    /// joiners) carries it explicitly. Also carries a word-wrapping
    /// paragraph style, since an attributed string does not inherit the
    /// field cell's own wrap mode.
    static func statusText(_ text: String) -> NSAttributedString {
        let font = statusFont
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        let lines = text.components(separatedBy: "\n")
        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: paragraphStyle]))
            }
            let color: NSColor = index == 0 ? .labelColor : .secondaryLabelColor
            result.append(NSAttributedString(
                string: line,
                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraphStyle]
            ))
        }
        return result
    }
}
