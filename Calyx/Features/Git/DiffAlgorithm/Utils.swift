// Utils.swift
// Calyx
//
// Port of src/vs/editor/common/diff/defaultLinesDiffComputer/utils.ts
// (Array2D, isSpace; LineRangeFragment is only used by computeMovedLines,
// which is not ported), microsoft/vscode c2c46e750ab7afe355bad8bea20a248520adfdb0,
// plus JavaScript string helpers the port depends on.

import Foundation

struct Array2D<T> {
    let width: Int
    let height: Int
    private var array: [T]

    init(width: Int, height: Int, initialValue: T) {
        self.width = width
        self.height = height
        self.array = [T](repeating: initialValue, count: width * height)
    }

    func get(_ x: Int, _ y: Int) -> T {
        array[x + y * width]
    }

    mutating func set(_ x: Int, _ y: Int, _ value: T) {
        array[x + y * width] = value
    }
}

func isSpace(_ charCode: Int) -> Bool {
    charCode == CharCode.space || charCode == CharCode.tab
}

/// Subset of base/common/charCode.ts.
enum CharCode {
    static let tab = 9
    static let lineFeed = 10
    static let carriageReturn = 13
    static let space = 32
    static let comma = 44
    static let digit0 = 48
    static let digit9 = 57
    static let semicolon = 59
    static let upperA = 65
    static let upperZ = 90
    static let lowerA = 97
    static let lowerZ = 122
}

/// JavaScript whitespace as used by `String.prototype.trim` and the regex `\s`
/// (ECMAScript WhiteSpace + LineTerminator). Unlike Foundation's
/// `.whitespacesAndNewlines`, this includes U+FEFF and excludes U+0085.
func jsIsWhitespace(_ unit: UInt16) -> Bool {
    switch unit {
    case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680,
         0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
        return true
    default:
        return false
    }
}

/// UTF-16 code units of `units` with leading JS whitespace removed (`trimStart`).
func jsTrimStart(_ units: ArraySlice<UInt16>) -> ArraySlice<UInt16> {
    var s = units.startIndex
    while s < units.endIndex && jsIsWhitespace(units[s]) {
        s += 1
    }
    return units[s...]
}

/// UTF-16 code units of `units` with trailing JS whitespace removed (`trimEnd`).
func jsTrimEnd(_ units: ArraySlice<UInt16>) -> ArraySlice<UInt16> {
    var e = units.endIndex
    while e > units.startIndex && jsIsWhitespace(units[e - 1]) {
        e -= 1
    }
    return units[..<e]
}

/// JS `String.prototype.trim` on UTF-16 code units.
func jsTrim(_ units: ArraySlice<UInt16>) -> ArraySlice<UInt16> {
    jsTrimEnd(jsTrimStart(units))
}

/// JS `===` on strings: compares UTF-16 code units (Swift `==` uses canonical equivalence).
func jsStringEquals(_ a: String, _ b: String) -> Bool {
    a.utf16.elementsEqual(b.utf16)
}
