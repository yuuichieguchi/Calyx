//
//  MCPAppHexColor.swift
//  Calyx
//
//  A validated sRGB color in hex form, the color type of
//  `MCPAppThemeInputs`.
//

import Foundation

struct MCPAppHexColor: Sendable, Equatable {
    /// Lowercase `#rrggbb`.
    let hex: String
    /// `0xrrggbb`.
    let rgb: UInt32

    /// Accepts `#rrggbb` or `rrggbb`, ASCII hex digits in either case.
    /// Anything else is nil.
    init?(_ text: String) {
        let digits = text.hasPrefix("#") ? text.dropFirst() : Substring(text)
        guard digits.count == 6,
              digits.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let rgb = UInt32(digits, radix: 16)
        else { return nil }
        self.hex = "#" + digits.lowercased()
        self.rgb = rgb
    }

    /// `rgb` is 0xrrggbb; bits above the low 24 are ignored.
    init(rgb: UInt32) {
        self.rgb = rgb & 0xFFFFFF
        self.hex = String(format: "#%06x", self.rgb)
    }
}
