// SecretRedactor.swift
// Calyx
//
// Masks secret VALUES in command-log text (env assignments, CLI flags,
// Authorization headers, and known token formats) with `marker`, keeping
// keys/flags/header names visible. This runs before text enters
// CommandLogStore (CommandLogStore.ingestStart/materializeOutput), i.e.
// before any consumer -- including MCP tools that expose command-log
// records -- can ever see it.
//
// Known limitations (deliberate, see CalyxTests/CommandLog/SecretRedactorTests.swift
// for the pinned behaviors these trade off against):
//  - `-p` adjacency (e.g. `mysql -pfoo`) is NOT masked: a bare single-letter
//    flag is too false-positive-prone to recognize reliably (e.g. `ls -pfoo`
//    is a plain path argument, not a password).
//  - Prefix-less AWS secret access keys (the `AWS_SECRET_ACCESS_KEY` value
//    itself has no recognizable token prefix) are only caught by the
//    name-gated assignment rule, never by a standalone token-format scan.
//  - A boolean `--secret` flag (no value intended) can swallow the next
//    positional argument as if it were the flag's value.
//  - Escaped quotes inside a double-quoted assignment value (`TOKEN="a\"b"`)
//    are not honored -- the value is cut at the first unescaped-looking `"`.
//  - `TOKEN=$(cat f)` has no literal secret value in the text, so there is
//    nothing for this redactor to find or mask.
//  - Unsigned/malformed JWTs (fewer than 3 dot-separated segments, or
//    segments shorter than the pinned minimums) are not matched.
//
// Performance: redact(_:) makes a small, bounded number of linear O(n)
// passes over the input. Input is capped at CommandLogStore.outputByteCap
// (256 KiB) and this runs once per command finalize, not per byte
// streamed.
//
// Rules a (env assignment), b (fish `set`), and the JWT format (part of
// rule e) are hand-written byte scanners, not regexes -- see the "why not
// a regex" note above `redactAssignmentsAndFishSet` for the backtracking
// blowup this avoids. Rules c and d (CLI flags, Authorization header) and
// the remaining rule-e token formats stay regex-based: each has a literal
// prefix (`--password`, `authorization`, `ghp_`, `AKIA`, ...) that either
// anchors a mismatch in O(1) or, for the open-ended alnum-run formats
// (`sk-`, `xox`, `glpat-`, `npm_`, github tokens), is additionally gated
// behind a cheap `String.contains` prefix pre-check so the pass is
// skipped entirely unless a plausible match could exist. All of the
// above (hand-scanners, prefix gates, and every remaining regex) were
// stress-tested against adversarial 256 KiB inputs -- dense repetitions
// of each rule's keyword/prefix, and a single huge alphanumeric run with
// one keyword at the start -- confirming sub-second completion in each
// case; see the algorithm notes on `redactAssignmentsAndFishSet` and
// `redactJWTs` for why those two needed hand-written scanners instead of
// gating alone.

import Foundation

enum SecretRedactor {

    static let marker = "[redacted]"

    // MARK: - Name gate (rules a, b)

    /// Case-insensitive substrings that mark an env/`set` variable name as
    /// secret-carrying. `API_?KEY` (APIKEY or API_KEY) and the `AUTH`-not-
    /// followed-by-`OR` rule are handled separately below since they are not
    /// plain substring checks.
    private static let secretNameNeedles = ["TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL", "ACCESS_KEY"]

