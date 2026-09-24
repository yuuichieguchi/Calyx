//
//  MCPConnectionFailureText.swift
//  Calyx
//
//  The one-sentence `MCPConnectionFailure.reason` Settings shows for a
//  server that could not connect or kept crashing. Built from the error
//  the connection attempt threw and, when the transport was lost, how the
//  child process ended.
//

import Foundation

enum MCPConnectionFailureText {

    /// Why a connection attempt failed. `error` is what the attempt
    /// threw: a handshake error, an error of a request after the
    /// handshake, or an error from creating the transport. `exit` is how
    /// the child ended when the transport was lost during the attempt.
    static func connectFailure(
        _ error: any Error,
        exit: MCPTransportExitInfo?,
        requestTimeout: TimeInterval,
        handshakeOrder: MCPHandshakeOrder
    ) -> String {
        switch error {
        case let negotiation as MCPNegotiationError:
            switch negotiation {
            case .handshakeFailed(let initialize, let discover):
                let failures = (handshakeOrder == .initializeFirst ? [initialize, discover] : [discover, initialize])
                    .compactMap { $0 }
                guard let failure = failures.first(where: isTransportClosed) ?? failures.first else {
                    return "The server's handshake replies could not be read."
                }
                return sentence(failure, exit: exit, requestTimeout: requestTimeout, phase: "during the handshake")
            case .legacySSERequired:
                return "The server rejected both Streamable HTTP and legacy HTTP+SSE requests."
            case .authorizationRequired(let signal):
                return "The server requires sign-in (HTTP \(signal.httpStatus.map(String.init) ?? "401"))."
            }
        case let protocolError as MCPClientProtocolError:
            return sentence(protocolError, exit: exit, requestTimeout: requestTimeout, phase: "while loading its tools")
        case MCPTransportError.closed:
            return exit.map { exitSentence($0, phase: "during the handshake") }
                ?? "The connection closed during the handshake."
        case let urlError as URLError:
            return "Could not reach the server: \(urlError.localizedDescription)"
        default:
            return "The server could not be started: \(describe(error))"
        }
    }

    /// Why a connection that was lost too many times in a row stopped
    /// restarting: how the child ended, or the transport's reason.
    static func connectionLost(reason: String, exit: MCPTransportExitInfo?) -> String {
        guard let exit else { return "The connection closed: \(reason)." }
        return exitSentence(exit, phase: nil)
    }

    /// Whether `error` means the transport was lost, so the child's exit
    /// and stderr are available.
    static func transportWasLost(_ error: any Error) -> Bool {
        switch error {
        case MCPNegotiationError.handshakeFailed(let initialize, let discover):
            return [initialize, discover].contains { $0.map(isTransportClosed) ?? false }
        case let protocolError as MCPClientProtocolError:
            return isTransportClosed(protocolError)
        case MCPTransportError.closed:
            return true
        default:
            return false
        }
    }

    // MARK: - Private

    private static func isTransportClosed(_ error: MCPClientProtocolError) -> Bool {
        if case .transportClosed = error { return true }
        return false
    }

    private static func sentence(
        _ error: MCPClientProtocolError,
        exit: MCPTransportExitInfo?,
        requestTimeout: TimeInterval,
        phase: String
    ) -> String {
        switch error {
        case .transportClosed(let reason):
            return exit.map { exitSentence($0, phase: phase) } ?? "The connection closed \(phase): \(reason)."
        case .timeout:
            return "The server did not reply within \(seconds(requestTimeout)) seconds \(phase)."
        case .transport(let signal):
            if let status = signal.httpStatus {
                return "The server answered HTTP \(status) \(phase)."
            }
            return "The connection failed \(phase): \(signal.message)."
        case .serverError(let rpcError):
            return "The server returned an error \(phase): \(rpcError.message) (code \(rpcError.code))."
        case .malformedReply(let detail):
            return "The server sent a reply that could not be read \(phase): \(detail)."
        case .encodingFailed(let detail):
            return "A request could not be encoded \(phase): \(detail)."
        case .mrtrRoundLimitExceeded:
            return "The server asked for input too many times \(phase)."
        }
    }

    /// Exit status 127 and 126 are how `/usr/bin/env` reports a command it
    /// could not find or could not run.
    private static func exitSentence(_ exit: MCPTransportExitInfo, phase: String?) -> String {
        let suffix = phase.map { " \($0)" } ?? ""
        switch exit {
        case .exited(127):
            return "The command was not found (exit status 127)."
        case .exited(126):
            return "The command could not be run (exit status 126)."
        case .exited(let status):
            return "The server exited with status \(status)\(suffix)."
        case .signaled(let signal):
            return "The server was terminated by signal \(signal)\(suffix)."
        }
    }

    private static func seconds(_ interval: TimeInterval) -> String {
        interval.rounded() == interval ? String(Int(interval)) : String(format: "%.1f", interval)
    }

    /// A Foundation error's localized description, otherwise the error as
    /// written by Swift.
    private static func describe(_ error: any Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        let nsError = error as NSError
        if [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain].contains(nsError.domain) {
            return nsError.localizedDescription
        }
        return String(describing: error)
    }
}
