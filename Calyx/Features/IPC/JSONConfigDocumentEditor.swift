// JSONConfigDocumentEditor.swift
// Calyx
//
// Byte-offset based editor for the single JSON key-path value or array
// element Calyx owns inside an otherwise user-owned JSON document. Never
// re-serializes the whole document through JSONSerialization: a small
// recursive-descent scanner locates the exact byte range to splice, so
// everything outside that range survives untouched, key order and
// whitespace included.

import Foundation

/// A single step in a path through a JSON document: either an object
/// member by key, or the array element matching a predicate (evaluated
/// against that element's `JSONSerialization`-decoded value). A path of
/// only `.key` segments is the same address a plain `[String]` key path
/// gives; `.element` extends the grammar to reach inside a specific array
/// element's own nested structure, e.g. `hooks.<Event>[]`'s matcher group
/// objects, each of which owns its own nested `"hooks"` array.
enum JSONPathSegment {
    case key(String)
    case element(where: (Any) -> Bool)
}

enum JSONConfigDocumentEditor {

    enum EditorError: Error, LocalizedError, Sendable {
        case typeConflict(String)

        var errorDescription: String? {
            switch self {
            case .typeConflict(let key):
                return "Expected \"\(key)\" to hold a JSON object or array, but it holds a different type"
            }
        }
    }

    static func setValue(_ value: Data, at keyPath: [String], in current: Data?) throws -> Data {
        precondition(!keyPath.isEmpty, "keyPath must not be empty")
        var bytes = try rootBytes(from: current)
        try JSONEditor.setValue(Array(value), at: keyPath, in: &bytes)
        return Data(bytes)
    }

    static func removeValue(at keyPath: [String], in current: Data?) throws -> Data? {
        precondition(!keyPath.isEmpty, "keyPath must not be empty")
        guard let current, !current.isEmpty else { return current }
        var bytes = Array(current)
        _ = try JSONEditor.parseRootObject(bytes)
        try JSONEditor.removeValue(at: keyPath, in: &bytes)
        return Data(bytes)
    }

    static func appendArrayElement(_ element: Data, at keyPath: [String], in current: Data?) throws -> Data {
        precondition(!keyPath.isEmpty, "keyPath must not be empty")
        var bytes = try rootBytes(from: current)
        try JSONEditor.appendArrayElement(Array(element), at: keyPath, in: &bytes)
        return Data(bytes)
    }

    static func removeArrayElements(
        at path: [JSONPathSegment], in current: Data?, where predicate: (Any) -> Bool
    ) throws -> Data? {
        precondition(!path.isEmpty, "path must not be empty")
        guard let current, !current.isEmpty else { return current }
        var bytes = Array(current)
        _ = try JSONEditor.parseRootObject(bytes)
        try JSONEditor.removeArrayElements(at: path, in: &bytes, where: predicate)
        return Data(bytes)
    }

    // MARK: - Read-only detection (L1's "same detection function as the write side")

    /// Whether `keyPath` resolves to a present member, decided by the
    /// same `JParser` structural scan `setValue`/`removeValue` use --
    /// never a whole-document `JSONSerialization.jsonObject(with:)`
    /// parse, which can resolve differently on a document both
    /// technically accept (a duplicate key: both resolve the FIRST
    /// occurrence here, matching `locateObject`'s `.first(where:)`). A
    /// leading UTF-8 BOM is skipped by `JParser.parseDocument` as bytes
    /// outside the document, matching `JSONSerialization`'s own leniency
    /// there.
    /// `false` for a `nil`/empty document, or one `JParser` cannot parse
    /// at all -- a read-only predicate reports "not installed" rather
    /// than throwing; only the write side (`removeValue`) throws
    /// `ConfigFileError.invalidJSON` for that case.
    static func containsValue(at keyPath: [String], in current: Data?) -> Bool {
        precondition(!keyPath.isEmpty, "keyPath must not be empty")
        guard let current, !current.isEmpty else { return false }
        return JSONEditor.containsValue(at: keyPath, in: Array(current))
    }

    /// Whether `path` resolves to an array holding at least one element
    /// matching `predicate` -- the same resolution `removeArrayElements`
    /// performs (`.element(where:)` evaluated via `JSONSerialization`
    /// against that one element's own decoded bytes, the "element-level
    /// decode is fine" carve-out; only the document's own top-level
    /// structure is walked by `JParser`). `false` for a `nil`/empty
    /// document, one `JParser` cannot parse, or a `path` that does not
    /// resolve to an array at all.
    static func containsArrayElement(at path: [JSONPathSegment], in current: Data?, where predicate: @escaping (Any) -> Bool) -> Bool {
        precondition(!path.isEmpty, "path must not be empty")
        guard let current, !current.isEmpty else { return false }
        return JSONEditor.containsArrayElement(at: path, in: Array(current), where: predicate)
    }