    /// True if `name` looks like it holds a secret value, per the spec's
    /// name-gate: TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|CREDENTIAL|ACCESS_KEY
    /// anywhere in the (case-insensitive) name, or AUTH anywhere it is not
    /// immediately followed by OR (so GIT_AUTHOR_NAME, AUTHORS, etc. are
    /// excluded, but AUTH_TOKEN, X_AUTH, AUTHENTICATION are included).
    private static func isSecretName(_ name: Substring) -> Bool {
        let upper = name.uppercased()
        for needle in secretNameNeedles where upper.contains(needle) {
            return true
        }
        if upper.contains("APIKEY") || upper.contains("API_KEY") {
            return true
        }
        var searchStart = upper.startIndex
        while let range = upper.range(of: "AUTH", range: searchStart..<upper.endIndex) {
            if !upper[range.upperBound...].hasPrefix("OR") {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    /// Cheap superset pre-check for rules a/b: true if `text` contains any
    /// substring that `isSecretName` could ever key off of. Deliberately
    /// coarser than `isSecretName` (e.g. it does not apply the AUTH-not-
    /// followed-by-OR exclusion) so it can only over-trigger, never miss a
    /// case the byte-scanner would otherwise have redacted -- this lets
    /// `redactAssignmentsAndFishSet` skip its whole-text scan in O(n) for
    /// the (overwhelmingly common) case of genuinely secret-free text.
    private static func containsSecretKeyword(_ text: String) -> Bool {
        let upper = text.uppercased()
        for needle in secretNameNeedles where upper.contains(needle) {
            return true
        }
        return upper.contains("APIKEY") || upper.contains("API_KEY") || upper.contains("AUTH")
    }

    // MARK: - Rules a & b: hand-written byte scanner
    //
    // Why not a regex: `[A-Za-z_][A-Za-z0-9_]*` (the identifier at the
    // start of both a `NAME=value` assignment and fish's `set NAME ...`)
    // is a greedy, unanchored run with no preceding literal to fail fast
    // on. On a long run of identifier characters that never reaches the
    // rule's required delimiter (`=`, or `set`'s mandatory whitespace), a
    // backtracking regex engine retries at every offset within the run --
    // O(k) work per offset, O(k^2) across a k-byte run. A 256 KiB run of a
    // single repeated letter reproduced this as a multi-minute hang.
    //
    // The fix is a hand-written scanner that bounds the one place the
    // blowup comes from: identifier length. `maxIdentifierLength` caps how
    // far the scanner will walk forward looking for the end of a run of
    // identifier bytes; runs longer than that are simply not real
    // variable/flag names (nothing in `export`, `set`, or a CLI flag ever
    // legitimately produces a 256+ char bare identifier) and are copied
    // through unchanged. Because the scanner only ever attempts this
    // bounded walk at the START of an identifier run (guarded by
    // `i == 0 || !isIdentByte(bytes[i - 1])`), and falls back to a plain
    // byte-by-byte copy for every other position, each input byte is
    // visited a small constant number of times overall: O(n) total, with
    // no per-offset retry. Value/`set`-values scanning is a single forward
    // walk to a natural terminator (a closing quote, whitespace, or `\n`),
    // consumed once and never rescanned, so it stays O(n) in total even
    // when one individual value is large.

    private static func isIdentByte(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x5F
    }
    private static func isIdentStartByte(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F
    }
    /// `\s;|&` from the original `[^\s;|&]+` bare-value alternative
    /// (ASCII whitespace only -- see the Unicode-`\s` note below).
    private static func isBareValueTerminator(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0B || b == 0x0C
            || b == UInt8(ascii: ";") || b == UInt8(ascii: "|") || b == UInt8(ascii: "&")
    }
    /// Space/tab only -- used for the whitespace *within* a fish `set`
    /// line, which must not cross into the next line.
    private static func isLineWhitespace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09
    }

    /// No real env var, CLI flag, or fish variable name is remotely this
    /// long; a run longer than this is treated as "not an identifier" and
    /// copied through unchanged rather than fully scanned, which is what
    /// keeps identifier scanning O(1) per attempt regardless of how long
    /// the underlying byte run actually is.
    private static let maxIdentifierLength = 256

    /// Parses a rule-a value starting at `from` (just after `=`),
    /// mirroring `"[^"\n]*"` | `'[^'\n]*'` | `[^\s;|&]+` in that
    /// alternation order: an unterminated quote (no closing quote before
    /// `\n`/end-of-text) falls back to the bare alternative, starting over
    /// at the quote character itself, exactly as regex alternation
    /// backtracking would. Returns the exclusive end index of the
    /// consumed value, or nil if no alternative matches (e.g. an empty
    /// bare value at end of input, which the regex's trailing `+` would
    /// also reject).
    private static func parseAssignmentValueEnd(_ bytes: [UInt8], from: Int, n: Int) -> Int? {
        if from < n, bytes[from] == UInt8(ascii: "\"") {
            var k = from + 1
            while k < n, bytes[k] != UInt8(ascii: "\""), bytes[k] != UInt8(ascii: "\n") { k += 1 }
            if k < n, bytes[k] == UInt8(ascii: "\"") { return k + 1 }
        } else if from < n, bytes[from] == UInt8(ascii: "'") {
            var k = from + 1
            while k < n, bytes[k] != UInt8(ascii: "'"), bytes[k] != UInt8(ascii: "\n") { k += 1 }
            if k < n, bytes[k] == UInt8(ascii: "'") { return k + 1 }
        }
        var k = from
        while k < n, !isBareValueTerminator(bytes[k]) { k += 1 }
        return k > from ? k : nil
    }

    private struct FishSetParse {
        let nameStart: Int
        let nameEnd: Int
        let valuesEnd: Int
    }

    /// Parses `(?:\s+-\S+)?\s+(?<name>[A-Za-z_][A-Za-z0-9_]*)\s+(?<values>[^\n]+)`
    /// starting right after the literal `set` keyword (matching fish's
    /// `set [-flags] NAME VALUES...`). Every component here is inherently
    /// short (a whitespace run, at most one flag token, an identifier
    /// bounded by `maxIdentifierLength`) except `values`, which -- like an
    /// assignment value -- is scanned forward exactly once to the next
    /// newline/end-of-text and never rescanned.
    private static func parseFishSet(_ bytes: [UInt8], afterSetKeyword: Int, n: Int) -> FishSetParse? {
        var k = afterSetKeyword

        func skipLineWhitespace() -> Bool {
            let start = k
            while k < n, isLineWhitespace(bytes[k]) { k += 1 }
            return k > start
        }

        guard skipLineWhitespace() else { return nil }

        if k < n, bytes[k] == UInt8(ascii: "-") {
            // Optional `-flag` token: `\s+-\S+` inside the regex's
            // `(?:\s+-\S+)?` group. If no whitespace follows the flag's
            // `\S+` run, the group can never have matched (there is no
            // shorter split of a maximal non-whitespace run that exposes
            // trailing whitespace), so we rewind and treat it as absent --
            // equivalent to the regex dropping the optional group.
            let savedK = k
            var f = k + 1
            while f < n, !isBareValueTerminator(bytes[f]) { f += 1 }
            k = f
            if !skipLineWhitespace() {
                k = savedK
            }
        }

        guard k < n, isIdentStartByte(bytes[k]) else { return nil }
        let nameStart = k
        var nameEnd = k
        let cap = min(n, nameStart + maxIdentifierLength)
        while nameEnd < cap, isIdentByte(bytes[nameEnd]) { nameEnd += 1 }
        if nameEnd == cap, nameEnd < n, isIdentByte(bytes[nameEnd]) { return nil }

        k = nameEnd
        guard skipLineWhitespace() else { return nil }

        let valuesStart = k
        var v = valuesStart
        while v < n, bytes[v] != UInt8(ascii: "\n") { v += 1 }
        guard v > valuesStart else { return nil }

        return FishSetParse(nameStart: nameStart, nameEnd: nameEnd, valuesEnd: v)
    }

    /// Rules a & b in one left-to-right pass: env assignment (`FOO=bar`)
    /// and fish `set [-flags] FOO bar...`, both name-gated by
    /// `isSecretName`. See the "why not a regex" note above this section.
    private static func redactAssignmentsAndFishSet(_ text: String) -> String {
        guard containsSecretKeyword(text) else { return text }

        let bytes = Array(text.utf8)
        let n = bytes.count
        var out = [UInt8]()
        out.reserveCapacity(n)

        var i = 0
        while i < n {
            let b = bytes[i]

            guard isIdentStartByte(b), i == 0 || !isIdentByte(bytes[i - 1]) else {
                out.append(b)
                i += 1
                continue
            }

            let nameStart = i
            var nameEnd = i
            let cap = min(n, nameStart + maxIdentifierLength)
            while nameEnd < cap, isIdentByte(bytes[nameEnd]) { nameEnd += 1 }
            let overLong = nameEnd == cap && nameEnd < n && isIdentByte(bytes[nameEnd])

            // Try fish `set` first (only possible if this identifier is
            // literally "set"), then fall back to a plain assignment.
            if !overLong, nameEnd - nameStart == 3,
               bytes[nameStart] == UInt8(ascii: "s"), bytes[nameStart + 1] == UInt8(ascii: "e"), bytes[nameStart + 2] == UInt8(ascii: "t"),
               let parsed = parseFishSet(bytes, afterSetKeyword: nameEnd, n: n) {
                let setName = String(decoding: bytes[parsed.nameStart..<parsed.nameEnd], as: UTF8.self)
                if isSecretName(Substring(setName)) {
                    out.append(contentsOf: bytes[nameStart..<parsed.nameEnd])
                    out.append(UInt8(ascii: " "))
                    out.append(contentsOf: marker.utf8)
                    i = parsed.valuesEnd
                    continue
                }
            }

            if !overLong, nameEnd < n, bytes[nameEnd] == UInt8(ascii: "="),
               let valueEnd = parseAssignmentValueEnd(bytes, from: nameEnd + 1, n: n) {
                let name = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)
                if isSecretName(Substring(name)) {
                    out.append(contentsOf: name.utf8)
                    out.append(UInt8(ascii: "="))
                    out.append(contentsOf: marker.utf8)
                    i = valueEnd
                    continue
                }
            }

            out.append(contentsOf: bytes[nameStart..<nameEnd])
            i = nameEnd
        }

        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Regexes (rules c, d, and most of e)
    //
    // Declared as computed `static var`s rather than stored `static let`s:
    // Regex<Output> does not conform to Sendable in this SDK (verified
    // against the installed _StringProcessing.swiftinterface -- no
    // unconditional or conditional Sendable conformance is declared for
    // it), so a *stored* static property would fail Swift 6 strict
    // concurrency's "non-Sendable global/static state" check. A computed
    // property re-evaluates the regex literal per access, which is cheap
    // (the literal's pattern is compiled by the compiler, not re-parsed at
    // runtime) and keeps `redact` callable from any isolation domain,
    // matching both CommandLogStore's @MainActor call site and the
    // non-actor-isolated test functions in SecretRedactorTests.
    //
    // These regexes are safe to keep as regexes (unlike rules a/b and the
    // JWT format below) because each has a short literal anchor
    // (`--password`, `authorization`, `ghp_`, `AKIA`, ...) immediately at
    // the match's start, so a mismatch fails in O(1) rather than after an
    // unbounded greedy scan -- confirmed by stress-testing each against a
    // 256 KiB adversarial input tiled with its own prefix/keyword.

    /// Rule c (`=` form): `--password=`, `--token=`, `--api-key=`,
    /// `--secret=`, `--access-token=`. The value may itself start with `-`
    /// (e.g. `--token=-abc`) since the `=` unambiguously delimits it.
    private static var cliFlagEqualsRegex: Regex<(Substring, flag: Substring, value: Substring)> {
        /(?<flag>--password|--token|--api-key|--secret|--access-token)\b=(?<value>\S+)/
    }

    /// Rule c (space form): same flags, space-separated value. The value
    /// must NOT start with `-`, otherwise it is almost certainly the next
    /// flag rather than this flag's value (`--password --verbose` must
    /// leave `--verbose` alone). Known limitation: a boolean `--secret`
    /// flag with no value can still swallow the next positional argument
    /// as if it were the value (e.g. `--secret myfile.txt`).
    private static var cliFlagSpaceRegex: Regex<(Substring, flag: Substring, value: Substring)> {
        /(?<flag>--password|--token|--api-key|--secret|--access-token)\b\s+(?<value>(?!-)\S+)/
    }

    /// Rule d: `Authorization:` header (any case), keeping an optional
    /// leading scheme (`Bearer`/`Basic`/`Token`, any case) intact and
    /// masking only the credential value. Value stops at whitespace or a
    /// quote so it works both bare and inside a quoted `-H "..."` argument.
    private static var authorizationHeaderRegex: Regex<(Substring, head: Substring, value: Substring)> {
        /(?<head>(?i:authorization):\s*(?:(?i:bearer|basic|token)\s+)?)(?<value>[^\s'"]+)/
    }

    // MARK: - Rule e: known token formats, matched anywhere in the text.
    //
    // No `\b` boundary: a leading `\b` would fail to match a token glued
    // directly to other alphanumeric output with no delimiter (real
    // terminal output has no guarantee of whitespace around an embedded
    // secret), and a trailing `\b` combined with a bounded quantifier can
    // make the whole match fail on such adjacency too -- if adjacent
    // filler in the same character class extends past the quantifier's
    // upper bound, every backtrack length lands mid-run on a word/word
    // "boundary" that never holds, so no length satisfies `\b` and the
    // match is dropped entirely (silently failing to redact a real
    // token). Each quantifier below therefore has an explicit upper bound
    // -- generous enough to comfortably exceed every real-world token
    // length these prefixes produce, per each rule's comment -- with no
    // trailing assertion, so consumption is capped (never swallows an
    // unbounded run of adjacent alphanumeric filler) without any chance
    // of the boundary check itself defeating the match.

    /// GitHub personal/OAuth/user-to-server/server-to-server/refresh
    /// tokens. Real tokens are exactly 36 chars after the prefix; the
    /// upper bound (100) is slack against future format growth while
    /// still capping how much adjacent same-charset filler a match can
    /// absorb. False positives: a 36+ char alnum run that merely happens
    /// to start with `ghp_`/`gho_`/etc. would also match; accepted as
    /// extremely unlikely to occur outside real tokens.
    private static var githubTokenRegex: Regex<Substring> {
        /gh[oprsu]_[A-Za-z0-9]{36,100}/
    }

    /// GitHub fine-grained personal access tokens (real tokens: ~82 chars
    /// after the prefix; bounded to 150 for slack).
    private static var githubPatRegex: Regex<Substring> {
        /github_pat_[A-Za-z0-9_]{22,150}/
    }

    /// OpenAI (`sk-...`) and Anthropic (`sk-ant-...`) API keys. The 20+
    /// char minimum after `sk-` is chosen to exclude short, non-secret
    /// uses of the same prefix (`sk-learn`, `sk-foo`) while still matching
    /// real keys, which are always much longer; bounded to 200 to cap
    /// adjacent-filler absorption.
    private static var openAIAnthropicRegex: Regex<Substring> {
        /sk-[A-Za-z0-9_-]{20,200}/
    }

    /// AWS access key IDs. Fixed-width (`AKIA` + exactly 16 base32-ish
    /// chars) per the real key-ID format; does not catch the paired
    /// *secret* key, which has no recognizable prefix (see the
    /// name-gated-assignment-only limitation above).
    private static var awsAccessKeyRegex: Regex<Substring> {
        /AKIA[0-9A-Z]{16}/
    }

    /// Slack bot/app/user/refresh/service tokens (`xoxb-`, `xoxa-`,
    /// `xoxp-`, `xoxr-`, `xoxs-`); bounded to 200 to cap adjacent-filler
    /// absorption.
    private static var slackTokenRegex: Regex<Substring> {
        /xox[baprs]-[A-Za-z0-9-]{10,200}/
    }

    /// GitLab personal access tokens (real tokens: 20 chars after the
    /// prefix; bounded to 100 for slack).
    private static var gitlabTokenRegex: Regex<Substring> {
        /glpat-[A-Za-z0-9_-]{20,100}/
    }

    /// npm automation/publish tokens (real tokens: 36 chars after the
    /// prefix; bounded to 100 for slack).
    private static var npmTokenRegex: Regex<Substring> {
        /npm_[A-Za-z0-9]{36,100}/
    }

    /// Google API keys (fixed-width: `AIza` + exactly 35 chars).
    private static var googleAPIKeyRegex: Regex<Substring> {
        /AIza[0-9A-Za-z_-]{35}/
    }

    // JWTs (three dot-separated base64url segments, each header/payload
    // segment starting `eyJ` -- a base64url-encoded `{"`) are hand-scanned
    // rather than a regex, for the same reason as rules a/b: a
    // backtracking search for the segment-separating `.` after a greedy
    // `[A-Za-z0-9_-]+` run has no literal anchor to fail fast on, so dense
    // "eyJ"-shaped filler with no real dots forces the same per-offset
    // rescanning blowup a bounded-quantifier regex version of this
    // reproduced at ~16s for a 256 KiB adversarial input (well over the
    // "well under a second" bar). Segment scans are capped
    // (`maxJWTSegmentLength`) so one attempt is bounded work, and -- like
    // the identifier scan in rules a/b -- an attempt is only ever made at
    // the start of a run of JWT-alphabet bytes (`isRunStart` below), so a
    // long homogeneous run is scanned once, not once per byte within it.
    // Minimum segment lengths exclude short illustrative fragments
    // (`eyJab.eyJcd.ef`) that aren't plausible real tokens. Unsigned JWTs
    // (missing third segment) are not matched -- see limitations above.
    private static let maxJWTSegmentLength = 2000

    private static func isJWTByte(_ b: UInt8) -> Bool {
        isIdentByte(b) || b == UInt8(ascii: "-")
    }

    private static func redactJWTs(_ text: String) -> String {
        guard text.contains("eyJ") else { return text }

        let bytes = Array(text.utf8)
        let n = bytes.count
        var out = [UInt8]()
        out.reserveCapacity(n)

        func scanSegment(from start: Int) -> Int {
            var k = start
            let cap = min(n, start + maxJWTSegmentLength)
            while k < cap, isJWTByte(bytes[k]) { k += 1 }
            return k
        }

        var i = 0
        while i < n {
            let isRunStart = i == 0 || !isJWTByte(bytes[i - 1])
            if isRunStart, i + 3 <= n, bytes[i] == UInt8(ascii: "e"), bytes[i + 1] == UInt8(ascii: "y"), bytes[i + 2] == UInt8(ascii: "J") {
                let seg1End = scanSegment(from: i + 3)
                if seg1End - (i + 3) >= 8, seg1End < n, bytes[seg1End] == UInt8(ascii: "."),
                   seg1End + 4 <= n, bytes[seg1End + 1] == UInt8(ascii: "e"), bytes[seg1End + 2] == UInt8(ascii: "y"), bytes[seg1End + 3] == UInt8(ascii: "J") {
                    let seg2End = scanSegment(from: seg1End + 4)
                    if seg2End - (seg1End + 4) >= 8, seg2End < n, bytes[seg2End] == UInt8(ascii: ".") {
                        let seg3End = scanSegment(from: seg2End + 1)
                        if seg3End - (seg2End + 1) >= 10 {
                            out.append(contentsOf: marker.utf8)
                            i = seg3End
                            continue
                        }
                    }
                }
            }
            out.append(bytes[i])
            i += 1
        }

        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - redact

    static func redact(_ text: String) -> String {
        // a & b. Env assignment / fish `set`, name-gated.
        var result = redactAssignmentsAndFishSet(text)

        // c. CLI secret flags, `=` then space form.
        result = result.replacing(cliFlagEqualsRegex) { match in
            "\(match.output.flag)=\(marker)"
        }
        result = result.replacing(cliFlagSpaceRegex) { match in
            "\(match.output.flag) \(marker)"
        }

        // d. Authorization header.
        result = result.replacing(authorizationHeaderRegex) { match in
            "\(match.output.head)\(marker)"
        }

        // e. Known token formats, anywhere in the text -- each gated on its
        // literal prefix so the regex pass is skipped unless a plausible
        // match could exist.
        if result.contains("ghp_") || result.contains("gho_") || result.contains("ghu_")
            || result.contains("ghs_") || result.contains("ghr_") {
            result = result.replacing(githubTokenRegex, with: marker)
        }
        if result.contains("github_pat_") {
            result = result.replacing(githubPatRegex, with: marker)
        }
        if result.contains("sk-") {
            result = result.replacing(openAIAnthropicRegex, with: marker)
        }
        if result.contains("AKIA") {
            result = result.replacing(awsAccessKeyRegex, with: marker)
        }
        if result.contains("xox") {
            result = result.replacing(slackTokenRegex, with: marker)
        }
        if result.contains("glpat-") {
            result = result.replacing(gitlabTokenRegex, with: marker)
        }
        if result.contains("npm_") {
            result = result.replacing(npmTokenRegex, with: marker)
        }
        if result.contains("AIza") {
            result = result.replacing(googleAPIKeyRegex, with: marker)
        }
        result = redactJWTs(result)

        return result
    }
}
