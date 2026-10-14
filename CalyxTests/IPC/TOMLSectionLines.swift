//
//  TOMLSectionLines.swift
//  CalyxTests
//
//  The non-empty lines of one `[table]` in a TOML text, up to the next
//  table header, for the helper-form Codex/Grok tests (which pin each
//  table's exact line set without assuming a line order the spec leaves
//  open). `nil` when the header is absent.
//

import Foundation

func tomlSectionLines(_ header: String, in content: String) -> Set<String>? {
    let lines = content.components(separatedBy: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
    guard let start = lines.firstIndex(of: header) else { return nil }
    var result: [String] = []
    for line in lines[(start + 1)...] {
        if line.hasPrefix("[") { break }
        if !line.trimmingCharacters(in: .whitespaces).isEmpty { result.append(line) }
    }
    return Set(result)
}