    /// The `JSONSerialization`-decoded value `path` resolves to, or
    /// `nil` when `path` does not resolve at all. Node-level decode only
    /// (the resolved node's own byte range, via the same
    /// `JSONSerialization` call `resolvePath`'s `.element(where:)` step
    /// already makes) -- the document's own top-level structure is
    /// walked by `JParser`, never a whole-document `JSONSerialization`
    /// parse. Exists for callers that need the resolved value itself
    /// (e.g. an array's element count, or structural equality against a
    /// candidate value), where `containsArrayElement`'s plain `Bool`
    /// isn't enough. Throws `ConfigFileError.invalidJSON` when `current`
    /// itself cannot be parsed at all -- same throwing contract as
    /// `removeValue`, so a caller on the write side can propagate it
    /// unchanged, and a caller on the read side wraps this in `try?`.
    static func decodedValue(at path: [JSONPathSegment], in current: Data?) throws -> Any? {
        precondition(!path.isEmpty, "path must not be empty")
        guard let current, !current.isEmpty else { return nil }
        return try JSONEditor.decodedValue(at: path, in: Array(current))
    }

    /// `nil` or empty input starts from an empty object -- there is no
    /// document yet, so the container the keyPath needs is created from
    /// scratch, same as an existing empty `{}` would be.
    private static func rootBytes(from current: Data?) throws -> [UInt8] {
        guard let current, !current.isEmpty else { return Array("{}".utf8) }
        let bytes = Array(current)
        _ = try JSONEditor.parseRootObject(bytes)
        return bytes
    }
}

// MARK: - Byte-range scan tree

/// A parsed JSON value's exact byte span, plus (for objects and arrays)
/// enough structure to splice a single member or element without touching
/// anything else: each member/element records the whitespace gap before it
/// so a removal can hand that gap to its neighbor, and an insertion can
/// copy it as a template for matching indentation.
private indirect enum JNode {
    case object(JObject)
    case array(JArray)
    case scalar(Range<Int>)

    var range: Range<Int> {
        switch self {
        case .object(let o): return o.openBrace..<(o.closeBrace + 1)
        case .array(let a): return a.openBracket..<(a.closeBracket + 1)
        case .scalar(let r): return r
        }
    }
}

private struct JMember {
    /// Whitespace from the previous delimiter (`{` or `,`) up to this
    /// member's opening quote -- typically the newline + indent that
    /// precedes every sibling at this nesting level.
    let gapBefore: Range<Int>
    let keyRange: Range<Int>
    let key: String
    let colonPos: Int
    let value: JNode
}

private struct JObject {
    let openBrace: Int
    let closeBrace: Int
    let members: [JMember]
}

private struct JElement {
    let gapBefore: Range<Int>
    let value: JNode
}

private struct JArray {
    let openBracket: Int
    let closeBracket: Int
    let elements: [JElement]
}

private struct JSONScanError: Error {}

// MARK: - Recursive-descent scanner

private struct JParser {
    let bytes: [UInt8]

    func parseDocument() throws -> JObject {
        var i = skipBOM(0)
        i = skipWS(i)
        let (node, end) = try parseValue(at: i)
        guard case .object(let obj) = node else { throw JSONScanError() }
        i = skipWS(end)
        guard i == bytes.count else { throw JSONScanError() }
        return obj
    }

    /// Skips a leading UTF-8 BOM (`EF BB BF`), if `bytes` starts with one:
    /// bytes outside the JSON document itself, same as `JSONSerialization`
    /// already treats it. Every subsequent range this parser records is
    /// an absolute offset past it, so it is never touched by a splice and
    /// survives verbatim on write.
    func skipBOM(_ start: Int) -> Int {
        guard start + 3 <= bytes.count,
              bytes[start] == 0xEF, bytes[start + 1] == 0xBB, bytes[start + 2] == 0xBF
        else { return start }
        return start + 3
    }

