// EndpointLiveness.swift
// Calyx
//
// The liveness identifier of the Calyx process that writes
// agent-endpoint.json (spec Feature C, J1): its pid and its start time.
//
// Threat model: the file outlives the process that wrote it (a crash, a
// SIGKILL, a listener that died). Its port may then be taken by another
// local process, and every sender would hand that process the bearer
// token. So every reader (the hook scripts' prologue, the zsh/fish
// integration, the OpenCode plugin and the pi extension) checks, before
// it sends the token, that the writer is still alive and is the same
// process.
//
// Why pid plus start time: a pid alone can be reused by an unrelated
// process after the writer exits; the pair (pid, start time) cannot,
// short of the pid being reused within the same second.
//
// Normalisation contract (verified in V3-4): `startText` is the start
// time as `strftime("%a %b %e %H:%M:%S %Y")` prints it in UTC under the
// C locale (built from `gmtime_r`'s fields, see `format`), then
// `normalize`d. Readers run `TZ=UTC LC_ALL=C ps -p <pid>
// -o lstart=` and normalise its output the same way (split on whitespace,
// drop empty fields, join with one space), so the two texts are equal
// for the same process. `%e` pads a single-digit day with a space
// (`Oct  7`), and `ps` may pad or trail spaces; normalisation removes both.

import Darwin
import Foundation

struct EndpointLiveness: Sendable, Equatable {
    let pid: Int32
    let startText: String

    /// This process's identifier, or nil when `proc_pidinfo` does not
    /// return a full `proc_bsdinfo` (the caller treats nil as a failure
    /// to publish the endpoint file).
    static func current() -> EndpointLiveness? {
        let pid = getpid()
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var seconds = time_t(info.pbi_start_tvsec)
        var calendar = tm()
        guard gmtime_r(&seconds, &calendar) != nil else { return nil }
        let text = format(calendar)
        return EndpointLiveness(pid: pid, startText: normalize(text))
    }

    /// C-locale `%a`/`%b` names, indexed by `tm_wday` / `tm_mon`.
    private static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `strftime("%a %b %e %H:%M:%S %Y")` as the C locale prints it, built
    /// from the `tm` fields directly. `strftime` itself follows the
    /// process's `LC_TIME`, which this process does not own (the linked
    /// libghostty calls `setlocale`), and would then print localised day
    /// and month names that no `LC_ALL=C ps` reader matches; `strftime_l`
    /// is not exported to Swift by the public Darwin module. `%e`'s space
    /// padding is omitted because `normalize` removes it anyway.
    private static func format(_ t: tm) -> String {
        let weekday = weekdayNames[Int(t.tm_wday)]
        let month = monthNames[Int(t.tm_mon)]
        let clock = String(format: "%02d:%02d:%02d", t.tm_hour, t.tm_min, t.tm_sec)
        return "\(weekday) \(month) \(t.tm_mday) \(clock) \(Int(t.tm_year) + 1900)"
    }

    /// Splits on whitespace, drops empty fields and joins with single
    /// spaces: the normalisation every reader applies to `ps -o lstart=`.
    static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
