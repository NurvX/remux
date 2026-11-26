import Foundation
import XCTest
@testable import Remux

/// Fixtures are verbatim `screen -ls` output captured from GNU Screen 4.09.01
/// (including the CRLF line endings Screen writes on its header lines).
final class ScreenSessionListParserTests: XCTestCase {
    func testParsesDetachedAttachedAndDeadRowsWithDateColumn() {
        let output = """
        There are screens on:\r
        \t1119.remux-att\t(11/26/26 00:22:01)\t(Attached)
        \t954.remux-cmd\t(11/26/26 00:20:59)\t(Detached)
        \t891.remux-test\t(11/26/26 00:20:58)\t(Dead ???)
        Remove dead screens with 'screen -wipe'.
        3 Sockets in /run/screen/S-root.\r

        """

        let sessions = ScreenSessionListParser.parse(output)

        XCTAssertEqual(sessions.map(\.id), ["1119.remux-att", "954.remux-cmd", "891.remux-test"])
        XCTAssertEqual(sessions.map(\.status), [.attached, .detached, .dead])
        XCTAssertEqual(sessions.map(\.pid), [1119, 954, 891])
        XCTAssertEqual(sessions.first?.createdText, "11/26/26 00:22:01")
    }

    func testParsesRowsWithoutDateColumnAndDottedDefaultNames() {
        let output = "There is a screen on:\n\t4242.pts-0.build-host\t(Detached)\n1 Socket in /tmp/screens/S-me.\n"

        let sessions = ScreenSessionListParser.parse(output)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].pid, 4242)
        XCTAssertEqual(sessions[0].name, "pts-0.build-host")
        XCTAssertEqual(sessions[0].id, "4242.pts-0.build-host")
        XCTAssertNil(sessions[0].createdText)
    }

    func testMultiuserAndUnknownStatuses() {
        let sessions = ScreenSessionListParser.parse(
            "\t10.shared\t(Multi, attached)\n\t11.odd\t(Private)\n\t12.wiped\t(Removed)\n"
        )

        XCTAssertEqual(sessions[0].status, .attached)
        XCTAssertTrue(sessions[0].isMultiuser)
        XCTAssertEqual(sessions[1].status, .unknown("Private"))
        XCTAssertEqual(sessions[2].status, .unknown("Removed"))
    }

    func testIgnoresHeadersFootersAndDuplicates() {
        let sessions = ScreenSessionListParser.parse(
            "There are screens on:\n\t1.a\t(Detached)\n\t1.a\t(Detached)\n2 Sockets in /run/screen/S-x.\n"
        )
        XCTAssertEqual(sessions.map(\.id), ["1.a"])
    }

    func testNoSocketsExitStatusOneIsAnEmptyList() throws {
        let result = RemuxSSHExecResult(
            exitStatus: 1,
            stdout: Data("No Sockets found in /run/screen/S-root.\n\n".utf8),
            stderr: Data()
        )
        XCTAssertEqual(try ScreenSessionListParser.sessions(from: result), [])
    }

    func testNonZeroExitWithSessionsStillParses() throws {
        let result = RemuxSSHExecResult(
            exitStatus: 1,
            stdout: Data("There is a screen on:\n\t7.x\t(Detached)\n1 Socket in /run/screen/S-u.\n".utf8),
            stderr: Data()
        )
        XCTAssertEqual(try ScreenSessionListParser.sessions(from: result).map(\.id), ["7.x"])
    }

    func testMissingScreenIsReported() {
        let result = RemuxSSHExecResult(
            exitStatus: 127,
            stdout: Data(),
            stderr: Data("\(ScreenCommandBuilder.screenNotFoundMarker): screen\n".utf8)
        )
        XCTAssertThrowsError(try ScreenSessionListParser.sessions(from: result)) {
            XCTAssertEqual($0 as? ScreenSessionListError, .screenNotFound("\(ScreenCommandBuilder.screenNotFoundMarker): screen\n"))
        }
    }

    func testUnrecognizedFailureIsReported() {
        let result = RemuxSSHExecResult(
            exitStatus: 1,
            stdout: Data(),
            stderr: Data("Cannot make directory '/run/screen': Permission denied\n".utf8)
        )
        XCTAssertThrowsError(try ScreenSessionListParser.sessions(from: result)) {
            guard case .remoteExit(1, let stderr)? = $0 as? ScreenSessionListError else {
                return XCTFail("unexpected \($0)")
            }
            XCTAssertTrue(stderr.contains("Permission denied"))
        }
    }

    func testDashboardOrderingGroupsByStatus() {
        let sessions = ScreenSessionListParser.parse(
            "\t3.zeta\t(Attached)\n\t2.dead\t(Dead ???)\n\t1.beta\t(Detached)\n\t4.alpha\t(Detached)\n"
        )
        XCTAssertEqual(
            sessions.sortedForDashboard().map(\.id),
            ["4.alpha", "1.beta", "3.zeta", "2.dead"]
        )
    }
}

