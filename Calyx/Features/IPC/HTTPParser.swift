// HTTPParser.swift
// Calyx
//
// Lightweight HTTP/1.1 parser for the IPC MCP server.

import Foundation

// MARK: - HTTPRequest

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?
}

// MARK: - HTTPResponse

struct HTTPResponse: Sendable {
    let statusCode: Int
    let statusMessage: String
    let headers: [String: String]
    let body: Data?

    func serialize() -> Data {
        var result = "HTTP/1.1 \(statusCode) \(statusMessage)\r\n"

        // Write headers
        for (key, value) in headers {
            result += "\(key): \(value)\r\n"
        }

        // Add Content-Length if not already present
        let hasContentLength = headers.contains { $0.key.lowercased() == "content-length" }
        if !hasContentLength {
            let length = body?.count ?? 0
            result += "Content-Length: \(length)\r\n"
        }

        result += "\r\n"

        var data = Data(result.utf8)
        if let body {
            data.append(body)
        }
        return data
    }
}

// MARK: - HTTPParseError

enum HTTPParseError: Error, Equatable {
    case headerTooLarge
    case bodyTooLarge
    case invalidContentLength
    case malformedRequest
    case timeout
}

// MARK: - HTTPParser

struct HTTPParser {

    static let maxHeaderSize: Int = 8 * 1024      // 8KB
    static let maxBodySize: Int = 1 * 1024 * 1024  // 1MB

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    // MARK: - Parse

    static func parse(_ data: Data) throws -> HTTPRequest {
        // Find the header/body separator "\r\n\r\n"
        guard let separatorRange = data.range(of: headerTerminator) else {
            if data.count > maxHeaderSize {
                throw HTTPParseError.headerTooLarge
            }
            throw HTTPParseError.malformedRequest
        }

        let headerEndIndex = separatorRange.lowerBound
        if headerEndIndex > maxHeaderSize {
            throw HTTPParseError.headerTooLarge
        }

        // Extract header portion as string
        let headerData = data[data.startIndex..<headerEndIndex]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw HTTPParseError.malformedRequest
        }

