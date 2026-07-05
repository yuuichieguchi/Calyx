//
//  SSHConfigParserTests.swift
//  CalyxTests
//
//  TDD Red phase, P5 (remote sessions), cycle 1: read-only ~/.ssh/config
//  candidate extraction for the future remote-host picker UI (not this
//  cycle). Introduces ONE new symbol -- SSHConfigParser -- that does not
//  exist anywhere in the codebase yet, so this file is a held-out
//  compile-RED file per this codebase's established convention (see
//  SessionDaemonClientSessionStateBoundTimeoutSeamTests's header): it is
//  expected to FAIL TO COMPILE until the Green phase adds it. That
//  compile failure IS this file's RED evidence.
//
//  SCOPE: SSHConfigParser.hostCandidates(from:) is a PURE function --
//  its only input is an ssh_config-format STRING (never a file path, so
//  no filesystem access is possible from inside it at all), and its only
//  output is the ordered list of Host aliases a UI could offer as remote
//  session candidates. It deliberately does NOT resolve Include
//  directives (storage-layer/UI concern, out of scope for this pure
//  parsing contract) and does NOT deduplicate repeated aliases (not
//  part of the given contract; left to a future caller if ever needed).
//
//  KEYWORD MATCHING: the first whitespace-separated token of each line,
//  compared case-insensitively, must equal the WHOLE word "Host" -- not
//  merely be prefixed by it. This matters because "HostName" (a
//  different, much more common ssh_config keyword) itself starts with
//  the same four letters "Host"; a naive prefix-matching parser would
//  misread every HostName VALUE as an extra Host candidate.
//
//  MATCH BLOCKS: ssh_config's Host and Match keywords are both
//  block-introducing -- a Match line's own inline condition (e.g.
//  "Match host <pattern>") is itself just a Match-keyword line, and any
//  literal "host" appearing later on that SAME line is Match's own
//  condition syntax, never a fresh Host directive. Simple whole-first-
//  token matching (see above) handles this automatically: no separate
//  block-tracking/indentation logic is needed, since a real Host block
//  can never begin except with a line whose own first token is "Host".
//
//  Coverage:
//  - Host aliases extracted in declaration order, across multiple lines
//  - multiple space-separated aliases on one Host line each become
//    their own candidate
//  - patterns containing * or ? are excluded, even when only ONE of
//    several aliases on a line is a wildcard
//  - a bare "Host *" catch-all block contributes zero candidates
//  - negated patterns (leading !) are excluded even without a wildcard
//  - the Host keyword is recognized case-insensitively
//  - comments (# lines) and blank/whitespace-only lines are ignored
//  - HostName's value is never confused with a Host candidate (whole-
//    keyword match, not prefix match)
//  - a Match block's own inline "host <pattern>" condition never
//    introduces spurious candidates
//  - Include's argument is never read as a candidate, and no file I/O
//    is ever attempted (the function only consumes its String argument)
//  - a representative composite fixture combining all of the above
//    yields the exact expected candidate list, in order
//

import XCTest
@testable import Calyx

final class SSHConfigParserTests: XCTestCase {

    // MARK: - Order preservation, multiple aliases per Host line

    func test_hostCandidates_extractsHostEntriesInOrderAcrossMultipleLines() {
        let config = """
        Host alpha
            HostName alpha.example.com

        Host beta
            HostName beta.example.com

        Host gamma
            HostName gamma.example.com
        """
        XCTAssertEqual(SSHConfigParser.hostCandidates(from: config), ["alpha", "beta", "gamma"],
                       "Host aliases must be returned in the same order their Host lines appear in the " +
                       "config text")
    }

    func test_hostCandidates_multipleAliasesOnOneHostLineEachBecomeOwnCandidate() {
        let config = "Host alpha beta gamma\n    HostName somewhere.example.com\n"
        XCTAssertEqual(SSHConfigParser.hostCandidates(from: config), ["alpha", "beta", "gamma"],
                       "Each space-separated alias on a single Host line must become its own candidate, " +
                       "in the order written")
    }

    // MARK: - Wildcard patterns

    func test_hostCandidates_skipsPatternsContainingAsteriskWildcard() {
        let config = "Host *.example.com direct-host\n"
        XCTAssertEqual(SSHConfigParser.hostCandidates(from: config), ["direct-host"],
                       "A pattern containing * must be excluded as a UI candidate, while a plain " +
                       "non-wildcard alias on the SAME line must still be included")
    }

    func test_hostCandidates_skipsPatternsContainingQuestionMarkWildcard() {
        let config = "Host bastion? direct-host\n"
        XCTAssertEqual(SSHConfigParser.hostCandidates(from: config), ["direct-host"],
                       "A pattern containing ? must be excluded the same way * is")
    }

