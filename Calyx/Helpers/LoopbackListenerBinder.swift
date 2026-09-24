//
//  LoopbackListenerBinder.swift
//  Calyx
//
//  Binds an `NWListener` on `127.0.0.1` and waits until the kernel has
//  accepted the bind. Shared by the IPC server (`CalyxMCPServer`) and the
//  OAuth loopback redirect listener (`LoopbackRedirectListener`).
//
//  `NWListener(using:)` does not validate the bind; it only checks the
//  parameter shape. The kernel-level bind happens during `start(queue:)`
//  and a bind failure (e.g. EADDRINUSE) surfaces through
//  `stateUpdateHandler` as `.failed`, so every bind here waits for `.ready`
//  or `.failed` before reporting the port as taken.
//
//  A listener returned from this type is started on its own serial queue,
//  in `.ready`, with a placeholder `newConnectionHandler` that cancels
//  every connection. Callers replace `stateUpdateHandler` and
//  `newConnectionHandler` with their own wiring.
//

import Foundation
import Network

enum LoopbackListenerBinder {

    /// 1s is generous: a successful loopback bind reaches `.ready` in
    /// sub-millisecond on a healthy host; bind failures are reported
    /// essentially synchronously from the kernel. We cap so a wedged
    /// listener never blocks a bind indefinitely.
    private static let listenerReadyTimeout: TimeInterval = 1.0

