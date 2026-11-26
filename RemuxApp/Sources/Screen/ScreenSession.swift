import Foundation

/// One GNU Screen session as reported by `screen -ls`.
///
/// Screen identifies a session by `<pid>.<name>`. The name may itself contain
/// dots (the default name is `<tty>.<host>`), so `pid` is only the leading
/// digits and `name` is everything after the first dot.
struct ScreenSession: Identifiable, Equatable, Hashable, Sendable {
    enum Status: Equatable, Hashable, Sendable {
        case attached
        case detached
        /// The socket exists but its owning process is gone. `screen -wipe`
        /// removes these.
        case dead
        case unknown(String)

        var displayName: String {
            switch self {
            case .attached: return "Attached"
            case .detached: return "Detached"
            case .dead: return "Dead"
            case .unknown(let raw): return raw
            }
        }
    }

    let pid: Int
    let name: String
    let status: Status
    /// Present when the session is shared by several displays
    /// (`(Multi, attached)`).
    let isMultiuser: Bool
    /// The raw date column printed by newer Screen builds, if any.
    let createdText: String?

    /// The exact selector accepted by `screen -S`, `-r` and `-X`.
    var id: String { "\(pid).\(name)" }
}

enum ScreenSessionListError: Error, Equatable, LocalizedError {
    case invalidUTF8
    case screenNotFound(String)
    case screenNotExecutable(String)
    case remoteExit(status: Int, stderr: String)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "The screen session list was not valid UTF-8."
        case .screenNotFound:
            return "GNU Screen is not installed on this server."
        case .screenNotExecutable:
            return "The screen executable on this server cannot be run."
        case .remoteExit(let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "screen exited with status \(status)." : detail
        }
    }
}

enum ScreenSessionListParser {
    /// Interprets the result of the `list` action.
    ///
    /// `screen -ls` exits non-zero in ordinary situations: 1 when there are no
    /// sockets, and on several builds also when sessions exist. Its stdout is
    /// therefore authoritative and the exit status is only consulted when the
    /// output is unrecognizable.
    static func sessions(from result: RemuxSSHExecResult) throws -> [ScreenSession] {
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        if result.exitStatus == 127,
           stderr.contains(ScreenCommandBuilder.screenNotFoundMarker) {
            throw ScreenSessionListError.screenNotFound(stderr)
        }
        if result.exitStatus == 126,
           stderr.contains(ScreenCommandBuilder.screenNotExecutableMarker) {
            throw ScreenSessionListError.screenNotExecutable(stderr)
        }

        guard let stdout = String(data: result.stdout, encoding: .utf8) else {
            throw ScreenSessionListError.invalidUTF8
        }
        if isNoSocketsOutput(stdout) || isNoSocketsOutput(stderr) {
            return []
        }

        let sessions = parse(stdout)
        if sessions.isEmpty, !isSocketListingOutput(stdout), result.exitStatus != 0 {
            throw ScreenSessionListError.remoteExit(
                status: result.exitStatus,
                stderr: stderr.isEmpty ? stdout : stderr
            )
        }
        return sessions
    }

    /// Parses `screen -ls` output. Lines that are not session rows (headers,
    /// the trailing socket-count line) are ignored.
    ///
    /// Accepted row shapes (fields are tab-separated):
    ///
    ///     \t12345.dev\t(Detached)
    ///     \t12345.pts-0.host\t(11/25/2026 09:14:02 AM)\t(Attached)
    ///     \t12345.shared\t(Multi, attached)
    ///     \t12345.gone\t(Dead ???)
    static func parse(_ output: String) -> [ScreenSession] {
        var sessions: [ScreenSession] = []
        var seen = Set<String>()
        for rawLine in output.split(whereSeparator: \.isNewline) {
            guard let session = parseRow(String(rawLine)),
                  seen.insert(session.id).inserted
            else { continue }
            sessions.append(session)
        }
        return sessions
    }

    static func parseRow(_ line: String) -> ScreenSession? {
        let fields = line
            .split(separator: "\t", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let selector = fields.first,
              let dot = selector.firstIndex(of: "."),
              let pid = Int(selector[..<dot]),
              pid > 0
        else { return nil }

        let name = String(selector[selector.index(after: dot)...])
        guard !name.isEmpty, !name.contains(where: \.isWhitespace) else { return nil }

        let parenthesized = fields.dropFirst().compactMap(unwrapParentheses)
        guard let rawStatus = parenthesized.last else { return nil }
        let createdText = parenthesized.count > 1 ? parenthesized[parenthesized.count - 2] : nil

        let (status, isMultiuser) = parseStatus(rawStatus)
        return ScreenSession(
            pid: pid,
            name: name,
            status: status,
            isMultiuser: isMultiuser,
            createdText: createdText
        )
    }

    static func parseStatus(_ raw: String) -> (ScreenSession.Status, Bool) {
        let lowered = raw.lowercased()
        let isMultiuser = lowered.contains("multi")
        if lowered.contains("dead") || lowered.contains("remote or dead") {
            return (.dead, isMultiuser)
        }
        if lowered.contains("detached") {
            return (.detached, isMultiuser)
        }
        if lowered.contains("attached") {
            return (.attached, isMultiuser)
        }
        return (.unknown(raw), isMultiuser)
    }

    private static func unwrapParentheses(_ field: String) -> String? {
        guard field.hasPrefix("("), field.hasSuffix(")"), field.count >= 2 else { return nil }
        return String(field.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    private static func isNoSocketsOutput(_ text: String) -> Bool {
        text.range(of: "No Sockets found", options: .caseInsensitive) != nil
    }

    private static func isSocketListingOutput(_ text: String) -> Bool {
        text.range(of: "There is a screen on", options: .caseInsensitive) != nil
            || text.range(of: "There are screens on", options: .caseInsensitive) != nil
            || text.range(of: "Socket in", options: .caseInsensitive) != nil
            || text.range(of: "Sockets in", options: .caseInsensitive) != nil
    }
}

extension Array where Element == ScreenSession {
    /// Detached sessions first (the ones you can attach to without stealing a
    /// display), then attached, then dead; alphabetical within each group.
    func sortedForDashboard() -> [ScreenSession] {
        func rank(_ status: ScreenSession.Status) -> Int {
            switch status {
            case .detached: return 0
            case .attached: return 1
            case .unknown: return 2
            case .dead: return 3
            }
        }
        return sorted { lhs, rhs in
            let l = rank(lhs.status), r = rank(rhs.status)
            if l != r { return l < r }
            let byName = lhs.name.localizedStandardCompare(rhs.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.pid < rhs.pid
        }
    }
}
