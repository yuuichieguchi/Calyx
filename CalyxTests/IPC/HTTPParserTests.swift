import XCTest
@testable import Calyx

final class HTTPParserTests: XCTestCase {

    // MARK: - Helpers

    /// Build raw HTTP request data from a request line, headers, and optional body.
    private func makeRawRequest(
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: String? = nil
    ) -> Data {
        var lines = ["\(method) \(path) HTTP/1.1"]
        for (key, value) in headers {
            lines.append("\(key): \(value)")
        }
        if let body {
            let bodyData = body.data(using: .utf8)!
            // Only add Content-Length if not already provided explicitly
            if headers["Content-Length"] == nil
                && headers["content-length"] == nil {
                lines.append("Content-Length: \(bodyData.count)")
            }
        }
        let headerBlock = lines.joined(separator: "\r\n") + "\r\n\r\n"
        var data = headerBlock.data(using: .utf8)!
        if let body {
            data.append(body.data(using: .utf8)!)
        }
        return data
    }

    /// Build raw HTTP request data from a raw string (for malformed / edge-case tests).
    private func makeRawData(_ string: String) -> Data {
        Data(string.utf8)
    }

    // MARK: - Happy Path: POST

    func test_parseValidPostRequest() throws {
        let raw = makeRawRequest(
            method: "POST",
            path: "/mcp",
            headers: [
                "Content-Type": "application/json",
            ],
            body: "{}"
        )

        let request = try HTTPParser.parse(raw)

        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/mcp")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertNotNil(request.body)
        XCTAssertEqual(String(data: request.body!, encoding: .utf8), "{}")
    }

    // MARK: - Happy Path: GET

    func test_parseValidGetRequest() throws {
        let raw = makeRawRequest(
            method: "GET",
            path: "/health",
            headers: ["Host": "localhost"]
        )

        let request = try HTTPParser.parse(raw)

        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/health")
        XCTAssertEqual(request.headers["Host"], "localhost")
        XCTAssertNil(request.body)
    }

    // MARK: - Header Parsing: Authorization

    func test_parseRequestWithAuthorization() throws {
        let raw = makeRawRequest(
            method: "GET",
            path: "/secure",
            headers: [
                "Host": "localhost",
                "Authorization": "Bearer abc123",
            ]
        )

        let request = try HTTPParser.parse(raw)

        XCTAssertEqual(request.headers["Authorization"], "Bearer abc123")
    }

    // MARK: - Error: Header Too Large

    func test_headerTooLarge_throws() {
        // Build a header block that exceeds 8KB
        let hugeValue = String(repeating: "X", count: HTTPParser.maxHeaderSize + 1)
        let raw = makeRawRequest(
            method: "GET",
            path: "/",
            headers: ["X-Large": hugeValue]
        )

        XCTAssertThrowsError(try HTTPParser.parse(raw)) { error in
            XCTAssertEqual(error as? HTTPParseError, .headerTooLarge)
        }
    }

    // MARK: - Error: Body Too Large

    func test_bodyTooLarge_throws() {
        // Content-Length claims more than 1MB
        let oversizedLength = HTTPParser.maxBodySize + 1
        let rawString =
            "POST /upload HTTP/1.1\r\n"
            + "Content-Length: \(oversizedLength)\r\n"
            + "\r\n"
        let raw = makeRawData(rawString)

        XCTAssertThrowsError(try HTTPParser.parse(raw)) { error in
            XCTAssertEqual(error as? HTTPParseError, .bodyTooLarge)
        }
    }

    // MARK: - Error: Invalid Content-Length (Negative)

    func test_invalidContentLength_negative_throws() {
        let rawString =
            "POST /data HTTP/1.1\r\n"
            + "Content-Length: -1\r\n"
            + "\r\n"
        let raw = makeRawData(rawString)

        XCTAssertThrowsError(try HTTPParser.parse(raw)) { error in
            XCTAssertEqual(error as? HTTPParseError, .invalidContentLength)
        }
    }

    // MARK: - Error: Invalid Content-Length (Non-Numeric)

    func test_invalidContentLength_nonNumeric_throws() {
        let rawString =
            "POST /data HTTP/1.1\r\n"
            + "Content-Length: abc\r\n"
            + "\r\n"
        let raw = makeRawData(rawString)

        XCTAssertThrowsError(try HTTPParser.parse(raw)) { error in
            XCTAssertEqual(error as? HTTPParseError, .invalidContentLength)
        }
    }

    // MARK: - Error: Malformed Request

    func test_malformedRequest_throws() {
        let garbage = makeRawData("not an http request at all\u{00}\u{01}\u{02}")

        XCTAssertThrowsError(try HTTPParser.parse(garbage)) { error in
            XCTAssertEqual(error as? HTTPParseError, .malformedRequest)
        }
    }