    /// Attempt to bind an `NWListener` on `127.0.0.1:<port>`. Returns the
    /// started listener together with the port it actually resolved to
    /// once ready, or `nil` if the bind fails (e.g. EADDRINUSE), does not
    /// become ready within 1s, or reaches `.ready` without a resolvable
    /// non-zero port.
    ///
    /// The resolved port is read back from `nl.port?.rawValue` rather than
    /// trusted to equal `tryPort` because `requiredLocalEndpoint` with a
    /// literal port of `0` is not rejected by Network framework on every
    /// host (see `bindKernelAssignedListener`'s doc
    /// comment): on hosts where it isn't rejected, this very function can
    /// reach `.ready` with the kernel having silently picked an ephemeral
    /// port for `tryPort == 0`, and the only way to learn which port that
    /// is is to ask the listener itself. A `nil`/`0` readback here is
    /// treated as a bind failure (cancel + `nil`) so a caller can never
    /// record port `0` as if it were a successful bind.
    ///
    /// `logLabel` prefixes log lines and names the listener's queue.
    static func bindListener(onPort tryPort: Int, logLabel: String) async -> (NWListener, Int)? {
        let params = NWParameters.tcp
        let nwPort = NWEndpoint.Port(integerLiteral: UInt16(tryPort))
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: nwPort
        )
        guard let nl = try? NWListener(using: params) else { return nil }
        guard let ready = await startListenerAndWaitForReady(nl, logLabel: logLabel) else { return nil }
        guard let resolvedPort = ready.port?.rawValue, resolvedPort != 0 else {
            ready.cancel()
            return nil
        }
        return (ready, Int(resolvedPort))
    }

    /// Asks the kernel for a free ephemeral loopback port via a throwaway
    /// BSD socket, then binds an `NWListener` to that resolved port with
    /// `requiredLocalEndpoint`. Returns the started listener and the port
    /// the kernel actually picked, or `nil` if every attempt fails.
    ///
    /// Implementation note: this path resolves a concrete port via a BSD
    /// socket before ever touching `NWListener`, rather than binding
    /// `requiredLocalEndpoint` with a literal port of `0` directly, on
    /// the assumption that Network framework rejects a literal-`0`
    /// `requiredLocalEndpoint` at `start()` time
    /// (`nw_path_create_evaluator_for_listener failed`). That rejection
    /// is environment-dependent,
    /// not universal: on hosts where it does *not* reject the bind, a
    /// literal-`0` `requiredLocalEndpoint` reaches `.ready` directly,
    /// with the kernel silently choosing the ephemeral port inside
    /// `bindListener(onPort:logLabel:)` itself, which is exactly why
    /// that function reads back `nl.port?.rawValue` after `.ready`
    /// instead of trusting the requested port. This path remains for
    /// hosts where the literal-`0` bind genuinely is rejected.
    static func bindKernelAssignedListener(logLabel: String) async -> (NWListener, Int)? {
        // Strategy: use the BSD socket API to ask the kernel for a free
        // ephemeral port on 127.0.0.1, then probe that exact port via
        // `requiredLocalEndpoint` with the resolved port number (see
        // this function's doc comment for why a literal port `0` isn't
        // handed to `NWListener` directly). The BSD socket is closed
        // before NWListener binds; the race window is sub-millisecond.
        //
        // Try up to a handful of kernel-assigned ports; if one happens
        // to lose the close->bind race we ask the kernel for another.
        for attempt in 0..<5 {
            guard let probedPort = askKernelForFreeLoopbackPort() else {
                NSLog("[\(logLabel)] BSD fallback attempt \(attempt): kernel did not return a port")
                continue
            }

            let params = NWParameters.tcp
            let nwPort = NWEndpoint.Port(integerLiteral: UInt16(probedPort))
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback),
                port: nwPort
            )
            guard let nl = try? NWListener(using: params) else { continue }
            guard let ready = await startListenerAndWaitForReady(nl, logLabel: logLabel) else { continue }

            // Symmetric with `bindListener(onPort:logLabel:)`: read the
            // port the listener itself actually resolved to, rather than
            // trusting `probedPort` (the pre-bind BSD-socket probe) to
            // still be accurate. The BSD socket is closed before
            // `NWListener` binds and nothing structurally guarantees the
            // two can never differ, so a caller must only ever record a
            // port the listener confirmed it actually bound.
            guard let boundPort = ready.port?.rawValue, boundPort != 0 else {
                ready.cancel()
                continue
            }
            if Int(boundPort) != probedPort {
                NSLog("[\(logLabel)] BSD fallback probed port \(probedPort) but the listener resolved to \(boundPort); recording the resolved port")
            }
            return (ready, Int(boundPort))
        }
        return nil
    }

    /// Ask the kernel for a free ephemeral port on `127.0.0.1` by
    /// binding a throwaway BSD socket to `127.0.0.1:0`, reading the
    /// assigned port via `getsockname`, then closing the socket. The
    /// returned port is the kernel's choice from the ephemeral range;
    /// use it as the desired port for an `NWListener` bind.
    static func askKernelForFreeLoopbackPort() -> Int? {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = UInt32(0x7F000001).bigEndian  // 127.0.0.1
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return nil }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                getsockname(fd, saPtr, &len)
            }
        }
        guard nameResult == 0 else { return nil }
        let resolvedPort = Int(UInt16(bigEndian: boundAddr.sin_port))
        return resolvedPort != 0 ? resolvedPort : nil
    }

    /// Start `nl` on a dedicated background queue and suspend until it
    /// reaches `.ready` (success) or `.failed` / `.cancelled` / timeout
    /// (failure). Returns the listener on success, `nil` on failure.
    ///
    /// The queue is a dedicated background queue rather than `.main`:
    /// this function suspends on a `CheckedContinuation` instead of
    /// blocking a thread, so the caller's actor stays free to run other
    /// work while a bind is in flight.
    ///
    /// `stateUpdateHandler` can fire `.ready` and later still fire
    /// `.failed`/`.cancelled` on this SAME listener (a later `.cancel()`
    /// on a failure path drives `.cancelled` into this same closure), and
    /// a `CheckedContinuation` resumed twice traps, so every arm below
    /// (the state handler's three cases and the timeout) routes through
    /// one `IPCListenerReadyGuard`, constructed before `nl.start(queue:)`
    /// so no resume can race its construction. The state handler and the
    /// timeout's `asyncAfter` both run on the same serial
    /// `listenerQueue`, so the guard needs no lock beyond its own plain
    /// `Bool`.
    private static func startListenerAndWaitForReady(_ nl: NWListener, logLabel: String) async -> NWListener? {
        let listenerQueue = DispatchQueue(
            label: "\(logLabel).listenerProbe"
        )
        let guardian = IPCListenerReadyGuard()

        let didSucceed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            nl.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guardian.resumeOnce { continuation.resume(returning: true) }
                case .failed(let err):
                    NSLog("[\(logLabel)] probe listener failed: \(err)")
                    guardian.resumeOnce { continuation.resume(returning: false) }
                case .cancelled:
                    guardian.resumeOnce { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            // NWListener fails its `start()` with EINVAL when no
            // `newConnectionHandler` is set before `start()` is invoked.
            // Install a no-op placeholder here purely to satisfy the
            // start-time invariant; the caller reassigns the real
            // handler after the bind completes successfully.
            nl.newConnectionHandler = { connection in
                connection.cancel()
            }
            nl.start(queue: listenerQueue)

            listenerQueue.asyncAfter(deadline: .now() + listenerReadyTimeout) {
                guardian.resumeOnce { continuation.resume(returning: false) }
            }
        }

        if !didSucceed {
            nl.cancel()
            return nil
        }
        return nl
    }
}
