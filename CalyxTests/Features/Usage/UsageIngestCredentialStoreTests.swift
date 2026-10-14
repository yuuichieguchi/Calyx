//
//  UsageIngestCredentialStoreTests.swift
//  CalyxTests
//
//  `UsageIngestCredentialStore`: the usage route's dedicated token, kept
//  in `<directory>/usage-otel-credential.json` as exactly
//  `{"Authorization":"Bearer <64 lowercase hex>"}` at mode 0600. Every
//  test works in its own temporary directory; every token is synthetic.
//

import XCTest
@testable import Calyx

final class UsageIngestCredentialStoreTests: XCTestCase {

    private var rootDir: String = ""
    private var dir: String = ""

    private let tokenA = String(repeating: "0123456789abcdef", count: 4)
    private let tokenB = String(repeating: "fedcba9876543210", count: 4)

    private struct MakeTokenFailure: Error {}

    override func setUp() {
        super.setUp()
        rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageIngestCredentialStoreTests-\(UUID().uuidString)").path
        dir = (rootDir as NSString).appendingPathComponent("Calyx")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: rootDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private var filePath: String { (dir as NSString).appendingPathComponent("usage-otel-credential.json") }

    private func expectedContents(_ token: String) -> Data {
        Data("{\"Authorization\":\"Bearer \(token)\"}".utf8)
    }

    private func makeDir() throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    private func writeFile(_ data: Data, mode: Int) throws {
        try makeDir()
        let ok = FileManager.default.createFile(atPath: filePath, contents: data, attributes: [.posixPermissions: mode])
        XCTAssertTrue(ok, "Fixture error: could not create the headers file")
        // createFile's attributes are subject to the umask; set the mode explicitly.
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: filePath)
    }

