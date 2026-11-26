import Foundation
import NIOConcurrencyHelpers
import UIKit

/// Drives one interactive `screen -r` attachment: owns the SSH PTY channel,
/// pumps bytes between it and the Ghostty surface in order, forwards window
/// size changes, and keeps the socket alive briefly in the background.
@MainActor
final class ScreenTerminalModel: ObservableObject {
    enum State: Equatable {
        case waitingForLayout
        case connecting
        case connected
        /// The Screen client exited: detached, or the session ended.
        case ended(String)
        case failed(ScreenFailure)
    }

    /// Screen's command prefix (Ctrl+A).
    static let prefix: UInt8 = 0x01

    let session: ScreenSession
    let service: ScreenSessionService
    let terminalView: ScreenTerminalSurfaceView

    @Published private(set) var state: State = .waitingForLayout
    @Published var ctrlLatched = false {
        didSet { terminalView.ctrlLatched = ctrlLatched }
    }
    @Published var altLatched = false {
        didSet { terminalView.altLatched = altLatched }
    }
    /// Best-effort local tracking of Screen's copy mode, used to make the
    /// scroll gestures behave sensibly.
    @Published private(set) var isInCopyMode = false
    @Published private(set) var didRequestDetach = false

    private var connection: RemuxSSHExecConnection?
    private var connectTask: Task<Void, Never>?
    private var inboundTask: Task<Void, Never>?
    private var outboundTask: Task<Void, Never>?
    private var outboundContinuation: AsyncStream<OutboundItem>.Continuation?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []
    private var connectionGeneration = 0
    /// The PTY size last reported to the server.
    private var remoteGrid: ScreenTerminalSurfaceView.Grid?

    private enum OutboundItem: Sendable {
        case bytes(Data)
        case resize(ScreenTerminalSurfaceView.Grid)
    }

    init(session: ScreenSession, service: ScreenSessionService) {
        self.session = session
        self.service = service
        terminalView = ScreenTerminalSurfaceView(settings: service.terminalSettings)

        terminalView.onWrite = { [weak self] data in
            self?.enqueue(.bytes(data)) ?? false
        }
        terminalView.onGridChange = { [weak self] grid in
            self?.gridDidChange(grid)
        }
        terminalView.onModifiersConsumed = { [weak self] in
            guard let self else { return }
            if ctrlLatched { ctrlLatched = false }
            if altLatched { altLatched = false }
        }
        terminalView.onRendererFailure = { [weak self] message in
            self?.state = .failed(ScreenFailure(message: message))
        }
        terminalView.onTwoFingerTap = { [weak self] in
            guard let self else { return }
            if isInCopyMode { exitCopyMode() } else { enterCopyMode() }
        }
        terminalView.onTwoFingerSwipe = { [weak self] direction in
            guard let self else { return }
            switch direction {
            // Content follows the fingers: swiping down reveals older output.
            case .down: scrollBack(pageUp: true)
            case .up: scrollBack(pageUp: false)
            case .left: sendPrefixed("n")
            case .right: sendPrefixed("p")
            default: break
            }
        }
        observeAppLifecycle()
    }

    deinit {
        MainActor.assumeIsolated {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            connectTask?.cancel()
            inboundTask?.cancel()
            outboundTask?.cancel()
            outboundContinuation?.finish()
            if let connection {
                Task { await connection.close(disposition: .reusable) }
            }
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }
    }

    var title: String { session.name }

    var isLive: Bool { state == .connected }

    // MARK: Lifecycle

    /// Reconnects after a failure or after the app was suspended.
    func reconnect() {
        guard let grid = terminalView.grid else {
            state = .waitingForLayout
            return
        }
        teardownConnection()
        connect(grid: grid)
    }

    /// Cleanly detaches (Ctrl+A d). Screen's client exits and the channel
    /// closes, which ends the attachment while the session keeps running.
    func detach() {
        guard isLive else {
            close()
            return
        }
        didRequestDetach = true
        sendPrefixed("d")
    }

    /// Closes the SSH channel without detaching first. Screen notices the
    /// hang-up and detaches the session on its own.
    func close() {
        teardownConnection()
        if case .connected = state { state = .ended("Disconnected") }
        if case .connecting = state { state = .ended("Disconnected") }
        endBackgroundTask()
    }

    private func gridDidChange(_ grid: ScreenTerminalSurfaceView.Grid) {
        switch state {
        case .waitingForLayout:
            connect(grid: grid)
        case .connected:
            if let remoteGrid, remoteGrid.columns == grid.columns, remoteGrid.rows == grid.rows {
                // Same size, fresh (blank) terminal: ask Screen to redisplay.
                sendPrefixed("l")
            } else {
                enqueue(.resize(grid))
            }
        case .connecting:
            // Picked up once the channel is open.
            break
        case .ended, .failed:
            break
        }
    }

