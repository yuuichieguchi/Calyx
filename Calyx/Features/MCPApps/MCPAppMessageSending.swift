//
//  MCPAppMessageSending.swift
//  Calyx
//
//  Formats a consented `ui/message` and hands the text to a delivery
//  path, mapping every failure to the -32000 the view receives.
//

import Foundation

enum MCPAppMessageSending {
    /// `{}` when delivered. A formatting failure (an image that cannot be
    /// written) or a delivery failure is -32000, and nothing is delivered
    /// after a formatting failure. Runs `deliver` in the caller's isolation.
    static func send(
        _ blocks: [MCPMessageContentBlock],
        imageDirectory: URL = MCPAppMessageFormatter.imageDirectory,
        isolation: isolated (any Actor)? = #isolation,
        deliver: (String) async throws -> Void
    ) async -> Result<AnyCodable, JSONRPCError> {
        let text: String
        do {
            text = try MCPAppMessageFormatter.format(content: blocks, imageDirectory: imageDirectory).pastedText
        } catch {
            return .failure(JSONRPCError(code: -32000, message: "The message could not be prepared: \(error)", data: nil))
        }
        do {
            try await deliver(text)
        } catch {
            return .failure(JSONRPCError(code: -32000, message: "The message could not be delivered: \(error)", data: nil))
        }
        return .success(AnyCodable([String: AnyCodable]()))
    }
}