final class ScreenCommandBuilderTests: XCTestCase {
    func testCommandsKeepUserValuesOutOfShellSyntax() throws {
        let hostile = "x'; touch /tmp/pwned; echo '"
        let name = try XCTUnwrap(ScreenSessionName(sanitizing: "work"))
        let command = ScreenCommandBuilder.command(
            .create(name: name, initialInput: .literal(hostile)),
            screenExecutable: "/opt/my tools/screen"
        )

        XCTAssertTrue(command.hasPrefix("exec /bin/sh -c '"))
        XCTAssertFalse(command.contains("touch /tmp/pwned"))
        XCTAssertFalse(command.contains("/opt/my tools"))
        XCTAssertTrue(command.contains(" create "))
    }

    func testListAndWipeForceCLocale() {
        let list = ScreenCommandBuilder.command(.list)
        XCTAssertTrue(list.contains(#"list) LC_ALL=C; export LC_ALL; exec "$resolved" -ls;;"#))
        XCTAssertTrue(list.hasSuffix(" list"))
        XCTAssertTrue(ScreenCommandBuilder.command(.wipe).hasSuffix(" wipe"))
    }

    func testScriptIsWellFormedCaseStatement() {
        let command = ScreenCommandBuilder.command(.list)
        XCTAssertTrue(command.contains(#"case "$2" in list)"#))
        XCTAssertFalse(command.contains(";;;"))
        XCTAssertTrue(command.contains(";; esac"))
    }

    func testAttachUsesUTF8AndDetachesOtherDisplays() throws {
        let selector = try XCTUnwrap(ScreenSessionSelector(rawValue: "123.dev"))
        let command = ScreenCommandBuilder.command(.attach(selector: selector))
        XCTAssertTrue(command.contains(#"TERM=xterm-256color; export TERM; exec "$resolved" -U -d -r "$target""#))
        XCTAssertTrue(command.hasSuffix(" attach \(ScreenCommandBuilder.octalEncodedArgument("123.dev"))"))
    }

    func testOctalEncoding() {
        XCTAssertEqual(ScreenCommandBuilder.octalEncodedArgument("a'"), #"'\0141\0047'"#)
    }

    func testSessionNameSanitizing() {
        XCTAssertEqual(ScreenSessionName(sanitizing: "  my build.server/1 ")?.rawValue, "my-build-server-1")
        XCTAssertEqual(ScreenSessionName(sanitizing: "--lead--trail--")?.rawValue, "lead-trail")
        XCTAssertEqual(ScreenSessionName(sanitizing: "naïve_name")?.rawValue, "nave_name")
        XCTAssertNil(ScreenSessionName(sanitizing: "..."))
        XCTAssertNil(ScreenSessionName(sanitizing: ""))
        XCTAssertEqual(
            ScreenSessionName(sanitizing: String(repeating: "a", count: 100))?.rawValue.count,
            ScreenSessionName.maximumLength
        )
    }

    func testSelectorValidation() {
        XCTAssertNotNil(ScreenSessionSelector(rawValue: "1.a"))
        XCTAssertNotNil(ScreenSessionSelector(rawValue: "4242.pts-0.host"))
        XCTAssertNil(ScreenSessionSelector(rawValue: "a.b"))
        XCTAssertNil(ScreenSessionSelector(rawValue: "12."))
        XCTAssertNil(ScreenSessionSelector(rawValue: ".x"))
        XCTAssertNil(ScreenSessionSelector(rawValue: "1.a b"))
    }

    /// Escaping verified against GNU Screen 4.09: stuffing this encoding makes
    /// the window receive the original line byte for byte.
    func testLiteralStuffEscapesScreenMetacharacters() {
        XCTAssertEqual(
            ScreenStuffText.literal(#"echo "$HOME ${USER} ^A \ 'q'""#).encoded,
            #"echo "\$HOME \${USER} \^A \\ 'q'"^M"#
        )
        XCTAssertEqual(ScreenStuffText.literal("a\nb", pressReturn: false).encoded, "a^Mb")
    }

    func testControlStuff() {
        XCTAssertEqual(ScreenStuffText.control("c")?.encoded, "^C")
        XCTAssertEqual(ScreenStuffText.control("[")?.encoded, "^[")
        XCTAssertNil(ScreenStuffText.control("1"))
    }
}
