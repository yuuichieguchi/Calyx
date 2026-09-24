//
//  MCPAppMessageFormatter.swift
//  Calyx
//
//  Turns `ui/message` content into what is pasted into the pane. Text has
//  no length limit and is pasted inline; images are written to files and
//  their paths pasted instead.
//

import Foundation

enum MCPMessageContentBlock: Sendable, Equatable {
    case text(String)
    case image(base64: String, mimeType: String)
}

enum MCPAppMessageFormatter {

    /// Where image content is written.
    static var imageDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("calyx-mcp-apps", isDirectory: true)
    }

    /// Drops C0 controls except newline and tab, DEL, and C1 controls;
    /// turns CR and CRLF into LF.
    static func sanitizeControlCharacters(_ s: String) -> String {
        var output = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in s.unicodeScalars {
            defer { previousWasCR = scalar == "\r" }
            switch scalar.value {
            case 0x0D:
                output.append("\n")
            case 0x0A:
                if !previousWasCR { output.append(scalar) }
            case 0x09:
                output.append(scalar)
            case 0x00...0x1F, 0x7F, 0x80...0x9F:
                continue
            default:
                output.append(scalar)
            }
        }
        return String(output)
    }

    /// Blocks are joined with newlines, in order. Images are written under
    /// `imageDirectory`; an undecodable image or a failed write throws.
    static func format(content: [MCPMessageContentBlock]) throws -> (pastedText: String, writtenFilePaths: [String]) {
        try format(content: content, imageDirectory: imageDirectory)
    }

    /// `format(content:)` writing images under `directory`.
    static func format(
        content: [MCPMessageContentBlock],
        imageDirectory directory: URL
    ) throws -> (pastedText: String, writtenFilePaths: [String]) {
        var parts: [String] = []
        var paths: [String] = []
        for block in content {
            switch block {
            case .text(let text):
                parts.append(sanitizeControlCharacters(text))
            case .image(let base64, let mimeType):
                guard let data = Data(base64Encoded: base64) else {
                    throw MCPAppMessageFormatterError.invalidBase64
                }
                let url = directory.appendingPathComponent(
                    "image-\(UUID().uuidString.lowercased()).\(fileExtension(for: mimeType))"
                )
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic])
                paths.append(url.path)
                parts.append(url.path)
            }
        }
        return (parts.joined(separator: "\n"), paths)
    }

    /// The MIME subtype, letters and digits only, before any `+` suffix or
    /// parameter (`image/svg+xml` becomes `svg`, `image/jpeg` becomes `jpg`).
    static func fileExtension(for mimeType: String) -> String {
        let essence = mimeType.lowercased().split(separator: ";").first ?? ""
        let subtype = essence.split(separator: "/").last ?? ""
        let base = subtype.split(separator: "+").first ?? ""
        let cleaned = String(base.filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
        switch cleaned {
        case "jpeg": return "jpg"
        case "": return "bin"
        default: return cleaned
        }
    }
}

enum MCPAppMessageFormatterError: Error, Equatable {
    /// An image block's data is not base64.
    case invalidBase64
}
