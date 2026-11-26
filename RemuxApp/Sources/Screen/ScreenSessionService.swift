import Foundation

enum ScreenCommandError: Error, Equatable, LocalizedError {
    case remoteExit(status: Int, message: String)
    case duplicateName(String)

    var errorDescription: String? {
        switch self {
        case .remoteExit(let status, let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "screen exited with status \(status)." : detail
        case .duplicateName(let name):
            return "A session named \u{201C}\(name)\u{201D} already exists."
        }
    }
}

/// Headless GNU Screen management for one saved server.
///
/// Every call resolves the server's credentials and runs over the app's pooled
/// SSH connection, so repeated dashboard actions reuse one authenticated
/// transport.
struct ScreenSessionService: Sendable {
    let server: SavedServer
    let terminalSettings: TerminalSettings
    let screenExecutable: String

    private let resolveAuth: @Sendable () async throws -> ResolvedSSHAuth
    private let dependencies: RemuxAppDependencies

    init(
        server: SavedServer,
        terminalSettings: TerminalSettings,
        screenExecutable: String = ScreenCommandBuilder.defaultExecutable,
        dependencies: RemuxAppDependencies,
        resolveAuth: @escaping @Sendable () async throws -> ResolvedSSHAuth
    ) {
        self.server = server
        self.terminalSettings = terminalSettings
        self.screenExecutable = screenExecutable
        self.dependencies = dependencies
        self.resolveAuth = resolveAuth
    }

    func listSessions() async throws -> [ScreenSession] {
        let result = try await run(.list)
        return try ScreenSessionListParser.sessions(from: result)
    }

    func createSession(named name: ScreenSessionName, initialCommand: String?) async throws {
        let trimmed = initialCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let input = trimmed.isEmpty ? nil : ScreenStuffText.literal(trimmed)
        try requireSuccess(await run(.create(name: name, initialInput: input)))
    }

    func kill(_ session: ScreenSession) async throws {
        try requireSuccess(await run(.kill(selector: ScreenSessionSelector(session))))
    }

    func send(_ text: ScreenStuffText, to session: ScreenSession) async throws {
        try requireSuccess(await run(.stuff(selector: ScreenSessionSelector(session), text: text)))
    }

    /// `screen -wipe` exits non-zero whenever live sessions remain, so only
    /// a missing executable is treated as failure.
    func wipeDeadSessions() async throws {
        let result = try await run(.wipe)
        if result.exitStatus == 126 || result.exitStatus == 127 {
            _ = try ScreenSessionListParser.sessions(from: result)
        }
    }

    func openAttach(
        to session: ScreenSession,
        grid: ScreenTerminalSurfaceView.Grid,
        onData: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable (Int?, Error?) -> Void
    ) async throws -> RemuxSSHExecConnection {
        let auth = try await resolveAuth()
        return try await dependencies.openScreenTerminal(
            command: ScreenCommandBuilder.command(
                .attach(selector: ScreenSessionSelector(session)),
                screenExecutable: screenExecutable
            ),
            pty: RemuxSSHPTYRequest(
                term: ScreenCommandBuilder.terminalType,
                columns: grid.columns,
                rows: grid.rows,
                pixelWidth: grid.pixelWidth,
                pixelHeight: grid.pixelHeight
            ),
            server: server,
            sshAuth: auth,
            onData: onData,
            onFinish: onFinish
        )
    }

    func trustHostKey(_ challenge: SSHHostKeyTrustChallenge) throws {
        try dependencies.trustedHostStore.trustHostKey(challenge)
    }

    private func run(_ action: ScreenCommandBuilder.Action) async throws -> RemuxSSHExecResult {
        let auth = try await resolveAuth()
        return try await dependencies.runScreenCommand(
            ScreenCommandBuilder.command(action, screenExecutable: screenExecutable),
            server: server,
            sshAuth: auth
        )
    }

    private func requireSuccess(_ result: RemuxSSHExecResult) throws {
        guard result.exitStatus != 0 else { return }
        if result.exitStatus == 126 || result.exitStatus == 127 {
            _ = try ScreenSessionListParser.sessions(from: result)
        }
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        throw ScreenCommandError.remoteExit(
            status: result.exitStatus,
            message: stderr.isEmpty ? stdout : stderr
        )
    }
}

/// A user-presentable failure, with the host-key challenge when the failure
/// was an untrusted server key.
struct ScreenFailure: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let hostKeyChallenge: SSHHostKeyTrustChallenge?

    init(_ error: any Error) {
        if let screenError = error as? ScreenSessionListError {
            message = screenError.localizedDescription
            hostKeyChallenge = nil
            return
        }
        if let commandError = error as? ScreenCommandError {
            message = commandError.localizedDescription
            hostKeyChallenge = nil
            return
        }
        let reason = GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(error)
        hostKeyChallenge = reason.hostKeyChallenge
        switch reason.kind {
        case .serverUnreachable:
            message = "Remux could not reach the server. Check the address, port, network, or VPN."
        case .authentication:
            message = "The server rejected these credentials."
        case .hostKey:
            message = reason.hostKeyChallenge == nil
                ? "Remux could not verify the SSH host key."
                : "This server's SSH host key is not trusted yet."
        default:
            message = error.localizedDescription
        }
    }

    init(message: String) {
        self.message = message
        hostKeyChallenge = nil
    }

    static func == (lhs: ScreenFailure, rhs: ScreenFailure) -> Bool {
        lhs.id == rhs.id
    }
}
