//
//  MCPOAuthIssuerValidator.swift
//  Calyx
//
//  RFC 9207 section 2.4 validation of the authorization response's `iss`
//  parameter. The comparison is exact: no case folding, default-port
//  elision, trailing-slash or percent-encoding normalization.
//

import Foundation

enum MCPOAuthIssuerValidationError: Error, Sendable, Equatable {
    case missing
    case mismatch
}

enum MCPOAuthIssuerValidator {

    /// A present `iss` is always compared, whether or not the server
    /// advertises it. An absent `iss` fails only when the server advertises
    /// `authorization_response_iss_parameter_supported`.
    static func validate(issuerParameter: String?, recordedIssuer: String, serverAdvertisesIss: Bool) -> Result<Void, MCPOAuthIssuerValidationError> {
        guard let issuerParameter else {
            return serverAdvertisesIss ? .failure(.missing) : .success(())
        }
        return issuerParameter == recordedIssuer ? .success(()) : .failure(.mismatch)
    }
}