    func test_hostCandidates_bareWildcardOnlyHostLineYieldsNoCandidates() {
        let config = "Host *\n    Compression yes\n"
        XCTAssertEqual(SSHConfigParser.hostCandidates(from: config), [],
                       "A Host * catch-all block (common for global defaults) must contribute zero " +
                       "candidates")
    }

    // MARK: - Negated patterns

    func test_hostCandidates_skipsNegatedPatterns() {
        let config = "Host !excluded-host direct-host\n"
        XCTAssertEqual(SSHConfigParser.hostCandidates(from: config), ["direct-host"],
                       "A pattern starting with ! (negation) must be excluded even when it contains no " +
                       "wildcard character")
    }

    // MARK: - Case-insensitive keyword

    func test_hostCandidates_recognizesLowercaseHostKeyword() {
        let config = "host lowercase-alias\n"
        XCTAssertEqual(SSHConfigParser.hostCandidates(from: config), ["lowercase-alias"],
                       "The Host keyword must be recognized case-insensitively")
    }

    func test_hostCandidates_recognizesUppercaseHostKeyword() {
        let config = "HOST uppercase-alias\n"
        XCTAssertEqual(SSHConfigParser.hostCandidates(from: config), ["uppercase-alias"],
                       "The HOST keyword spelled in all caps must still be recognized")
    }

    // MARK: - Comments and blank lines

    func test_hostCandidates_ignoresCommentedOutHostLines() {
        let config = "# Host commented-out\nHost real-host\n"
        XCTAssertEqual(SSHConfigParser.hostCandidates(from: config), ["real-host"],
                       "A Host line prefixed by # is a comment and must not contribute a candidate")
    }

    func test_hostCandidates_ignoresBlankLinesAndWhitespaceOnlyLines() {
        let config = "\n   \nHost real-host\n\t\n"
        XCTAssertEqual(SSHConfigParser.hostCandidates(from: config), ["real-host"],
                       "Blank and whitespace-only lines must be skipped without affecting extraction")
    }

    // MARK: - Whole-keyword matching (not prefix matching)

    func test_hostCandidates_doesNotConfuseHostNameKeywordWithHostKeyword() {
        let config = "Host real-alias\n    HostName real-alias.internal.example.com\n"
        XCTAssertEqual(SSHConfigParser.hostCandidates(from: config), ["real-alias"],
                       "HostName's VALUE must never be treated as its own Host candidate -- the keyword " +
                       "match must be on the whole word \"Host\", not merely a \"Host\" prefix, since " +
                       "\"HostName\" itself starts with the same four letters")
    }

    // MARK: - Match blocks

    func test_hostCandidates_ignoresConfigInsideMatchBlocks() {
        let config = """
        Host real-alias
            HostName real.example.com

        Match host wildcard-in-match-block
            ProxyCommand none
        """
        XCTAssertEqual(SSHConfigParser.hostCandidates(from: config), ["real-alias"],
                       "A Match block's own condition line (e.g. \"Match host <pattern>\") must never be " +
                       "misread as a Host directive introducing new candidates")
    }

    // MARK: - Include is not resolved

    func test_hostCandidates_doesNotTreatIncludeArgumentAsACandidateOrResolveIt() {
        let config = "Include other_config\nHost real-alias\n"
        XCTAssertEqual(SSHConfigParser.hostCandidates(from: config), ["real-alias"],
                       "Include's argument must never be treated as a Host candidate, and the parser " +
                       "must never attempt to read any file -- it only ever consumes the configText " +
                       "string argument it was given")
    }

    // MARK: - Representative composite fixture

    func test_hostCandidates_representativeFixture_returnsExactExpectedCandidateList() {
        let config = """
        # Personal hosts
        Host laptop
            HostName 192.168.1.50
            User dev

        Host *.internal !bastion
            ProxyJump bastion

        Host bastion
            HostName bastion.example.com
            User ops

        Host build-a build-b
            User ci

        Match host build-a
            ForwardAgent yes

        Include conf.d/*.conf

        host trailing-lowercase
        """
        XCTAssertEqual(
            SSHConfigParser.hostCandidates(from: config),
            ["laptop", "bastion", "build-a", "build-b", "trailing-lowercase"],
            "A representative ssh_config fixture combining comments, a wildcard+negation Host line " +
            "(contributing zero candidates), multiple aliases on one line, a Match block, and an " +
            "Include directive must yield exactly this candidate list in this order"
        )
    }
}