        // Split into lines by \r\n
        let lines = headerString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            throw HTTPParseError.malformedRequest
        }

        // Parse request line: "METHOD PATH HTTP/1.x"
        let requestLineParts = lines[0].split(separator: " ", maxSplits: 2)
        guard requestLineParts.count >= 2 else {
            throw HTTPParseError.malformedRequest
        }

        let method = String(requestLineParts[0])
        let path = String(requestLineParts[1])

        // Parse headers
        var headers: [String: String] = [:]
        for i in 1..<lines.count {
            let line = lines[i]
            if line.isEmpty { continue }
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colonIndex])
            let valueStart = line.index(after: colonIndex)
            let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        // Content-Length lookup/validation is shared with
        // `completeness(of:)` (`CalyxMCPServer`'s pre-parse
        // buffer-completeness gate) via `contentLength(inHeaderString:)`
        // — see that function's doc comment for why, and for the
        // documented behavior change to duplicate-header handling this
        // introduced.
        let contentLength: Int?
        switch Self.contentLength(inHeaderString: headerString) {
        case .success(let value):
            contentLength = value
        case .failure(let error):
            throw error
        }

        var body: Data?

        if let length = contentLength {
            if length > maxBodySize {
                throw HTTPParseError.bodyTooLarge
            }

            if length == 0 {
                // Content-Length: 0 → nil body
                body = nil
            } else {
                // Extract body bytes starting after the separator
                let bodyStart = separatorRange.upperBound
                if bodyStart < data.endIndex {
                    let available = data[bodyStart..<data.endIndex]
                    let take = min(length, available.count)
                    body = Data(available.prefix(take))
                }
            }
        }

        return HTTPRequest(
            method: method,
            path: path,
            headers: headers,
            body: body
        )
    }

    // MARK: - Shared Content-Length Lookup

    /// Case-insensitive `Content-Length` header value lookup within a
    /// raw header block string (exactly the `headerString` `parse(_:)`
    /// decodes from the bytes before `\r\n\r\n` — request line included).
    /// Shared by `parse(_:)` and `CalyxMCPServer`'s pre-parse
    /// buffer-completeness gate (`completeness(of:)`) so a request with
    /// a duplicate or mixed-case `Content-Length` header is resolved
    /// identically by whichever of the two runs first.
    ///
    /// The request line (`headerString`'s first `\r\n`-delimited line,
    /// e.g. `POST /mcp HTTP/1.1`) is deliberately skipped via
    /// `.dropFirst()` below — matching `parse(_:)`'s own header
    /// dictionary, which has only ever been built from `lines[1...]`.
    /// Without this, a pathological (but `parse(_:)`'s own lenient
    /// `lines[0].split(separator: " ", maxSplits: 2)` request-line
    /// parser accepts) request line shaped like `Content-Length: 5 x`
    /// would itself be picked up as a genuine `Content-Length`
    /// declaration.
    ///
    /// Takes the *first* occurrence (after the request line) in
    /// document order, case-insensitively. This is a deliberate
    /// behavior change from `parse(_:)`'s previous, independent lookup
    /// (`headers.first { $0.key.lowercased() == "content-length" }`
    /// over a `[String: String]` built by `headers[key] = value`, which
    /// favors whichever *differently-cased* duplicate the Dictionary's
    /// unordered storage happens to iterate to first — non-deterministic
    /// for mixed-case duplicates, though deterministic — last-one-wins —
    /// for same-case duplicates). The non-duplicate common case is
    /// unaffected either way.
    ///
    /// Returns `.success(nil)` when no `Content-Length` header is
    /// present (no body expected), `.success(length)` for a valid
    /// non-negative value, or `.failure(.invalidContentLength)` for a
    /// header present but not parseable as one.
    static func contentLength(inHeaderString headerString: String) -> Result<Int?, HTTPParseError> {
        for line in headerString.components(separatedBy: "\r\n").dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colonIndex]
            guard key.caseInsensitiveCompare("Content-Length") == .orderedSame else { continue }
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            guard let length = Int(value), length >= 0 else {
                return .failure(.invalidContentLength)
            }
            return .success(length)
        }
        return .success(nil)
    }

    // MARK: - Buffer Completeness (pre-parse)

    /// Whether an in-progress connection read buffer (accumulated by
    /// `CalyxMCPServer.receiveUntilComplete` across possibly many
    /// `NWConnection.receive` chunks) holds a complete HTTP request,
    /// still needs more data before `parse(_:)` can be called, or has
    /// already exceeded the size `parse(_:)` would accept.
    enum Completeness: Equatable {
        case incomplete
        case complete
        case tooLarge
    }

    /// Cheap completeness check over an in-progress read `buffer` —
    /// deliberately not a full `parse(_:)` call, which assumes (and
    /// continues to assume — its own contract is unchanged) that it is
    /// only ever handed a complete buffer. Looks for the header/body
    /// separator `\r\n\r\n`; once present, reads only the
    /// `Content-Length` header's value (via
    /// `contentLength(inHeaderString:)` — the same lookup `parse(_:)`
    /// itself now uses) to determine how many total bytes the full
    /// request needs.
    ///
    /// Also returns `requiredTotal`, the exact byte count a complete
    /// request needs, once knowable (i.e. once the header terminator
    /// has been found) — `nil` only while `state == .incomplete` and
    /// the terminator itself hasn't appeared yet. A caller accumulating
    /// many small chunks can cache this and skip re-invoking this
    /// header-terminator search on every subsequent chunk, comparing
    /// the buffer's growing byte count against the cached total
    /// directly instead.
    ///
    /// The `contentLength > maxBodySize` check below happens *before*
    /// computing `headerLength + contentLength` deliberately: a
    /// client-declared `Content-Length` near `Int.max` (e.g. the
    /// literal `9223372036854775807`) would otherwise overflow that
    /// addition and trap the process — a pre-authentication crash any
    /// client could trigger with a single header line. Bounding
    /// `contentLength` alone first closes that off entirely, and
    /// doubles as this gate's size threshold matching `parse(_:)`'s own
    /// `length > maxBodySize` rejection exactly (a buffer that this
    /// gate would keep waiting on because `headerLength + contentLength`
    /// stayed under some looser combined cap, but that `parse(_:)`
    /// would then still reject as `.bodyTooLarge`, is exactly the kind
    /// of gate/parse threshold mismatch this avoids).
    static func completeness(of buffer: Data) -> (state: Completeness, requiredTotal: Int?) {
        guard let separatorRange = buffer.range(of: headerTerminator) else {
            let state: Completeness = buffer.count > maxHeaderSize ? .tooLarge : .incomplete
            return (state, nil)
        }

        let headerBlockLength = buffer.distance(from: buffer.startIndex, to: separatorRange.lowerBound)
        if headerBlockLength > maxHeaderSize {
            return (.tooLarge, nil)
        }

        let headerLength = buffer.distance(from: buffer.startIndex, to: separatorRange.upperBound)
        let headerBlock = buffer[buffer.startIndex..<separatorRange.lowerBound]
        guard let headerString = String(data: headerBlock, encoding: .utf8) else {
            // Not decodable — `parse(_:)`'s own `headerString` decode
            // will fail identically and raise `.malformedRequest` once
            // handed this buffer; nothing further to wait for.
            return (.complete, headerLength)
        }

        let parsedContentLength: Int?
        switch contentLength(inHeaderString: headerString) {
        case .success(let value):
            parsedContentLength = value
        case .failure:
            // Invalid `Content-Length` — `parse(_:)` raises
            // `.invalidContentLength` itself once handed this buffer.
            return (.complete, headerLength)
        }

        guard let parsedContentLength else {
            // No `Content-Length` header at all — `parse(_:)` has no
            // body to extract either way.
            return (.complete, headerLength)
        }

        if parsedContentLength > maxBodySize {
            return (.tooLarge, nil)
        }

        let requiredTotal = headerLength + parsedContentLength
        let state: Completeness = buffer.count >= requiredTotal ? .complete : .incomplete
        return (state, requiredTotal)
    }

    // MARK: - Response Builders

    static func response(
        statusCode: Int,
        body: Data?,
        contentType: String = "application/json"
    ) -> HTTPResponse {
        let statusMessage = Self.statusMessage(for: statusCode)

        var headers: [String: String] = [
            "Content-Type": contentType,
            "Connection": "close",
        ]

        let length = body?.count ?? 0
        headers["Content-Length"] = "\(length)"

        return HTTPResponse(
            statusCode: statusCode,
            statusMessage: statusMessage,
            headers: headers,
            body: body
        )
    }

    static func response(statusCode: Int, json: Any) -> HTTPResponse {
        let body: Data?
        if let data = try? JSONSerialization.data(withJSONObject: json) {
            body = data
        } else {
            body = nil
        }
        return response(statusCode: statusCode, body: body, contentType: "application/json")
    }

    // MARK: - Status Messages

    private static func statusMessage(for code: Int) -> String {
        switch code {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 413: "Payload Too Large"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Unknown"
        }
    }
}
