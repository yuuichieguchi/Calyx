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

        // Look up Content-Length (case-insensitive)
        let contentLengthValue = headers.first { $0.key.lowercased() == "content-length" }?.value

        var body: Data?

        if let lengthString = contentLengthValue {
            guard let length = Int(lengthString) else {
                throw HTTPParseError.invalidContentLength
            }
            if length < 0 {
                throw HTTPParseError.invalidContentLength
            }
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