    private func mode(of path: String) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let value = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber)
        return value.intValue & 0o777
    }

    private struct FileIdentity: Equatable {
        let inode: UInt64
        let mtimeSec: Int
        let mtimeNsec: Int
    }

    private func identity(of path: String) throws -> FileIdentity {
        var st = stat()
        guard stat(path, &st) == 0 else {
            throw NSError(domain: "UsageIngestCredentialStoreTests", code: 1)
        }
        return FileIdentity(
            inode: UInt64(st.st_ino),
            mtimeSec: Int(st.st_mtimespec.tv_sec),
            mtimeNsec: Int(st.st_mtimespec.tv_nsec)
        )
    }

    private func listing(_ path: String) -> [String]? {
        (try? FileManager.default.contentsOfDirectory(atPath: path))?.sorted()
    }

    // MARK: - headersFilePath

    func test_fileName_isUsageOtelCredentialJSON() {
        XCTAssertEqual(UsageIngestCredentialStore.fileName, "usage-otel-credential.json")
    }

    func test_legacyFileName_isUsageOtelHeadersJSON() {
        XCTAssertEqual(UsageIngestCredentialStore.legacyFileName, "usage-otel-headers.json")
    }

    // MARK: - Legacy file (G5 disposition 24)

    private var legacyPath: String { (dir as NSString).appendingPathComponent("usage-otel-headers.json") }

    func test_loadOrCreate_removesAPreExistingLegacyFile() throws {
        try makeDir()
        try expectedContents(tokenB).write(to: URL(fileURLWithPath: legacyPath))
        let credential = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenA }
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPath))
        XCTAssertEqual(credential.token, tokenA, "the legacy file's token is not adopted")
        XCTAssertEqual(listing(dir), ["usage-otel-credential.json"])
    }

    func test_loadOrCreate_removesTheLegacyFile_whenTheNewFileIsAlreadyUsable() throws {
        try writeFile(expectedContents(tokenA), mode: 0o600)
        try expectedContents(tokenB).write(to: URL(fileURLWithPath: legacyPath))
        let credential = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenB }
        XCTAssertEqual(credential.token, tokenA)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPath))
    }

    func test_loadOrCreate_leavesALegacyNamedDirectoryInPlace() throws {
        try FileManager.default.createDirectory(atPath: legacyPath, withIntermediateDirectories: true)
        _ = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenA }
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyPath, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertEqual(FileManager.default.contents(atPath: filePath), expectedContents(tokenA))
    }

    func test_read_readsOnlyTheNewName() throws {
        try makeDir()
        try expectedContents(tokenB).write(to: URL(fileURLWithPath: legacyPath))
        XCTAssertNil(UsageIngestCredentialStore.read(directory: dir), "a legacy file alone is not read")
        try writeFile(expectedContents(tokenA), mode: 0o600)
        XCTAssertEqual(UsageIngestCredentialStore.read(directory: dir)?.token, tokenA)
    }

    func test_headersFilePath_isDirectoryPlusFileName() {
        XCTAssertEqual(UsageIngestCredentialStore.headersFilePath(directory: "/some/dir"), "/some/dir/usage-otel-credential.json")
    }

    // MARK: - loadOrCreate: first creation

    func test_loadOrCreate_onMissingDirectory_createsDirectoryAndFile() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir))
        _ = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenA }
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath))
    }

    func test_loadOrCreate_onEmptyDirectory_writesExactContents() throws {
        try makeDir()
        _ = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenA }
        XCTAssertEqual(FileManager.default.contents(atPath: filePath), expectedContents(tokenA))
    }

    func test_loadOrCreate_onEmptyDirectory_writesMode0600() throws {
        try makeDir()
        _ = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenA }
        XCTAssertEqual(try mode(of: filePath), 0o600)
    }

    func test_loadOrCreate_onEmptyDirectory_returnsGeneratedTokenAndPath() throws {
        try makeDir()
        let credential = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenA }
        XCTAssertEqual(credential, UsageIngestCredential(token: tokenA, headersFilePath: filePath))
    }

    func test_loadOrCreate_onEmptyDirectory_leavesNoOtherFileInDirectory() throws {
        try makeDir()
        _ = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenA }
        XCTAssertEqual(listing(dir), ["usage-otel-credential.json"])
    }

    // MARK: - loadOrCreate: existing usable file

    func test_loadOrCreate_secondCall_returnsSameToken() throws {
        let first = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenA }
        let second = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenB }
        XCTAssertEqual(second, first)
        XCTAssertEqual(second.token, tokenA)
    }

    func test_loadOrCreate_secondCall_doesNotAskForAToken() throws {
        _ = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenA }
        var calls = 0
        _ = try UsageIngestCredentialStore.loadOrCreate(directory: dir) {
            calls += 1
            return self.tokenB
        }
        XCTAssertEqual(calls, 0)
    }

    func test_loadOrCreate_secondCall_doesNotRewriteFile() throws {
        _ = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenA }
        let before = try identity(of: filePath)
        _ = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenB }
        XCTAssertEqual(try identity(of: filePath), before)
        XCTAssertEqual(FileManager.default.contents(atPath: filePath), expectedContents(tokenA))
    }

    func test_loadOrCreate_usableFileWithMode0644_isTightenedTo0600() throws {
        try writeFile(expectedContents(tokenA), mode: 0o644)
        XCTAssertEqual(try mode(of: filePath), 0o644, "Fixture error: mode not applied")
        _ = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenB }
        XCTAssertEqual(try mode(of: filePath), 0o600)
    }

    func test_loadOrCreate_usableFileWithMode0644_isNotRewritten() throws {
        try writeFile(expectedContents(tokenA), mode: 0o644)
        let before = try identity(of: filePath)
        let credential = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenB }
        XCTAssertEqual(credential.token, tokenA)
        XCTAssertEqual(try identity(of: filePath).inode, before.inode)
        XCTAssertEqual(try identity(of: filePath).mtimeSec, before.mtimeSec)
        XCTAssertEqual(try identity(of: filePath).mtimeNsec, before.mtimeNsec)
        XCTAssertEqual(FileManager.default.contents(atPath: filePath), expectedContents(tokenA))
    }

    func test_loadOrCreate_usableFileWithMode0400_isTightenedTo0600() throws {
        try writeFile(expectedContents(tokenA), mode: 0o400)
        XCTAssertEqual(try mode(of: filePath), 0o400, "Fixture error: mode not applied")
        _ = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenB }
        XCTAssertEqual(try mode(of: filePath), 0o600)
    }

    func test_loadOrCreate_usableFileWithMode0400_isNotRewritten() throws {
        try writeFile(expectedContents(tokenA), mode: 0o400)
        let before = try identity(of: filePath)
        let credential = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenB }
        XCTAssertEqual(credential.token, tokenA)
        XCTAssertEqual(try identity(of: filePath), before)
        XCTAssertEqual(FileManager.default.contents(atPath: filePath), expectedContents(tokenA))
    }

    /// Parses as the credential but is not exactly Calyx's bytes.
    private var prettyContents: Data {
        Data("{\n  \"Authorization\" : \"Bearer \(tokenA)\"\n}\n".utf8)
    }

    // MARK: - loadOrCreate: unusable contents are replaced

    private func assertReplaced(_ contents: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        try writeFile(contents, mode: 0o600)
        let credential = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenB }
        XCTAssertEqual(credential, UsageIngestCredential(token: tokenB, headersFilePath: filePath), file: file, line: line)
        XCTAssertEqual(FileManager.default.contents(atPath: filePath), expectedContents(tokenB), file: file, line: line)
        XCTAssertEqual(try mode(of: filePath), 0o600, file: file, line: line)
    }

    func test_loadOrCreate_emptyFile_isReplaced() throws {
        try assertReplaced(Data())
    }

    func test_loadOrCreate_notJSON_isReplaced() throws {
        try assertReplaced(Data("Bearer \(tokenA)".utf8))
    }

    func test_loadOrCreate_jsonArray_isReplaced() throws {
        try assertReplaced(Data("[\"Bearer \(tokenA)\"]".utf8))
    }

    /// Never repaired in part: the extra member is not just dropped while
    /// the old token is kept; a whole new credential is written.
    func test_loadOrCreate_extraMember_isReplacedWithNewToken() throws {
        try assertReplaced(Data("{\"Authorization\":\"Bearer \(tokenA)\",\"X-Other\":\"1\"}".utf8))
    }

    func test_loadOrCreate_tokenTooShort_isReplaced() throws {
        try assertReplaced(expectedContents(String(tokenA.dropLast())))
    }

    func test_loadOrCreate_tokenTooLong_isReplaced() throws {
        try assertReplaced(expectedContents(tokenA + "0"))
    }

    func test_loadOrCreate_tokenWithUpperCase_isReplaced() throws {
        try assertReplaced(expectedContents(tokenA.uppercased()))
    }

    func test_loadOrCreate_tokenWithNonHexLetter_isReplaced() throws {
        try assertReplaced(expectedContents(String(tokenA.dropLast()) + "g"))
    }

    func test_loadOrCreate_basicScheme_isReplaced() throws {
        try assertReplaced(Data("{\"Authorization\":\"Basic \(tokenA)\"}".utf8))
    }

    func test_loadOrCreate_lowercaseBearerScheme_isReplaced() throws {
        try assertReplaced(Data("{\"Authorization\":\"bearer \(tokenA)\"}".utf8))
    }

    func test_loadOrCreate_wrongMemberName_isReplaced() throws {
        try assertReplaced(Data("{\"authorization\":\"Bearer \(tokenA)\"}".utf8))
    }

    func test_loadOrCreate_nonStringValue_isReplaced() throws {
        try assertReplaced(Data("{\"Authorization\":42}".utf8))
    }

    // Files that only PARSE as the credential are unusable (exact bytes only).

    func test_loadOrCreate_prettyPrintedFile_isReplaced() throws {
        try assertReplaced(prettyContents)
    }

    func test_loadOrCreate_trailingNewline_isReplaced() throws {
        try assertReplaced(expectedContents(tokenA) + Data("\n".utf8))
    }

    func test_loadOrCreate_repeatedAuthorizationMember_isReplaced() throws {
        try assertReplaced(Data("{\"Authorization\":\"Bearer \(tokenA)\",\"Authorization\":\"Bearer \(tokenA)\"}".utf8))
    }

    func test_read_prettyPrintedFile_returnsNil() throws {
        try writeFile(prettyContents, mode: 0o600)
        XCTAssertNil(UsageIngestCredentialStore.read(directory: dir))
    }

    func test_read_trailingNewline_returnsNil() throws {
        try writeFile(expectedContents(tokenA) + Data("\n".utf8), mode: 0o600)
        XCTAssertNil(UsageIngestCredentialStore.read(directory: dir))
    }

    func test_read_repeatedAuthorizationMember_returnsNil() throws {
        try writeFile(Data("{\"Authorization\":\"Bearer \(tokenA)\",\"Authorization\":\"Bearer \(tokenB)\"}".utf8), mode: 0o600)
        XCTAssertNil(UsageIngestCredentialStore.read(directory: dir))
    }

    // MARK: - loadOrCreate: calls started at once

    /// Runs `count` `loadOrCreate` calls on separate threads at once. Each
    /// caller's `makeToken` returns its own valid token and waits (up to
    /// 0.5 s) until every caller has entered `makeToken`, so an
    /// implementation that decides outside the lock lets them all generate
    /// and write. In a correct implementation only the first caller ever
    /// reaches `makeToken`; it waits out the 0.5 s bound and continues while the
    /// others wait for the lock (bounded by `ConfigFileUtils`' 10 s lock
    /// timeout), so nothing can hang.
    private func runConcurrently(_ count: Int) -> [Result<UsageIngestCredential, Error>] {
        let gate = MakeTokenGate(parties: count)
        let results = ResultBox(count: count)
        let group = DispatchGroup()
        let directory = dir
        for index in 0..<count {
            group.enter()
            let token = String(repeating: String(index, radix: 16), count: 64)
            let thread = Thread {
                defer { group.leave() }
                let result = Result {
                    try UsageIngestCredentialStore.loadOrCreate(directory: directory) {
                        gate.arriveAndWait(timeout: 0.5)
                        return token
                    }
                }
                results.set(index, result)
            }
            // The main thread waits for these threads; match its priority
            // so XCTest reports no priority inversion.
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        guard group.wait(timeout: .now() + 60) == .success else {
            XCTFail("concurrent loadOrCreate calls did not finish within 60 s")
            return []
        }
        return results.all()
    }

    private func assertConcurrentCallsAgree(_ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let results = runConcurrently(count)
        XCTAssertEqual(results.count, count, file: file, line: line)
        var credentials: [UsageIngestCredential] = []
        for result in results {
            switch result {
            case .success(let credential): credentials.append(credential)
            case .failure(let error): XCTFail("loadOrCreate threw \(error)", file: file, line: line)
            }
        }
        guard let first = credentials.first else { return XCTFail("no credential", file: file, line: line) }
        XCTAssertEqual(Set(credentials.map(\.token)).count, 1, "every caller must return the same token", file: file, line: line)
        XCTAssertEqual(FileManager.default.contents(atPath: filePath), expectedContents(first.token), file: file, line: line)
        XCTAssertEqual(first.headersFilePath, filePath, file: file, line: line)
    }

    func test_loadOrCreate_twoConcurrentCalls_returnTheSameCredential() throws {
        try makeDir()
        assertConcurrentCallsAgree(2)
    }

    func test_loadOrCreate_eightConcurrentCalls_returnTheSameCredential() throws {
        try makeDir()
        assertConcurrentCallsAgree(8)
    }

    func test_loadOrCreate_twoConcurrentCalls_onMissingDirectory_returnTheSameCredential() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir), "Fixture error: directory exists")
        assertConcurrentCallsAgree(2)
    }

    func test_loadOrCreate_eightConcurrentCalls_onMissingDirectory_returnTheSameCredential() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir), "Fixture error: directory exists")
        assertConcurrentCallsAgree(8)
    }

    // MARK: - Symbolic link at the file's place

    private var otherDir: String { (rootDir as NSString).appendingPathComponent("elsewhere") }
    private var targetPath: String { (otherDir as NSString).appendingPathComponent("target.json") }

    /// `dir/usage-otel-credential.json` -> `rootDir/elsewhere/target.json`.
    /// The link's own mode is set to 0600, so an implementation that takes
    /// the mode from the link (not the target) sees nothing to fix.
    private func makeLink(targetContents: Data?, targetMode: Int = 0o644) throws {
        try makeDir()
        try FileManager.default.createDirectory(atPath: otherDir, withIntermediateDirectories: true)
        if let targetContents {
            XCTAssertTrue(FileManager.default.createFile(atPath: targetPath, contents: targetContents), "Fixture error: target not created")
            try FileManager.default.setAttributes([.posixPermissions: targetMode], ofItemAtPath: targetPath)
        }
        try FileManager.default.createSymbolicLink(atPath: filePath, withDestinationPath: targetPath)
        XCTAssertEqual(lchmod(filePath, 0o600), 0, "Fixture error: link mode not set")
    }

    private func isSymlink(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    private func linkDestination() -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: filePath)
    }

    func test_read_throughLinkToUsableFile_returnsCredential() throws {
        try makeLink(targetContents: expectedContents(tokenA))
        XCTAssertEqual(UsageIngestCredentialStore.read(directory: dir), UsageIngestCredential(token: tokenA, headersFilePath: filePath))
    }

    func test_loadOrCreate_throughLinkToUsableFile_returnsItsCredential() throws {
        try makeLink(targetContents: expectedContents(tokenA))
        let credential = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenB }
        XCTAssertEqual(credential, UsageIngestCredential(token: tokenA, headersFilePath: filePath))
    }

    func test_loadOrCreate_throughLinkToUsableFile_tightensTargetTo0600() throws {
        try makeLink(targetContents: expectedContents(tokenA), targetMode: 0o644)
        XCTAssertEqual(try mode(of: targetPath), 0o644, "Fixture error: target mode not applied")
        _ = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenB }
        XCTAssertEqual(try mode(of: targetPath), 0o600)
    }

    func test_loadOrCreate_throughLinkToUsableFile_doesNotRewriteTarget() throws {
        try makeLink(targetContents: expectedContents(tokenA))
        let before = try identity(of: targetPath)
        _ = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenB }
        XCTAssertEqual(try identity(of: targetPath), before)
        XCTAssertEqual(FileManager.default.contents(atPath: targetPath), expectedContents(tokenA))
    }

    func test_loadOrCreate_throughLinkToUsableFile_linkStaysALink() throws {
        try makeLink(targetContents: expectedContents(tokenA))
        _ = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenB }
        XCTAssertTrue(isSymlink(filePath))
        XCTAssertEqual(linkDestination(), targetPath)
    }

    func test_loadOrCreate_throughLinkToUnusableFile_writesTargetAndKeepsLink() throws {
        try makeLink(targetContents: Data("[]".utf8))
        let credential = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenB }
        XCTAssertEqual(credential.token, tokenB)
        XCTAssertEqual(FileManager.default.contents(atPath: targetPath), expectedContents(tokenB))
        XCTAssertEqual(try mode(of: targetPath), 0o600)
        XCTAssertTrue(isSymlink(filePath))
        XCTAssertEqual(linkDestination(), targetPath)
    }

    func test_loadOrCreate_throughLinkToMissingFile_writesTargetAndKeepsLink() throws {
        try makeLink(targetContents: nil)
        let credential = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenB }
        XCTAssertEqual(credential.token, tokenB)
        XCTAssertEqual(FileManager.default.contents(atPath: targetPath), expectedContents(tokenB))
        XCTAssertEqual(try mode(of: targetPath), 0o600)
        XCTAssertTrue(isSymlink(filePath))
        XCTAssertEqual(linkDestination(), targetPath)
    }

    // MARK: - loadOrCreate: token generation failures

    func test_loadOrCreate_makeTokenThrows_throws() throws {
        try makeDir()
        XCTAssertThrowsError(try UsageIngestCredentialStore.loadOrCreate(directory: dir) { throw MakeTokenFailure() })
    }

    func test_loadOrCreate_makeTokenThrows_leavesEmptyDirectoryEmpty() throws {
        try makeDir()
        _ = try? UsageIngestCredentialStore.loadOrCreate(directory: dir) { throw MakeTokenFailure() }
        XCTAssertEqual(listing(dir), [])
    }

    func test_loadOrCreate_makeTokenThrows_doesNotCreateDirectory() {
        _ = try? UsageIngestCredentialStore.loadOrCreate(directory: dir) { throw MakeTokenFailure() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir))
    }

    func test_loadOrCreate_makeTokenThrows_leavesUnusableFileUntouched() throws {
        let junk = Data("not json".utf8)
        try writeFile(junk, mode: 0o600)
        _ = try? UsageIngestCredentialStore.loadOrCreate(directory: dir) { throw MakeTokenFailure() }
        XCTAssertEqual(FileManager.default.contents(atPath: filePath), junk)
        XCTAssertEqual(listing(dir), ["usage-otel-credential.json"])
    }

    func test_loadOrCreate_malformedGeneratedToken_upperCase_throws() throws {
        try makeDir()
        XCTAssertThrowsError(try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenA.uppercased() })
    }

    func test_loadOrCreate_malformedGeneratedToken_wrongLength_throws() throws {
        try makeDir()
        XCTAssertThrowsError(try UsageIngestCredentialStore.loadOrCreate(directory: dir) { String(self.tokenA.dropLast()) })
    }

    func test_loadOrCreate_malformedGeneratedToken_empty_throws() throws {
        try makeDir()
        XCTAssertThrowsError(try UsageIngestCredentialStore.loadOrCreate(directory: dir) { "" })
    }

    func test_loadOrCreate_malformedGeneratedToken_writesNothing() throws {
        try makeDir()
        _ = try? UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenA.uppercased() }
        XCTAssertEqual(listing(dir), [])
    }

    func test_loadOrCreate_malformedGeneratedToken_doesNotCreateDirectory() {
        _ = try? UsageIngestCredentialStore.loadOrCreate(directory: dir) { "short" }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir))
    }

    func test_loadOrCreate_malformedGeneratedToken_leavesUnusableFileUntouched() throws {
        let junk = Data("[]".utf8)
        try writeFile(junk, mode: 0o600)
        _ = try? UsageIngestCredentialStore.loadOrCreate(directory: dir) { "short" }
        XCTAssertEqual(FileManager.default.contents(atPath: filePath), junk)
    }

    // MARK: - read

    func test_read_usableFile_returnsCredential() throws {
        try writeFile(expectedContents(tokenA), mode: 0o600)
        XCTAssertEqual(UsageIngestCredentialStore.read(directory: dir), UsageIngestCredential(token: tokenA, headersFilePath: filePath))
    }

    func test_read_returnsWhatLoadOrCreateWrote() throws {
        let created = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenA }
        XCTAssertEqual(UsageIngestCredentialStore.read(directory: dir), created)
    }

    func test_read_missingFile_returnsNil() throws {
        try makeDir()
        XCTAssertNil(UsageIngestCredentialStore.read(directory: dir))
    }

    func test_read_missingFile_createsNothing() throws {
        try makeDir()
        _ = UsageIngestCredentialStore.read(directory: dir)
        XCTAssertEqual(listing(dir), [])
    }

    func test_read_missingDirectory_returnsNilAndCreatesNothing() {
        XCTAssertNil(UsageIngestCredentialStore.read(directory: dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir))
    }

    func test_read_unusableFile_returnsNil() throws {
        try writeFile(Data("{\"Authorization\":\"Bearer \(tokenA)\",\"X\":\"1\"}".utf8), mode: 0o600)
        XCTAssertNil(UsageIngestCredentialStore.read(directory: dir))
    }

    func test_read_upperCaseToken_returnsNil() throws {
        try writeFile(expectedContents(tokenA.uppercased()), mode: 0o600)
        XCTAssertNil(UsageIngestCredentialStore.read(directory: dir))
    }

    func test_read_unusableFile_leavesFileUntouched() throws {
        let junk = Data("[]".utf8)
        try writeFile(junk, mode: 0o644)
        _ = UsageIngestCredentialStore.read(directory: dir)
        XCTAssertEqual(FileManager.default.contents(atPath: filePath), junk)
        XCTAssertEqual(try mode(of: filePath), 0o644)
        XCTAssertEqual(listing(dir), ["usage-otel-credential.json"])
    }
}

// MARK: - Concurrency helpers

/// Lets each caller wait until `parties` callers have arrived or a timeout
/// passes, whichever comes first. Never waits unboundedly.
private final class MakeTokenGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let parties: Int
    private var arrived = 0

    init(parties: Int) {
        self.parties = parties
    }

    func arriveAndWait(timeout: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        arrived += 1
        condition.broadcast()
        while arrived < parties {
            if !condition.wait(until: deadline) { break }
        }
        condition.unlock()
    }
}

/// Thread-safe slots for the callers' results.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [Result<UsageIngestCredential, Error>?]

    init(count: Int) {
        slots = Array(repeating: nil, count: count)
    }

    func set(_ index: Int, _ result: Result<UsageIngestCredential, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard slots.indices.contains(index) else { return }
        slots[index] = result
    }

    func all() -> [Result<UsageIngestCredential, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return slots.compactMap { $0 }
    }
}
