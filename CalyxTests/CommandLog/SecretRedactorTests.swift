//
//  SecretRedactorTests.swift
//  CalyxTests
//
//  Pins SecretRedactor.redact's exact masking behavior: env-assignment
//  secrets (export / inline-prefix / dotenv-style / fish `set`), CLI
//  secret flags, Authorization headers, and known token formats anywhere
//  in the text -- while leaving non-secret names, plain commands/output,
//  and deliberately-excluded shapes (GIT_AUTHOR_*, `mysql -pfoo`,
//  `--password --verbose`) untouched. Also pins idempotency.
//

import XCTest
@testable import Calyx

final class SecretRedactorTests: XCTestCase {

    // MARK: - Env assignments: export

    func test_redact_exportSecretishAssignment_masksValueKeepsKey() {
        let input = "export API_KEY=abc123"
        let expected = "export API_KEY=[redacted]"

        XCTAssertEqual(SecretRedactor.redact(input), expected)
    }

    func test_redact_exportPath_leftUntouched() {
        XCTAssertEqual(SecretRedactor.redact("export PATH=/usr/local/bin:$PATH"), "export PATH=/usr/local/bin:$PATH")
        XCTAssertEqual(SecretRedactor.redact("export EDITOR=vim"), "export EDITOR=vim")
    }

    func test_redact_inlineEnvPrefixAssignment_masksOnlyValue() {
        let input = "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI aws s3 ls"
        let expected = "AWS_SECRET_ACCESS_KEY=[redacted] aws s3 ls"

        XCTAssertEqual(SecretRedactor.redact(input), expected)
    }

    func test_redact_dotenvStyleOutputLine_masksValue() {
        let input = """
        OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz1234
        DATABASE_URL=postgres://user:pass@host:5432/db
        plain line here
        """
        let expected = """
        OPENAI_API_KEY=[redacted]
        DATABASE_URL=postgres://user:pass@host:5432/db
        plain line here
        """

        XCTAssertEqual(SecretRedactor.redact(input), expected)
    }

    func test_redact_singleAndDoubleQuotedAssignmentValues_maskedIncludingSpaces() {
        XCTAssertEqual(SecretRedactor.redact("export PASSWORD=\"two words\""), "export PASSWORD=[redacted]")
        XCTAssertEqual(SecretRedactor.redact("export PASSWORD='two words'"), "export PASSWORD=[redacted]")
    }

    func test_redact_gitAuthorEnvVars_leftUntouched() {
        let input = "GIT_AUTHOR_NAME=Alice git commit"

        XCTAssertEqual(SecretRedactor.redact(input), input,
                       "AUTH followed by OR (AUTHOR) must be excluded from the secret-name match")
    }

    // MARK: - fish `set`

    func test_redact_fishSetExportedSecret_masksAllValues() {
        XCTAssertEqual(SecretRedactor.redact("set -x API_KEY abc"), "set -x API_KEY [redacted]")
        XCTAssertEqual(SecretRedactor.redact("set -gx GITHUB_TOKEN a b c"), "set -gx GITHUB_TOKEN [redacted]",
                       "all list values must collapse to a single marker")
    }

    func test_redact_fishSetPath_leftUntouched() {
        let input = "set -x PATH /usr/bin $PATH"

        XCTAssertEqual(SecretRedactor.redact(input), input)
    }

    // MARK: - CLI secret flags

    func test_redact_passwordFlagEqualsForm_masksValue() {
        let input = "mytool --password=hunter2 --token=abc123 --api-key=abc123 --secret=abc123 --access-token=abc123"
        let expected = "mytool --password=[redacted] --token=[redacted] --api-key=[redacted] --secret=[redacted] --access-token=[redacted]"

        XCTAssertEqual(SecretRedactor.redact(input), expected)
    }

    func test_redact_passwordFlagSpaceForm_masksValue() {
        let input = "mytool --password hunter2 --token abc123 --api-key abc123 --secret abc123 --access-token abc123"
        let expected = "mytool --password [redacted] --token [redacted] --api-key [redacted] --secret [redacted] --access-token [redacted]"

        XCTAssertEqual(SecretRedactor.redact(input), expected)
    }

    func test_redact_flagFollowedByAnotherFlag_nextFlagNotMasked() {
        let input = "mytool --password --verbose"

        XCTAssertEqual(SecretRedactor.redact(input), input,
                       "--verbose is itself a flag, not --password's value, and must not be masked")
    }

    func test_redact_mysqlShortPAdjacency_leftUntouched() {
        let input = "mysql -pfoo"

        XCTAssertEqual(SecretRedactor.redact(input), input, "mysql -pNNN is deliberately not recognized as a secret flag")
    }

    // MARK: - Authorization headers

