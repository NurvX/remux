import Foundation
import SwiftUI

/// State and actions for the GNU Screen session dashboard of one server.
@MainActor
final class ScreenDashboardModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    struct QuickCommand: Identifiable, Hashable {
        let id: String
        let title: String
        let systemImage: String
        let text: ScreenStuffText

        static let presets: [QuickCommand] = [
            QuickCommand(id: "ctrl-c", title: "Interrupt (Ctrl+C)", systemImage: "stop.circle", text: .control("C")!),
            QuickCommand(id: "ctrl-d", title: "End of Input (Ctrl+D)", systemImage: "eject.circle", text: .control("D")!),
            QuickCommand(id: "ctrl-z", title: "Suspend (Ctrl+Z)", systemImage: "pause.circle", text: .control("Z")!),
            QuickCommand(id: "git-pull", title: "git pull", systemImage: "arrow.down.circle", text: .literal("git pull")),
            QuickCommand(id: "clear", title: "clear", systemImage: "eraser", text: .literal("clear")),
        ]
    }

    @Published private(set) var sessions: [ScreenSession] = []
    @Published private(set) var phase: Phase = .idle
    @Published var failure: ScreenFailure?
    @Published private(set) var busySessionIDs: Set<ScreenSession.ID> = []
    @Published private(set) var isMutating = false
    @Published private(set) var lastRefresh: Date?

    let service: ScreenSessionService

    init(service: ScreenSessionService) {
        self.service = service
    }

    var serverName: String { service.server.displayName }

    var detachedSessions: [ScreenSession] { sessions.filter { $0.status == .detached } }
    var attachedSessions: [ScreenSession] { sessions.filter { $0.status == .attached } }
    var otherSessions: [ScreenSession] {
        sessions.filter { $0.status != .detached && $0.status != .attached }
    }
    var hasDeadSessions: Bool { sessions.contains { $0.status == .dead } }

    func refresh() async {
        if phase != .loaded { phase = .loading }
        do {
            sessions = try await service.listSessions().sortedForDashboard()
            phase = .loaded
            lastRefresh = Date()
        } catch is CancellationError {
            if phase == .loading { phase = .idle }
        } catch {
            phase = sessions.isEmpty ? .failed : .loaded
            failure = ScreenFailure(error)
        }
    }

    func createSession(name rawName: String, initialCommand: String) async -> Bool {
        guard let name = ScreenSessionName(sanitizing: rawName) else {
            failure = ScreenFailure(message: "Use letters, numbers, dashes, or underscores for the session name.")
            return false
        }
        if sessions.contains(where: { $0.name == name.rawValue && $0.status != .dead }) {
            failure = ScreenFailure(ScreenCommandError.duplicateName(name.rawValue))
            return false
        }
        return await mutate {
            try await self.service.createSession(named: name, initialCommand: initialCommand)
        }
    }

    func kill(_ session: ScreenSession) async {
        _ = await mutate(session: session) {
            try await self.service.kill(session)
        }
    }

    func send(_ command: QuickCommand, to session: ScreenSession) async {
        await send(command.text, to: session)
    }

    func send(_ text: ScreenStuffText, to session: ScreenSession) async {
        _ = await mutate(session: session, refreshAfterwards: false) {
            try await self.service.send(text, to: session)
        }
    }

    func wipeDeadSessions() async {
        _ = await mutate {
            try await self.service.wipeDeadSessions()
        }
    }

    func trustHostKey(_ challenge: SSHHostKeyTrustChallenge) async {
        do {
            try service.trustHostKey(challenge)
            failure = nil
            await refresh()
        } catch {
            failure = ScreenFailure(error)
        }
    }

    func makeTerminalModel(for session: ScreenSession) -> ScreenTerminalModel {
        ScreenTerminalModel(session: session, service: service)
    }

    private func mutate(
        session: ScreenSession? = nil,
        refreshAfterwards: Bool = true,
        _ operation: @escaping () async throws -> Void
    ) async -> Bool {
        if let session { busySessionIDs.insert(session.id) }
        isMutating = true
        defer {
            if let session { busySessionIDs.remove(session.id) }
            isMutating = false
        }
        do {
            try await operation()
            if refreshAfterwards { await refresh() }
            return true
        } catch is CancellationError {
            return false
        } catch {
            failure = ScreenFailure(error)
            if refreshAfterwards { await refresh() }
            return false
        }
    }
}
