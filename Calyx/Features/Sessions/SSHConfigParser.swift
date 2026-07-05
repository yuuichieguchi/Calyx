// SSHConfigParser.swift
// Calyx
//
// Read-only ~/.ssh/config candidate extraction for the future remote-host
// picker UI (not this cycle). Pure function group -- no I/O, no actor
// isolation required; the parser's only input is an ssh_config-format
// STRING (never a file path, so no filesystem access is possible from
// inside it at all).

import Foundation

enum SSHConfigParser {

    /// Extracts every `Host` alias from `configText`, in declaration
    /// order, excluding wildcard (`*`/`?`) and negated (`!`) patterns.
    /// Deliberately does NOT resolve `Include` directives (storage-layer/
    /// UI concern, out of scope for this pure parsing contract) and does
    /// NOT deduplicate repeated aliases (not part of the given contract;
    /// left to a future caller if ever needed).
    ///
    /// KEYWORD MATCHING: a line contributes candidates only when its
    /// FIRST whitespace-separated token, compared case-insensitively,
    /// equals the WHOLE word "Host" -- never merely prefixed by it. This
    /// is what keeps `HostName`'s value from being misread as an extra
    /// Host candidate (`HostName` itself starts with the same four
    /// letters), and, as a side effect, is also why a `Match host
    /// <pattern>` block's own inline condition never introduces spurious
    /// candidates: that line's first token is `Match`, never `Host`, so
    /// no separate block-tracking/indentation logic is needed at all --
    /// a real `Host` block can never begin except with a line whose own
    /// first token is `Host`.
    static func hostCandidates(from configText: String) -> [String] {
        var candidates: [String] = []
        for rawLine in configText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let tokens = line.split(whereSeparator: { $0.isWhitespace })
            guard let keyword = tokens.first,
                  String(keyword).caseInsensitiveCompare("Host") == .orderedSame else { continue }
            for pattern in tokens.dropFirst() {
                if pattern.contains("*") || pattern.contains("?") || pattern.hasPrefix("!") { continue }
                candidates.append(String(pattern))
            }
        }
        return candidates
    }
}