    func test_redact_authorizationBearerHeader_masksTokenKeepsScheme() {
        let input = "curl -H \"Authorization: Bearer eyJabc.def.ghi\""
        let expected = "curl -H \"Authorization: Bearer [redacted]\""

        XCTAssertEqual(SecretRedactor.redact(input), expected)
    }

    func test_redact_authorizationBasicAndLowercaseHeaders_masked() {
        XCTAssertEqual(SecretRedactor.redact("authorization: basic dXNlcjpwYXNz"), "authorization: basic [redacted]")
        XCTAssertEqual(SecretRedactor.redact("Authorization: Token abc123def456"), "Authorization: Token [redacted]")
    }

    // MARK: - Known token formats: GitHub

    func test_redact_githubClassicAndFineGrainedTokens_maskedAnywhere() {
        let classic = "found token ghp_iK2ZWeqhFWCEPyYngFb51yBMWXaSCrUZoL8g here"
        let classicExpected = "found token [redacted] here"
        XCTAssertEqual(SecretRedactor.redact(classic), classicExpected)

        let fineGrained = "found token github_pat_9382dffx1kVZQ2tqMnMc__ here"
        let fineGrainedExpected = "found token [redacted] here"
        XCTAssertEqual(SecretRedactor.redact(fineGrained), fineGrainedExpected)
    }

    // MARK: - Known token formats: OpenAI / Anthropic

    func test_redact_openAIAndAnthropicKeys_masked() {
        let openAI = "key is sk-proj-pLIix6MEOLeMa61EqJomTEI1J done"
        XCTAssertEqual(SecretRedactor.redact(openAI), "key is [redacted] done")

        let anthropic = "key is sk-ant-api03-ptgUzEjfebzJ6sZWdoHI done"
        XCTAssertEqual(SecretRedactor.redact(anthropic), "key is [redacted] done")
    }

    func test_redact_skLearnAndShortSkWords_leftUntouched() {
        XCTAssertEqual(SecretRedactor.redact("pip install sk-learn"), "pip install sk-learn")
        XCTAssertEqual(SecretRedactor.redact("sk-foo"), "sk-foo")
    }

    // MARK: - Known token formats: AWS / Slack / GitLab / npm / Google

    func test_redact_awsSlackGitlabNpmGoogleTokens_masked() {
        XCTAssertEqual(SecretRedactor.redact("key: AKIAIOSFODNN7EXAMPLE"), "key: [redacted]")
        XCTAssertEqual(SecretRedactor.redact("token: xoxb-123456789012"), "token: [redacted]")
        XCTAssertEqual(SecretRedactor.redact("token: glpat-NqVwYS81VP7Hb1DX8pPd5k"), "token: [redacted]")
        XCTAssertEqual(SecretRedactor.redact("token: npm_YK0fFWqcajQLE9WVxuXbrFZmU3A6IIRgmKJS"), "token: [redacted]")
        XCTAssertEqual(SecretRedactor.redact("key: AIzaSyD-9tSrke72PouQMnMX-a7eZSW0jkFMB12"), "key: [redacted]")
    }

    // MARK: - Known token formats: JWT

    func test_redact_jwtThreePart_masked() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        let input = "Authorization header value was \(jwt) in the log"
        let expected = "Authorization header value was [redacted] in the log"

        XCTAssertEqual(SecretRedactor.redact(input), expected)
    }

    func test_redact_shortEyJFragment_leftUntouched() {
        let input = "eyJab.eyJcd.ef"

        XCTAssertEqual(SecretRedactor.redact(input), input, "each part is too short to qualify as a JWT")
    }

    // MARK: - No-op on plain text

    func test_redact_plainCommandsAndOutput_unchanged() {
        XCTAssertEqual(SecretRedactor.redact("ls -la"), "ls -la")
        XCTAssertEqual(SecretRedactor.redact("git status"), "git status")

        let buildOutput = """
        Compiling foo v0.1.0 (/Users/dev/foo)
            Finished dev [unoptimized + debuginfo] target(s) in 1.23s
        """
        XCTAssertEqual(SecretRedactor.redact(buildOutput), buildOutput)
    }

    // MARK: - Idempotency

    func test_redact_idempotent_secondPassIsNoOp() {
        let input = """
        export API_KEY=abc123
        curl -H "Authorization: Bearer ghp_iK2ZWeqhFWCEPyYngFb51yBMWXaSCrUZoL8g"
        mytool --password=hunter2
        """

        let once = SecretRedactor.redact(input)
        let twice = SecretRedactor.redact(once)

        XCTAssertNotEqual(once, input, "precondition: the first pass must actually change the input")
        XCTAssertEqual(twice, once, "a second pass over already-redacted text must be a no-op")
    }
}