    func skipWS(_ start: Int) -> Int {
        var i = start
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                i += 1
            } else {
                break
            }
        }
        return i
    }

    func parseValue(at start: Int) throws -> (JNode, Int) {
        guard start < bytes.count else { throw JSONScanError() }
        switch bytes[start] {
        case UInt8(ascii: "{"):
            return try parseObject(at: start)
        case UInt8(ascii: "["):
            return try parseArray(at: start)
        case UInt8(ascii: "\""):
            let end = try parseStringEnd(at: start)
            return (.scalar(start..<end), end)
        case UInt8(ascii: "t"):
            try expectLiteral("true", at: start)
            return (.scalar(start..<(start + 4)), start + 4)
        case UInt8(ascii: "f"):
            try expectLiteral("false", at: start)
            return (.scalar(start..<(start + 5)), start + 5)
        case UInt8(ascii: "n"):
            try expectLiteral("null", at: start)
            return (.scalar(start..<(start + 4)), start + 4)
        default:
            let end = try parseNumberEnd(at: start)
            return (.scalar(start..<end), end)
        }
    }

    func expectLiteral(_ literal: String, at start: Int) throws {
        let lb = Array(literal.utf8)
        guard start + lb.count <= bytes.count else { throw JSONScanError() }
        for k in 0..<lb.count where bytes[start + k] != lb[k] {
            throw JSONScanError()
        }
    }

    func parseStringEnd(at start: Int) throws -> Int {
        var i = start + 1
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "\\") {
                i += 2
                continue
            }
            if b == UInt8(ascii: "\"") {
                return i + 1
            }
            i += 1
        }
        throw JSONScanError()
    }

    func parseNumberEnd(at start: Int) throws -> Int {
        let allowed = Set("+-0123456789.eE".utf8)
        guard start < bytes.count, allowed.contains(bytes[start]) else { throw JSONScanError() }
        var i = start
        while i < bytes.count, allowed.contains(bytes[i]) {
            i += 1
        }
        return i
    }

    func parseObject(at openBrace: Int) throws -> (JNode, Int) {
        let i = skipWS(openBrace + 1)
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") {
            return (.object(JObject(openBrace: openBrace, closeBrace: i, members: [])), i + 1)
        }
        var members: [JMember] = []
        var gapStart = openBrace + 1
        while true {
            let keyStart = skipWS(gapStart)
            guard keyStart < bytes.count, bytes[keyStart] == UInt8(ascii: "\"") else { throw JSONScanError() }
            let keyEnd = try parseStringEnd(at: keyStart)
            let keyRange = keyStart..<keyEnd
            let key = decodeJSONString(Array(bytes[keyRange]))
            var j = skipWS(keyEnd)
            guard j < bytes.count, bytes[j] == UInt8(ascii: ":") else { throw JSONScanError() }
            let colonPos = j
            j = skipWS(colonPos + 1)
            let (value, valueEnd) = try parseValue(at: j)
            members.append(JMember(gapBefore: gapStart..<keyStart, keyRange: keyRange, key: key, colonPos: colonPos, value: value))
            let after = skipWS(valueEnd)
            guard after < bytes.count else { throw JSONScanError() }
            if bytes[after] == UInt8(ascii: ",") {
                gapStart = after + 1
                continue
            } else if bytes[after] == UInt8(ascii: "}") {
                return (.object(JObject(openBrace: openBrace, closeBrace: after, members: members)), after + 1)
            } else {
                throw JSONScanError()
            }
        }
    }

    func parseArray(at openBracket: Int) throws -> (JNode, Int) {
        let i = skipWS(openBracket + 1)
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") {
            return (.array(JArray(openBracket: openBracket, closeBracket: i, elements: [])), i + 1)
        }
        var elements: [JElement] = []
        var gapStart = openBracket + 1
        while true {
            let elemStart = skipWS(gapStart)
            let (value, valueEnd) = try parseValue(at: elemStart)
            elements.append(JElement(gapBefore: gapStart..<elemStart, value: value))
            let after = skipWS(valueEnd)
            guard after < bytes.count else { throw JSONScanError() }
            if bytes[after] == UInt8(ascii: ",") {
                gapStart = after + 1
                continue
            } else if bytes[after] == UInt8(ascii: "]") {
                return (.array(JArray(openBracket: openBracket, closeBracket: after, elements: elements)), after + 1)
            } else {
                throw JSONScanError()
            }
        }
    }
}

/// Unescapes a JSON string token (quotes included) whose bytes are already
/// known, by construction of the scanner that produced the range, to be
/// syntactically valid JSON string grammar -- so this never needs to
/// signal failure. Surrogate-pair `\uXXXX` escapes are decoded per unit,
/// which is exact for the plain-ASCII tool/key names Calyx's own keyPaths
/// use; unpaired surrogates outside that use case would decode lossily.
private func decodeJSONString(_ bytes: [UInt8]) -> String {
    var result: [UInt8] = []
    var i = 1
    let end = bytes.count - 1
    while i < end {
        let b = bytes[i]
        guard b == UInt8(ascii: "\\"), i + 1 < end else {
            result.append(b)
            i += 1
            continue
        }
        let next = bytes[i + 1]
        switch next {
        case UInt8(ascii: "\""): result.append(UInt8(ascii: "\"")); i += 2
        case UInt8(ascii: "\\"): result.append(UInt8(ascii: "\\")); i += 2
        case UInt8(ascii: "/"): result.append(UInt8(ascii: "/")); i += 2
        case UInt8(ascii: "n"): result.append(UInt8(ascii: "\n")); i += 2
        case UInt8(ascii: "t"): result.append(UInt8(ascii: "\t")); i += 2
        case UInt8(ascii: "r"): result.append(UInt8(ascii: "\r")); i += 2
        case UInt8(ascii: "b"): result.append(0x08); i += 2
        case UInt8(ascii: "f"): result.append(0x0C); i += 2
        case UInt8(ascii: "u"):
            let hexEnd = min(i + 6, end)
            if hexEnd == i + 6, let value = UInt32(String(decoding: bytes[(i + 2)..<hexEnd], as: UTF8.self), radix: 16),
               let scalar = Unicode.Scalar(value) {
                result.append(contentsOf: Array(String(scalar).utf8))
            }
            i = hexEnd
        default:
            result.append(next)
            i += 2
        }
    }
    return String(decoding: result, as: UTF8.self)
}

