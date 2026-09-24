//
//  MCPAppUnsupportedMethods.swift
//  Calyx
//
//  View requests Calyx never declares. Calyx has no model, so
//  `sampling/createMessage` is always method-not-found.
//

import Foundation

enum MCPAppUnsupportedMethods {
    static func errorForSampling() -> JSONRPCError {
        JSONRPCError(code: -32601, message: "sampling/createMessage is not supported by this host.", data: nil)
    }
}
