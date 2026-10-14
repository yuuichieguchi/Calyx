//
//  EndpointLivenessTests.swift
//  CalyxTests
//
//  Spec Feature C, J1 / C.3 G1: `EndpointLiveness` is the Calyx process's
//  liveness identifier written into agent-endpoint.json -- its pid and
//  its start time as `%a %b %e %H:%M:%S %Y` in UTC / C locale, runs of
//  spaces collapsed to one and the ends trimmed. Every reader compares it
//  with `TZ=UTC LC_ALL=C ps -p <pid> -o lstart=` normalised the same way,
//  so `current()` is checked here against that very command, run on every
//  test run (V3-4 verified the equality over 894 processes).
//
//  Coverage:
//  - current() is non-nil, its pid is getpid(), its startText equals the
//    normalised ps output (computed independently, TestHostLiveness)
//  - startText has the J1 shape (regex)
//  - normalize collapses runs of spaces and trims
//  - Equatable compares both fields
//  - AgentEndpointFile.write(...liveness:...) stores exactly the given
//    liveness (not current()), as "pid" (number) and "pidStart" (string)
//
//  NOT covered (no seam): "pid 0 / proc_pidinfo failure -> nil" (C.4).
//  `current()` takes no argument and always queries getpid(); forcing a
//  proc_pidinfo failure needs an injection point the planned API does not
//  have.
//

import XCTest
@testable import Calyx

final class EndpointLivenessTests: XCTestCase {

    private let shapePattern = #"^[A-Z][a-z]{2} [A-Z][a-z]{2} [0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}$"#

    func test_current_isTheTestHostsPidAndItsNormalisedPsStartTime() throws {
        let liveness = try XCTUnwrap(EndpointLiveness.current())
        XCTAssertEqual(liveness.pid, getpid())
        let fromPs = try XCTUnwrap(TestHostLiveness.startText(ofPid: getpid()), "precondition: ps reports this process")
        XCTAssertEqual(liveness.startText, fromPs,
                       "startText must equal `TZ=UTC LC_ALL=C ps -p <pid> -o lstart=` normalised")
    }

    func test_current_startTextHasTheJ1Shape() throws {
        let text = try XCTUnwrap(EndpointLiveness.current()).startText
        XCTAssertNotNil(text.range(of: shapePattern, options: .regularExpression),
                        "startText must look like `Tue Oct 7 01:02:03 2026`, got \(text)")
    }

    func test_normalize_collapsesRunsOfSpacesAndTrims() {
        XCTAssertEqual(EndpointLiveness.normalize("Tue Oct  7 01:02:03 2026 "), "Tue Oct 7 01:02:03 2026")
        XCTAssertEqual(EndpointLiveness.normalize("  Mon Jan 12 23:59:59 2026"), "Mon Jan 12 23:59:59 2026")
        XCTAssertEqual(EndpointLiveness.normalize("Wed Feb   3 00:00:00 2027   "), "Wed Feb 3 00:00:00 2027")
        XCTAssertEqual(EndpointLiveness.normalize("Thu Mar 5 10:11:12 2026"), "Thu Mar 5 10:11:12 2026",
                       "an already-normal text is unchanged")
    }

    func test_equatable_comparesPidAndStartText() {
        let a = EndpointLiveness(pid: 10, startText: "Tue Oct 7 01:02:03 2026")
        XCTAssertEqual(a, EndpointLiveness(pid: 10, startText: "Tue Oct 7 01:02:03 2026"))
        XCTAssertNotEqual(a, EndpointLiveness(pid: 11, startText: "Tue Oct 7 01:02:03 2026"))
        XCTAssertNotEqual(a, EndpointLiveness(pid: 10, startText: "Tue Oct 7 01:02:04 2026"))
    }

    func test_endpointFileWrite_storesTheGivenLiveness() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EndpointLivenessTests-" + UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try AgentEndpointFile.write(
            port: 41830, token: "t", wakeProofKey: IPCWakeProofKey.random(),
            liveness: EndpointLiveness(pid: 4242, startText: "Tue Oct 7 01:02:03 2026"),
            directory: dir
        )
        let data = try Data(contentsOf: URL(fileURLWithPath: dir + "/agent-endpoint.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["pid"] as? Int, 4242)
        XCTAssertNil(json["pid"] as? String)
        XCTAssertEqual(json["pidStart"] as? String, "Tue Oct 7 01:02:03 2026")
    }
}