// MARK: - Splice-based mutation

/// All mutation lives here as free functions over `inout [UInt8]`, each
/// re-parsing the document with `JParser` after every single splice
/// (insert/remove) rather than hand-adjusting stored offsets -- config
/// files are small, so the O(n^2) cost of repeated re-scans is not worth
/// the bug surface of manual offset fixups.
private enum JSONEditor {

    static func parseRootObject(_ bytes: [UInt8]) throws -> JObject {
        do {
            return try JParser(bytes: bytes).parseDocument()
        } catch {
            throw ConfigFileError.invalidJSON
        }
    }

    static func setValue(_ value: [UInt8], at keyPath: [String], in bytes: inout [UInt8]) throws {
        try ensureAncestorObjects(Array(keyPath.dropLast()), in: &bytes)
        let root = try parseRootObject(bytes)
        guard let parent = locateObject(root, path: Array(keyPath.dropLast())) else {
            throw JSONConfigDocumentEditor.EditorError.typeConflict(keyPath.dropLast().last ?? "")
        }
        let finalKey = keyPath.last!
        if let existing = parent.members.first(where: { $0.key == finalKey }) {
            let reindented = reindentValue(value, contextBytes: bytes, insertionPoint: existing.value.range.lowerBound, depth: keyPath.count)
            bytes.replaceSubrange(existing.value.range, with: reindented)
        } else {
            try insertMember(key: finalKey, value: value, into: parent, depth: keyPath.count, bytes: &bytes)
        }
    }

    static func removeValue(at keyPath: [String], in bytes: inout [UInt8]) throws {
        var path = keyPath
        while !path.isEmpty {
            let root = try parseRootObject(bytes)
            let ancestorPath = Array(path.dropLast())
            guard let parent = locateObject(root, path: ancestorPath) else { return }
            guard let idx = parent.members.firstIndex(where: { $0.key == path.last! }) else { return }
            spliceRemoveMember(&bytes, object: parent, index: idx)

            guard !ancestorPath.isEmpty else { return }

            let rescanned = try parseRootObject(bytes)
            guard let grandparent = locateObject(rescanned, path: Array(ancestorPath.dropLast())) else { return }
            guard let parentKey = ancestorPath.last,
                  let parentMember = grandparent.members.first(where: { $0.key == parentKey }),
                  case .object(let parentObj) = parentMember.value,
                  parentObj.members.isEmpty
            else { return }

            path = ancestorPath
        }
    }

    static func appendArrayElement(_ element: [UInt8], at keyPath: [String], in bytes: inout [UInt8]) throws {
        try ensureAncestorObjects(Array(keyPath.dropLast()), in: &bytes)
        let root = try parseRootObject(bytes)
        guard let parent = locateObject(root, path: Array(keyPath.dropLast())) else {
            throw JSONConfigDocumentEditor.EditorError.typeConflict(keyPath.dropLast().last ?? "")
        }
        let key = keyPath.last!
        if let existing = parent.members.first(where: { $0.key == key }) {
            guard case .array(let arr) = existing.value else {
                throw JSONConfigDocumentEditor.EditorError.typeConflict(key)
            }
            try insertArrayElement(element, into: arr, depth: keyPath.count, bytes: &bytes)
        } else {
            try insertMember(key: key, value: Array("[]".utf8), into: parent, depth: keyPath.count, bytes: &bytes)
            let root2 = try parseRootObject(bytes)
            guard let parent2 = locateObject(root2, path: Array(keyPath.dropLast())),
                  let created = parent2.members.first(where: { $0.key == key }),
                  case .array(let arr2) = created.value
            else {
                throw JSONConfigDocumentEditor.EditorError.typeConflict(key)
            }
            try insertArrayElement(element, into: arr2, depth: keyPath.count, bytes: &bytes)
        }
    }