    private func connect(grid: ScreenTerminalSurfaceView.Grid) {
        connectionGeneration += 1
        let generation = connectionGeneration
        state = .connecting
        didRequestDetach = false
        isInCopyMode = false

        let (inbound, inboundContinuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .unbounded
        )
        let finish = FinishBox()

        inboundTask = Task { [weak self] in
            for await chunk in inbound {
                guard let self, self.connectionGeneration == generation else { return }
                self.terminalView.feed(chunk)
            }
            guard let self, self.connectionGeneration == generation else { return }
            self.connectionDidFinish(finish.value)
        }

        let (outbound, outboundContinuation) = AsyncStream<OutboundItem>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.outboundContinuation = outboundContinuation

        connectTask = Task { [weak self, service, session] in
            do {
                let connection = try await service.openAttach(
                    to: session,
                    grid: grid,
                    onData: { data in inboundContinuation.yield(data) },
                    onFinish: { exitStatus, error in
                        finish.set(exitStatus: exitStatus, error: error)
                        inboundContinuation.finish()
                    }
                )
                guard let self, !Task.isCancelled, self.connectionGeneration == generation else {
                    await connection.close(disposition: .reusable)
                    return
                }
                self.connection = connection
                self.remoteGrid = grid
                self.state = .connected
                self.startOutboundPump(outbound, connection: connection, generation: generation)
                // The grid may have changed while the channel was opening.
                if let current = self.terminalView.grid,
                   current.columns != grid.columns || current.rows != grid.rows {
                    self.enqueue(.resize(current))
                }
            } catch {
                inboundContinuation.finish()
                guard let self, self.connectionGeneration == generation else { return }
                if !(error is CancellationError) {
                    self.state = .failed(ScreenFailure(error))
                }
            }
        }
    }

    private func startOutboundPump(
        _ outbound: AsyncStream<OutboundItem>,
        connection: RemuxSSHExecConnection,
        generation: Int
    ) {
        outboundTask = Task { [weak self] in
            for await item in outbound {
                do {
                    switch item {
                    case .bytes(let data):
                        try await connection.write(data)
                    case .resize(let grid):
                        try await connection.resizePTY(
                            columns: grid.columns,
                            rows: grid.rows,
                            pixelWidth: grid.pixelWidth,
                            pixelHeight: grid.pixelHeight
                        )
                    }
                } catch {
                    guard let self, self.connectionGeneration == generation else { return }
                    self.state = .failed(ScreenFailure(error))
                    return
                }
            }
        }
    }

    private func connectionDidFinish(_ result: (exitStatus: Int?, error: Error?)) {
        let closingConnection = connection
        connection = nil
        outboundContinuation?.finish()
        outboundContinuation = nil
        if let closingConnection {
            Task { await closingConnection.close(disposition: .reusable) }
        }
        endBackgroundTask()

        switch state {
        case .failed:
            return
        default:
            break
        }
        if let error = result.error, !didRequestDetach {
            state = .failed(ScreenFailure(error))
        } else if didRequestDetach {
            state = .ended("Detached")
        } else if let status = result.exitStatus, status != 0 {
            state = .failed(ScreenFailure(message: "screen exited with status \(status)."))
        } else {
            state = .ended("Session closed")
        }
    }

    private func teardownConnection() {
        connectionGeneration += 1
        connectTask?.cancel()
        connectTask = nil
        inboundTask?.cancel()
        inboundTask = nil
        outboundTask?.cancel()
        outboundTask = nil
        outboundContinuation?.finish()
        outboundContinuation = nil
        if let connection {
            self.connection = nil
            Task { await connection.close(disposition: .reusable) }
        }
    }

    @discardableResult
    private func enqueue(_ item: OutboundItem) -> Bool {
        guard state == .connected, let outboundContinuation else { return false }
        switch item {
        case .bytes(let data):
            updateCopyModeTracking(for: data)
        case .resize(let grid):
            remoteGrid = grid
        }
        outboundContinuation.yield(item)
        return true
    }

    // MARK: Screen key macros

    /// Sends the Screen prefix followed by `key` (e.g. "d" to detach,
    /// "[" for copy mode, "c" for a new window).
    func sendPrefixed(_ key: String) {
        var data = Data([Self.prefix])
        data.append(contentsOf: key.utf8)
        terminalView.sendRaw(data)
    }

    func sendPrefix() {
        terminalView.sendRaw(Data([Self.prefix]))
    }

    func enterCopyMode() {
        guard !isInCopyMode else { return }
        sendPrefixed("[")
    }

    /// Two-finger swipe: page through Screen's scrollback in copy mode.
    func scrollBack(pageUp: Bool) {
        if !isInCopyMode {
            guard pageUp else { return }
            sendPrefixed("[")
        }
        // Copy mode: Ctrl+B / Ctrl+F page back / forward.
        terminalView.sendRaw(Data([pageUp ? 0x02 : 0x06]))
    }

    func exitCopyMode() {
        guard isInCopyMode else { return }
        terminalView.send(key: .escape)
    }

    private func updateCopyModeTracking(for data: Data) {
        if data.count == 2, data.first == Self.prefix, data.last == UInt8(ascii: "[") {
            isInCopyMode = true
            return
        }
        guard isInCopyMode else { return }
        // Esc, q, Enter, space (marks) and Ctrl+C leave or finish copy mode
        // in Screen's default bindings.
        if data.contains(0x1B) && data.count == 1
            || data == Data([UInt8(ascii: "q")])
            || data == Data([0x0D])
            || data == Data([0x03]) {
            isInCopyMode = false
        }
    }

    // MARK: Background

    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginBackgroundTask() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        })
    }

    /// Keeps the SSH socket alive for the time iOS allows (about 30 seconds)
    /// so a quick app switch does not drop the attachment mid-command.
    private func beginBackgroundTask() {
        guard isLive, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Remux Screen \(session.id)"
        ) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Out of time: drop the channel cleanly. Screen detaches the
                // session on hang-up, so nothing is lost on the server.
                self.close()
                self.state = .ended("Disconnected while in the background")
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

private final class FinishBox: @unchecked Sendable {
    private let lock = NIOLock()
    private var exitStatus: Int?
    private var error: Error?

    func set(exitStatus: Int?, error: Error?) {
        lock.withLock {
            self.exitStatus = exitStatus
            self.error = error
        }
    }

    var value: (exitStatus: Int?, error: Error?) {
        lock.withLock { (exitStatus, error) }
    }
}
