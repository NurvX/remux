import SwiftUI

/// Lists the GNU Screen sessions on one server and manages them: refresh,
/// create, kill, send quick commands, wipe dead sockets, and attach.
struct ScreenDashboardView: View {
    @StateObject private var model: ScreenDashboardModel

    @State private var isCreatingSession = false
    @State private var sessionPendingKill: ScreenSession?
    @State private var commandTarget: ScreenSession?
    @State private var attachedTerminal: ScreenTerminalModel?

    init(model: @autoclosure @escaping () -> ScreenDashboardModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        List {
            if model.phase == .loaded && model.sessions.isEmpty {
                emptyState
            }
            sessionSection("Detached", sessions: model.detachedSessions)
            sessionSection("Attached", sessions: model.attachedSessions)
            sessionSection("Other", sessions: model.otherSessions)
            if model.hasDeadSessions {
                Section {
                    Button {
                        Task { await model.wipeDeadSessions() }
                    } label: {
                        Label("Wipe Dead Sessions", systemImage: "trash.slash")
                    }
                    .disabled(model.isMutating)
                } footer: {
                    Text("Removes sockets left behind by sessions whose process has ended.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if model.phase == .loading && model.sessions.isEmpty {
                ProgressView("Loading Sessions\u{2026}")
            } else if model.phase == .failed && model.sessions.isEmpty {
                ContentUnavailableView {
                    Label("Couldn\u{2019}t Load Sessions", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(model.failure?.message ?? "Pull to try again.")
                } actions: {
                    Button("Try Again") { Task { await model.refresh() } }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                isCreatingSession = true
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .shadow(radius: 4, y: 2)
            .padding(20)
            .accessibilityLabel("New Screen Session")
            .accessibilityIdentifier("screen.dashboard.new")
        }
        .refreshable { await model.refresh() }
        .task { if model.phase == .idle { await model.refresh() } }
        .navigationTitle("Screen Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Button {
                        Task { await model.wipeDeadSessions() }
                    } label: {
                        Label("Wipe Dead Sessions", systemImage: "trash.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
        .sheet(isPresented: $isCreatingSession) {
            NewScreenSessionSheet(model: model)
        }
        .sheet(item: $commandTarget) { session in
            ScreenQuickCommandSheet(model: model, session: session)
        }
        .confirmationDialog(
            "Kill \u{201C}\(sessionPendingKill?.name ?? "")\u{201D}?",
            isPresented: Binding(
                get: { sessionPendingKill != nil },
                set: { if !$0 { sessionPendingKill = nil } }
            ),
            titleVisibility: .visible,
            presenting: sessionPendingKill
        ) { session in
            Button("Kill Session", role: .destructive) {
                Task { await model.kill(session) }
            }
        } message: { _ in
            Text("Every window in this session and the programs running in them will be terminated.")
        }
        .alert(
            model.failure?.hostKeyChallenge == nil ? "Screen Error" : "Trust This Server?",
            isPresented: Binding(
                get: { model.failure != nil && model.phase != .failed },
                set: { if !$0 { model.failure = nil } }
            ),
            presenting: model.failure
        ) { failure in
            if let challenge = failure.hostKeyChallenge, challenge.receivedKeyFingerprint != nil {
                Button("Cancel", role: .cancel) {}
                Button(challenge.kind == .changed ? "Update Trust" : "Trust Server") {
                    Task { await model.trustHostKey(challenge) }
                }
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { failure in
            if let challenge = failure.hostKeyChallenge, let fingerprint = challenge.receivedKeyFingerprint {
                Text("\(failure.message)\n\n\(challenge.receivedKeyType) \(fingerprint)")
            } else {
                Text(failure.message)
            }
        }
        .fullScreenCover(item: $attachedTerminal, onDismiss: {
            Task { await model.refresh() }
        }) { terminal in
            ScreenTerminalScreen(model: terminal)
        }
    }

    @ViewBuilder
    private func sessionSection(_ title: String, sessions: [ScreenSession]) -> some View {
        if !sessions.isEmpty {
            Section(title) {
                ForEach(sessions) { session in
                    Button {
                        attach(session)
                    } label: {
                        ScreenSessionRow(
                            session: session,
                            isBusy: model.busySessionIDs.contains(session.id)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(session.status == .dead)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Kill", role: .destructive) {
                            sessionPendingKill = session
                        }
                        if session.status != .dead {
                            Button("Send") {
                                commandTarget = session
                            }
                            .tint(.indigo)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if session.status != .dead {
                            Button("Attach") { attach(session) }
                                .tint(.green)
                        }
                    }
                    .contextMenu {
                        if session.status != .dead {
                            Button {
                                attach(session)
                            } label: {
                                Label("Attach", systemImage: "terminal")
                            }
                            Menu {
                                ForEach(ScreenDashboardModel.QuickCommand.presets) { command in
                                    Button {
                                        Task { await model.send(command, to: session) }
                                    } label: {
                                        Label(command.title, systemImage: command.systemImage)
                                    }
                                }
                            } label: {
                                Label("Send Command", systemImage: "paperplane")
                            }
                        }
                        Button(role: .destructive) {
                            sessionPendingKill = session
                        } label: {
                            Label("Kill Session", systemImage: "xmark.octagon")
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.stack")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No Screen Sessions")
                    .font(.headline)
                Text("Tap + to start a background session on \(model.serverName).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    private func attach(_ session: ScreenSession) {
        guard session.status != .dead else { return }
        attachedTerminal = model.makeTerminalModel(for: session)
    }
}

extension ScreenTerminalModel: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

private struct ScreenSessionRow: View {
    let session: ScreenSession
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.body.weight(.medium))
                .foregroundStyle(iconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.name)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text("PID \(session.pid, format: .number.grouping(.never))")
                    if let created = session.createdText {
                        Text("\u{00B7}")
                        Text(created)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isBusy {
                ProgressView()
            } else {
                ScreenStatusBadge(status: session.status, isMultiuser: session.isMultiuser)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint(session.status == .dead ? "" : "Attaches to this session")
    }

    private var iconColor: Color {
        switch session.status {
        case .detached: return .green
        case .attached: return .orange
        case .dead: return .red
        case .unknown: return .secondary
        }
    }
}

struct ScreenStatusBadge: View {
    let status: ScreenSession.Status
    var isMultiuser = false

    var body: some View {
        Text(isMultiuser ? "Multi \u{00B7} \(status.displayName)" : status.displayName)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var color: Color {
        switch status {
        case .detached: return .green
        case .attached: return .orange
        case .dead: return .red
        case .unknown: return .gray
        }
    }
}

private struct NewScreenSessionSheet: View {
    @ObservedObject var model: ScreenDashboardModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var initialCommand = ""
    @State private var isSubmitting = false
    @FocusState private var nameFocused: Bool

    private var sanitizedName: String? {
        ScreenSessionName(sanitizing: name)?.rawValue
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .focused($nameFocused)
                        .submitLabel(.next)
                } header: {
                    Text("Session Name")
                } footer: {
                    if let sanitizedName, sanitizedName != name {
                        Text("Will be created as \u{201C}\(sanitizedName)\u{201D}.")
                    } else {
                        Text("Letters, numbers, dashes, and underscores.")
                    }
                }

                Section {
                    TextField("e.g. npm run dev", text: $initialCommand, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("Start With Command (Optional)")
                } footer: {
                    Text("Typed into the session\u{2019}s shell, so the session keeps running after the command finishes.")
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button("Create") {
                            isSubmitting = true
                            Task {
                                let created = await model.createSession(
                                    name: name,
                                    initialCommand: initialCommand
                                )
                                isSubmitting = false
                                if created { dismiss() }
                            }
                        }
                        .disabled(sanitizedName == nil)
                    }
                }
            }
            .onAppear { nameFocused = true }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct ScreenQuickCommandSheet: View {
    @ObservedObject var model: ScreenDashboardModel
    let session: ScreenSession
    @Environment(\.dismiss) private var dismiss

    @State private var customCommand = ""
    @State private var pressReturn = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Quick Commands") {
                    ForEach(ScreenDashboardModel.QuickCommand.presets) { command in
                        Button {
                            Task {
                                await model.send(command, to: session)
                                dismiss()
                            }
                        } label: {
                            Label(command.title, systemImage: command.systemImage)
                        }
                    }
                }

                Section {
                    TextField("Command", text: $customCommand, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    Toggle("Press Return", isOn: $pressReturn)
                    Button("Send") {
                        let text = ScreenStuffText.literal(customCommand, pressReturn: pressReturn)
                        Task {
                            await model.send(text, to: session)
                            dismiss()
                        }
                    }
                    .disabled(customCommand.isEmpty)
                } header: {
                    Text("Custom")
                } footer: {
                    Text("Typed into the session\u{2019}s current window without attaching.")
                }
            }
            .navigationTitle(session.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