    // MARK: - Response Serialization: 200 OK

    func test_responseSerialize_200() {
        let body = "{}".data(using: .utf8)!
        let response = HTTPResponse(
            statusCode: 200,
            statusMessage: "OK",
            headers: ["Content-Type": "application/json"],
            body: body
        )

        let serialized = response.serialize()
        let text = String(data: serialized, encoding: .utf8)!

        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{}"))
    }

    // MARK: - Response Serialization: 401 Unauthorized

    func test_responseSerialize_401() {
        let body = "{\"error\":\"unauthorized\"}".data(using: .utf8)!
        let response = HTTPResponse(
            statusCode: 401,
            statusMessage: "Unauthorized",
            headers: ["Content-Type": "application/json"],
            body: body
        )

        let serialized = response.serialize()
        let text = String(data: serialized, encoding: .utf8)!

        XCTAssertTrue(text.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        XCTAssertTrue(text.contains("Content-Length: \(body.count)\r\n"))
        XCTAssertTrue(text.contains("{\"error\":\"unauthorized\"}"))
    }

    // MARK: - Response Serialization: 413 Payload Too Large

    func test_responseSerialize_413() {
        let body = "{\"error\":\"payload too large\"}".data(using: .utf8)!
        let response = HTTPResponse(
            statusCode: 413,
            statusMessage: "Payload Too Large",
            headers: ["Content-Type": "application/json"],
            body: body
        )

        let serialized = response.serialize()
        let text = String(data: serialized, encoding: .utf8)!

        XCTAssertTrue(text.hasPrefix("HTTP/1.1 413 Payload Too Large\r\n"))
        XCTAssertTrue(text.contains("{\"error\":\"payload too large\"}"))
    }

    // MARK: - Response JSON Helper

    func test_response_json_helper() throws {
        let response = HTTPParser.response(
            statusCode: 200,
            json: ["key": "value"]
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["Content-Type"], "application/json")

        let body = try XCTUnwrap(response.body)
        let parsed = try JSONSerialization.jsonObject(with: body) as? [String: String]
        XCTAssertEqual(parsed?["key"], "value")
    }

    // MARK: - Edge Case: Content-Length Mismatch (Body Too Short)

    func test_contentLengthMismatch_bodyTooShort() {
        // Content-Length says 100 but actual body is only 5 bytes
        let rawString =
            "POST /data HTTP/1.1\r\n"
            + "Content-Length: 100\r\n"
            + "\r\n"
            + "hello"
        let raw = makeRawData(rawString)

        // Parser should either return partial body or throw malformedRequest.
        // We accept either behavior — the key is it must not crash.
        do {
            let request = try HTTPParser.parse(raw)
            // If it succeeds, body should be what was actually available
            if let body = request.body {
                XCTAssertLessThanOrEqual(body.count, 100,
                    "Body must not exceed claimed Content-Length")
            }
        } catch {
            XCTAssertEqual(error as? HTTPParseError, .malformedRequest,
                "Content-Length mismatch should throw malformedRequest if treated as error")
        }
    }

    // MARK: - Edge Case: Case-Insensitive Headers

    func test_caseInsensitiveHeaders() throws {
        let rawString =
            "POST /data HTTP/1.1\r\n"
            + "content-type: application/json\r\n"
            + "content-length: 2\r\n"
            + "\r\n"
            + "{}"
        let raw = makeRawData(rawString)

        // Should parse successfully regardless of header casing
        let request = try HTTPParser.parse(raw)

        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/data")
        XCTAssertNotNil(request.body)
        XCTAssertEqual(String(data: request.body!, encoding: .utf8), "{}")

        // Headers should be accessible (parser may normalize or preserve case)
        let contentType = request.headers["Content-Type"]
            ?? request.headers["content-type"]
        XCTAssertEqual(contentType, "application/json",
            "content-type header must be parseable regardless of case")
    }

    // MARK: - Edge Case: Empty Body with Zero Content-Length

    func test_emptyBody_withZeroContentLength() throws {
        let rawString =
            "POST /empty HTTP/1.1\r\n"
            + "Content-Length: 0\r\n"
            + "\r\n"
        let raw = makeRawData(rawString)

        let request = try HTTPParser.parse(raw)

        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/empty")

        // Body should be nil or empty Data — either is acceptable
        if let body = request.body {
            XCTAssertTrue(body.isEmpty, "Body with Content-Length: 0 should be empty")
        }
        // nil is also fine — no assertion needed for that case
    }

    // MARK: - Constants Verification

    func test_maxHeaderSize_is8KB() {
        XCTAssertEqual(HTTPParser.maxHeaderSize, 8 * 1024)
    }

    func test_maxBodySize_is1MB() {
        XCTAssertEqual(HTTPParser.maxBodySize, 1 * 1024 * 1024)
    }
}