    /// A path step resolved against one specific parse of `bytes`: a
    /// `.element(where:)` segment's predicate is evaluated once, against
    /// the content at that moment, and pinned down to the matched
    /// element's ordinal position. Every subsequent re-parse of `bytes`
    /// (after a splice shifts byte offsets) walks the SAME resolved
    /// path by key/index rather than re-running the predicate -- which
    /// matters once the predicate's own match condition is the very
    /// content being removed (see `removeArrayElements`'s doc comment).
    private enum ResolvedSegment {
        case key(String)
        case elementIndex(Int)
    }

    /// Runs `segments` against `root`, resolving each `.element(where:)`
    /// step to the ordinal index of the first array element (decoded via
    /// `JSONSerialization`) matching its predicate. Returns `nil` when
    /// any step can't be resolved: a `.key` naming an absent member or a
    /// non-object/array parent, or an `.element` predicate matching
    /// nothing in the current array.
    private static func resolvePath(
        _ root: JObject, segments: [JSONPathSegment], bytes: [UInt8]
    ) -> [ResolvedSegment]? {
        var resolved: [ResolvedSegment] = []
        var current: JNode = .object(root)
        for segment in segments {
            switch (segment, current) {
            case (.key(let key), .object(let obj)):
                guard let member = obj.members.first(where: { $0.key == key }) else { return nil }
                resolved.append(.key(key))
                current = member.value
            case (.element(let matches), .array(let arr)):
                guard let idx = arr.elements.firstIndex(where: { elem in
                    guard let decoded = try? JSONSerialization.jsonObject(
                        with: Data(bytes[elem.value.range]), options: [.fragmentsAllowed]
                    ) else { return false }
                    return matches(decoded)
                }) else { return nil }
                resolved.append(.elementIndex(idx))
                current = arr.elements[idx].value
            default:
                return nil
            }
        }
        return resolved
    }

    /// `keyPath` resolves to a present member: same-file backing for
    /// `JSONConfigDocumentEditor.containsValue`.
    static func containsValue(at keyPath: [String], in bytes: [UInt8]) -> Bool {
        guard let root = try? parseRootObject(bytes) else { return false }
        guard let parent = locateObject(root, path: Array(keyPath.dropLast())) else { return false }
        return parent.members.contains { $0.key == keyPath.last! }
    }

    /// `path` resolves to an array holding at least one `predicate`-
    /// matching element: same-file backing for `JSONConfigDocumentEditor
    /// .containsArrayElement`. Reuses `resolvePath` itself (appending
    /// `path`'s own terminal `.element(where:)` step) so this is
    /// exactly the same resolution `removeArrayElements` performs, not
    /// a second implementation of it.
    static func containsArrayElement(at path: [JSONPathSegment], in bytes: [UInt8], where predicate: @escaping (Any) -> Bool) -> Bool {
        guard let root = try? parseRootObject(bytes) else { return false }
        return resolvePath(root, segments: path + [.element(where: predicate)], bytes: bytes) != nil
    }

    /// The `JSONSerialization`-decoded value `path` resolves to, `nil`
    /// when it does not resolve: same-file backing for
    /// `JSONConfigDocumentEditor.decodedValue`. `parseRootObject`
    /// already throws `ConfigFileError.invalidJSON` for a document it
    /// cannot parse at all, so that error propagates unchanged.
    static func decodedValue(at path: [JSONPathSegment], in bytes: [UInt8]) throws -> Any? {
        let root = try parseRootObject(bytes)
        guard let resolved = resolvePath(root, segments: path, bytes: bytes),
              let node = locateNode(root, resolved: resolved) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: Data(bytes[node.range]), options: [.fragmentsAllowed])
    }

    /// Walks a previously `resolvePath`-resolved path against a fresh
    /// parse of the (possibly since-spliced) document, purely by key and
    /// ordinal index -- no predicate re-evaluation.
    private static func locateNode(_ root: JObject, resolved: [ResolvedSegment]) -> JNode? {
        var current: JNode = .object(root)
        for segment in resolved {
            switch (segment, current) {
            case (.key(let key), .object(let obj)):
                guard let member = obj.members.first(where: { $0.key == key }) else { return nil }
                current = member.value
            case (.elementIndex(let idx), .array(let arr)):
                guard idx < arr.elements.count else { return nil }
                current = arr.elements[idx].value
            default:
                return nil
            }
        }
        return current
    }

    /// Removes elements matching `predicate` from the array `path`
    /// addresses, one splice at a time, then applies the L1.3.1 owned-
    /// region cascade if that leaves the array empty.
    ///
    /// A `.element(where:)` segment resolves its predicate exactly once
    /// per matched element (`resolvePath`, called fresh only when
    /// looking for the NEXT unprocessed match): the predicate typically
    /// tests for the presence of the very content being removed (e.g.
    /// "this matcher group holds at least one of Calyx's own entries"),
    /// so re-running it against bytes already partway through that
    /// removal would stop matching before the removal (and the cascade
    /// it can trigger) is complete. Once an element is resolved, every
    /// splice and every cascade step against it walks the same resolved
    /// indices (`processLeafArray`, `cascadeRemove`) instead.
    static func removeArrayElements(
        at path: [JSONPathSegment], in bytes: inout [UInt8], where predicate: (Any) -> Bool
    ) throws {
        while true {
            let root = try parseRootObject(bytes)
            guard let resolved = resolvePath(root, segments: path, bytes: bytes) else { return }
            let before = bytes
            try processLeafArray(resolved, in: &bytes, where: predicate)
            // `resolvePath` succeeding does not guarantee
            // `processLeafArray` removed anything -- a `.key`-only path
            // (or an `.element` group whose leaf array holds no
            // predicate-matching element) resolves to the same node on
            // every iteration with nothing to cascade, which would
            // otherwise loop forever holding the caller's flock.
            if bytes == before { return }
        }
    }

    /// Strips every `predicate`-matching element from the array
    /// `resolved` addresses (re-parsing after each splice, since offsets
    /// shift), then cascades the removal upward through `resolved`'s own
    /// ancestor chain if the array ends up empty.
    private static func processLeafArray(
        _ resolved: [ResolvedSegment], in bytes: inout [UInt8], where predicate: (Any) -> Bool
    ) throws {
        while true {
            let root = try parseRootObject(bytes)
            guard let node = locateNode(root, resolved: resolved), case .array(let arr) = node else { return }

            var removedAny = false
            for (idx, elem) in arr.elements.enumerated() {
                let elemBytes = Array(bytes[elem.value.range])
                let decoded = try JSONSerialization.jsonObject(with: Data(elemBytes), options: [.fragmentsAllowed])
                if predicate(decoded) {
                    spliceRemoveElement(&bytes, array: arr, index: idx)
                    removedAny = true
                    break
                }
            }
            if removedAny { continue }

            if arr.elements.isEmpty {
                try cascadeRemove(resolved, in: &bytes)
            }
            return
        }
    }

    /// Removes the item `resolved`'s last segment addresses from its
    /// immediate parent, then decides whether to keep removing upward,
    /// one ancestor at a time, stopping before the root:
    ///
    /// - an ancestor reached by `.key` only keeps cascading if the
    ///   container that key named is now itself completely empty (the
    ///   L1.3.1 rule: a container whose only child was Calyx's is part
    ///   of Calyx's owned region)
    /// - an ancestor reached by `.element(where:)` always keeps
    ///   cascading: that array element exists, in this address, only to
    ///   hold the content the path is removing, so it goes as a whole
    ///   once that content is gone -- independent of any other sibling
    ///   key (e.g. a hook matcher-group's `"matcher"`) it still carries
    private static func cascadeRemove(_ resolved: [ResolvedSegment], in bytes: inout [UInt8]) throws {
        var remaining = resolved
        while let last = remaining.last {
            let ancestor = Array(remaining.dropLast())
            let root = try parseRootObject(bytes)
            guard let parentNode = locateNode(root, resolved: ancestor) else { return }

            switch (last, parentNode) {
            case (.key(let key), .object(let obj)):
                guard let idx = obj.members.firstIndex(where: { $0.key == key }) else { return }
                spliceRemoveMember(&bytes, object: obj, index: idx)
            case (.elementIndex(let idx), .array(let arr)):
                guard idx < arr.elements.count else { return }
                spliceRemoveElement(&bytes, array: arr, index: idx)
            default:
                return
            }

            guard let parentAddressing = ancestor.last else { return }

            switch parentAddressing {
            case .key:
                let rescanned = try parseRootObject(bytes)
                guard let node = locateNode(rescanned, resolved: ancestor) else { return }
                let isEmpty: Bool
                switch node {
                case .object(let obj): isEmpty = obj.members.isEmpty
                case .array(let arr): isEmpty = arr.elements.isEmpty
                case .scalar: return
                }
                guard isEmpty else { return }
            case .elementIndex:
                break
            }

            remaining = ancestor
        }
    }

    // MARK: - Navigation

    static func locateObject(_ root: JObject, path: [String]) -> JObject? {
        var current = root
        for key in path {
            guard let member = current.members.first(where: { $0.key == key }) else { return nil }
            guard case .object(let obj) = member.value else { return nil }
            current = obj
        }
        return current
    }

    /// Creates every ancestor object `keyPath` needs, one splice + rescan
    /// at a time, throwing if an existing key along the path holds
    /// something other than an object.
    static func ensureAncestorObjects(_ keyPath: [String], in bytes: inout [UInt8]) throws {
        guard !keyPath.isEmpty else { return }
        for depth in 1...keyPath.count {
            let ancestorPath = Array(keyPath.prefix(depth - 1))
            let key = keyPath[depth - 1]
            let root = try parseRootObject(bytes)
            guard let parent = locateObject(root, path: ancestorPath) else {
                throw JSONConfigDocumentEditor.EditorError.typeConflict(ancestorPath.last ?? "")
            }
            if let existing = parent.members.first(where: { $0.key == key }) {
                guard case .object = existing.value else {
                    throw JSONConfigDocumentEditor.EditorError.typeConflict(key)
                }
                continue
            }
            try insertMember(key: key, value: Array("{}".utf8), into: parent, depth: depth, bytes: &bytes)
        }
    }

    // MARK: - Insertion

    static func insertMember(key: String, value: [UInt8], into parent: JObject, depth: Int, bytes: inout [UInt8]) throws {
        let keyBytes = Array(encodeJSONString(key).utf8)
        if let last = parent.members.last {
            let prefix = Array(bytes[last.gapBefore])
            let colonSep = Array(bytes[(last.colonPos + 1)..<last.value.range.lowerBound])
            let insertionPos = last.value.range.upperBound
            let reindented = reindentValue(value, contextBytes: bytes, insertionPoint: insertionPos, depth: depth)
            var inserted: [UInt8] = [UInt8(ascii: ",")]
            inserted.append(contentsOf: prefix)
            inserted.append(contentsOf: keyBytes)
            inserted.append(UInt8(ascii: ":"))
            inserted.append(contentsOf: colonSep)
            inserted.append(contentsOf: reindented)
            bytes.insert(contentsOf: inserted, at: insertionPos)
        } else {
            let unit = detectIndentUnit(bytes)
            let eol = nearestEOL(bytes, around: parent.openBrace)
            var gap: [UInt8] = []
            var closingGap: [UInt8] = []
            if !unit.isEmpty {
                gap.append(contentsOf: eol)
                for _ in 0..<depth { gap.append(contentsOf: unit) }
                closingGap.append(contentsOf: eol)
                for _ in 0..<(depth - 1) { closingGap.append(contentsOf: unit) }
            }
            let reindented = reindentValue(value, contextBytes: bytes, insertionPoint: parent.openBrace + 1, depth: depth)
            var inserted: [UInt8] = []
            inserted.append(contentsOf: gap)
            inserted.append(contentsOf: keyBytes)
            inserted.append(UInt8(ascii: ":"))
            if !unit.isEmpty { inserted.append(UInt8(ascii: " ")) }
            inserted.append(contentsOf: reindented)
            inserted.append(contentsOf: closingGap)
            bytes.replaceSubrange((parent.openBrace + 1)..<parent.closeBrace, with: inserted)
        }
    }

    static func insertArrayElement(_ element: [UInt8], into array: JArray, depth: Int, bytes: inout [UInt8]) throws {
        if let last = array.elements.last {
            let prefix = Array(bytes[last.gapBefore])
            let insertionPos = last.value.range.upperBound
            let reindented = reindentValue(element, contextBytes: bytes, insertionPoint: insertionPos, depth: depth + 1)
            var inserted: [UInt8] = [UInt8(ascii: ",")]
            inserted.append(contentsOf: prefix)
            inserted.append(contentsOf: reindented)
            bytes.insert(contentsOf: inserted, at: insertionPos)
        } else {
            let unit = detectIndentUnit(bytes)
            let eol = nearestEOL(bytes, around: array.openBracket)
            var gap: [UInt8] = []
            var closingGap: [UInt8] = []
            if !unit.isEmpty {
                gap.append(contentsOf: eol)
                for _ in 0..<(depth + 1) { gap.append(contentsOf: unit) }
                closingGap.append(contentsOf: eol)
                for _ in 0..<depth { closingGap.append(contentsOf: unit) }
            }
            let reindented = reindentValue(element, contextBytes: bytes, insertionPoint: array.openBracket + 1, depth: depth + 1)
            var inserted: [UInt8] = []
            inserted.append(contentsOf: gap)
            inserted.append(contentsOf: reindented)
            inserted.append(contentsOf: closingGap)
            bytes.replaceSubrange((array.openBracket + 1)..<array.closeBracket, with: inserted)
        }
    }

    // MARK: - Removal splicing

    /// Deletes `object.members[index]` and repairs the surrounding comma,
    /// whether the member is first, middle, or last among its siblings: a
    /// non-last member's own `gapBefore` slides in to become its
    /// successor's, so deleting up to the successor's `gapBefore` start
    /// removes exactly the member plus its trailing comma; the last
    /// member instead has no successor to inherit from, so deletion runs
    /// from the end of the previous member's value (i.e. the comma before
    /// it) through this member's own end.
    static func spliceRemoveMember(_ bytes: inout [UInt8], object: JObject, index: Int) {
        let members = object.members
        let deleteRange: Range<Int>
        if members.count == 1 {
            deleteRange = (object.openBrace + 1)..<object.closeBrace
        } else if index < members.count - 1 {
            deleteRange = members[index].gapBefore.lowerBound..<members[index + 1].gapBefore.lowerBound
        } else {
            deleteRange = members[index - 1].value.range.upperBound..<members[index].value.range.upperBound
        }
        bytes.removeSubrange(deleteRange)
    }

    static func spliceRemoveElement(_ bytes: inout [UInt8], array: JArray, index: Int) {
        let elements = array.elements
        let deleteRange: Range<Int>
        if elements.count == 1 {
            deleteRange = (array.openBracket + 1)..<array.closeBracket
        } else if index < elements.count - 1 {
            deleteRange = elements[index].gapBefore.lowerBound..<elements[index + 1].gapBefore.lowerBound
        } else {
            deleteRange = elements[index - 1].value.range.upperBound..<elements[index].value.range.upperBound
        }
        bytes.removeSubrange(deleteRange)
    }

    // MARK: - Formatting

    /// The whitespace run right after the first `\n` that's immediately
    /// followed by a `"` -- i.e. the indent of the first indented member
    /// key anywhere in the document. Empty when the document has no
    /// indented member (a fully single-line document), which is exactly
    /// the signal `insertMember`/`insertArrayElement` use to stay compact
    /// when creating a brand new, sibling-less container.
    static func detectIndentUnit(_ bytes: [UInt8]) -> [UInt8] {
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "\n") {
                let wsStart = i + 1
                var j = wsStart
                while j < bytes.count, bytes[j] == UInt8(ascii: " ") || bytes[j] == UInt8(ascii: "\t") {
                    j += 1
                }
                if j > wsStart, j < bytes.count, bytes[j] == UInt8(ascii: "\"") {
                    return Array(bytes[wsStart..<j])
                }
            }
            i += 1
        }
        return []
    }

    /// The line ending nearest `index`: the terminator of the line just
    /// before it if one exists, else the terminator of the next line, else
    /// `"\n"` for a document with no newlines at all to detect one from.
    static func nearestEOL(_ bytes: [UInt8], around index: Int) -> [UInt8] {
        var i = min(index, bytes.count) - 1
        while i >= 0 {
            if bytes[i] == UInt8(ascii: "\n") {
                if i > 0, bytes[i - 1] == UInt8(ascii: "\r") {
                    return [UInt8(ascii: "\r"), UInt8(ascii: "\n")]
                }
                return [UInt8(ascii: "\n")]
            }
            i -= 1
        }
        var j = index
        while j < bytes.count {
            if bytes[j] == UInt8(ascii: "\n") {
                if j > 0, bytes[j - 1] == UInt8(ascii: "\r") {
                    return [UInt8(ascii: "\r"), UInt8(ascii: "\n")]
                }
                return [UInt8(ascii: "\n")]
            }
            j += 1
        }
        return [UInt8(ascii: "\n")]
    }

    static func encodeJSONString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += "\\u" + String(format: "%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    /// Re-lays-out `value`'s bytes (built by the caller, not re-parsed or
    /// re-emitted through `JSONSerialization`) so a multi-line value lands
    /// at the right indentation for the site it's being spliced into. The
    /// first line is left untouched (it follows directly after `"key": `
    /// on the existing line), and each subsequent line's leading
    /// whitespace is replaced by `unit` repeated `depth + relativeDepth`
    /// times, where `relativeDepth` is that line's own indentation
    /// measured in units of the *value's own* first indent (so the
    /// value's internal nesting is preserved even though its absolute
    /// indentation changes). A single-line value is returned unchanged.
    static func reindentValue(_ value: [UInt8], contextBytes: [UInt8], insertionPoint: Int, depth: Int) -> [UInt8] {
        var lines: [[UInt8]] = []
        var current: [UInt8] = []
        for b in value {
            if b == UInt8(ascii: "\n") {
                if current.last == UInt8(ascii: "\r") { current.removeLast() }
                lines.append(current)
                current = []
            } else {
                current.append(b)
            }
        }
        lines.append(current)
        guard lines.count > 1 else { return value }

        let unit = detectIndentUnit(contextBytes)
        let eol = nearestEOL(contextBytes, around: insertionPoint)

        var valueUnitLen = 0
        for line in lines.dropFirst() {
            let wsLen = line.prefix(while: { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }).count
            if wsLen > 0 { valueUnitLen = wsLen; break }
        }

        var result: [UInt8] = lines[0]
        for line in lines.dropFirst() {
            result.append(contentsOf: eol)
            let wsLen = line.prefix(while: { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }).count
            let relativeDepth = valueUnitLen > 0 ? wsLen / valueUnitLen : 0
            if !unit.isEmpty {
                for _ in 0..<(depth + relativeDepth) {
                    result.append(contentsOf: unit)
                }
            }
            result.append(contentsOf: line.dropFirst(wsLen))
        }
        return result
    }
}
