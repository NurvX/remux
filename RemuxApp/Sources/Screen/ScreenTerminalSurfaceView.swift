import GhosttyKit
import UIKit

/// A raw terminal for an attached GNU Screen session.
///
/// Unlike tmux, Screen has no control mode, so Remux renders it the classic
/// way: bytes from an SSH PTY are fed into a Ghostty *producer* (a VT parser
/// and terminal without a subprocess) and a renderer-only Ghostty surface
/// draws that terminal with Metal. Keyboard and accessory-bar input is
/// encoded by the surface and leaves through `write_cb` to `onWrite`.
///
/// Ghostty producers have a fixed grid, so when the view's size or the font
/// size changes the producer and surface are rebuilt at the new grid and
/// `onGridChange` fires; the owner then sends an SSH window-change and Screen
/// repaints the whole display.
@MainActor
final class ScreenTerminalSurfaceView: UIView, UIKeyInput {
    struct Grid: Equatable, Sendable {
        let columns: Int
        let rows: Int
        let pixelWidth: Int
        let pixelHeight: Int
    }

    enum Key {
        case escape, tab, enter, backspace
        case arrowUp, arrowDown, arrowLeft, arrowRight
        case home, end, pageUp, pageDown

        fileprivate var ghosttyKeyCode: GhosttySurfaceKeyEvent.KeyCode {
            switch self {
            case .escape: .escape
            case .tab: .tab
            case .enter: .enter
            case .backspace: .backspace
            case .arrowUp: .arrowUp
            case .arrowDown: .arrowDown
            case .arrowLeft: .arrowLeft
            case .arrowRight: .arrowRight
            case .home: .home
            case .end: .end
            case .pageUp: .pageUp
            case .pageDown: .pageDown
            }
        }
    }

    /// Bytes to send to the remote PTY. Return false to reject them.
    var onWrite: ((Data) -> Bool)?
    /// Called after every rebuild of the native terminal. A rebuilt terminal
    /// starts blank, so the owner must make Screen repaint even when the grid
    /// is unchanged (for example after a font change that keeps the size).
    var onGridChange: ((Grid) -> Void)?
    /// Called after a one-shot Ctrl/Alt latch is consumed so the accessory
    /// bar can clear its highlight.
    var onModifiersConsumed: (() -> Void)?
    var onRendererFailure: ((String) -> Void)?
    /// Two-finger tap.
    var onTwoFingerTap: (() -> Void)?
    /// Two-finger swipe.
    var onTwoFingerSwipe: ((UISwipeGestureRecognizer.Direction) -> Void)?

    var ctrlLatched = false
    var altLatched = false

    private(set) var grid: Grid?
    private(set) var fontSize: Float32

    private let settings: TerminalSettings
    private var runtime: GhosttyKitRuntime?
    private let writeBox = WriteBox()
    private var native: NativeTerminal?
    private var lastLayoutSize: CGSize = .zero
    private var pinchStartFontSize: Float32?

    private static let minimumFontSize: Float32 = TerminalSettings.minimumFontSize
    private static let maximumFontSize: Float32 = 32

    init(settings: TerminalSettings) {
        self.settings = settings
        fontSize = GhosttyTerminalAppearancePolicy.currentDeviceFontSize(settings: settings) ?? 13
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        backgroundColor = settings.theme.terminalBackgroundUIColor
        clipsToBounds = true
        writeBox.view = self

        do {
            runtime = try GhosttyKitRuntime(terminalSettings: settings)
        } catch {
            GhosttyRuntimeTrace.diagnostics("screen.runtime failed error=\(String(describing: error))")
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoFingerTap)
        tap.require(toFail: twoFingerTap)

        for direction: UISwipeGestureRecognizer.Direction in [.up, .down, .left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleTwoFingerSwipe(_:)))
            swipe.numberOfTouchesRequired = 2
            swipe.direction = direction
            addGestureRecognizer(swipe)
            pinch.require(toFail: swipe)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Output (server -> terminal)

    /// Feeds raw PTY output into the terminal and schedules a frame.
    func feed(_ data: Data) {
        guard let native, !data.isEmpty else { return }
        native.feed(data)
    }

    // MARK: Input (terminal -> server)

    func send(text: String) {
        guard !text.isEmpty else { return }
        var bytes = Data()
        var consumedModifier = false
        for character in text {
            var chunk = Data(String(character == "\n" ? "\r" : character).utf8)
            if ctrlLatched, let control = Self.controlByte(for: character) {
                chunk = Data([control])
                ctrlLatched = false
                consumedModifier = true
            }
            if altLatched {
                chunk.insert(0x1B, at: 0)
                altLatched = false
                consumedModifier = true
            }
            bytes.append(chunk)
        }
        sendRaw(bytes)
        if consumedModifier { onModifiersConsumed?() }
    }

    func send(key: Key) {
        if key == .escape || key == .tab || key == .enter {
            // Plain bytes; also honours a latched Alt.
            let byte: UInt8 = key == .escape ? 0x1B : (key == .tab ? 0x09 : 0x0D)
            var data = Data([byte])
            if altLatched {
                data.insert(0x1B, at: 0)
                altLatched = false
                onModifiersConsumed?()
            }
            sendRaw(data)
            return
        }
        var mods: GhosttySurfaceKeyEvent.Mods = []
        if ctrlLatched { mods.insert(.ctrl) }
        if altLatched { mods.insert(.alt) }
        let event = GhosttySurfaceKeyEvent(keyCode: key.ghosttyKeyCode, mods: mods)
        if native?.control.sendKeyEvent(event) != true {
            // Fall back to normal-mode sequences if the surface is not up yet.
            sendRaw(Self.fallbackSequence(for: key))
        }
        if !mods.isEmpty {
            ctrlLatched = false
            altLatched = false
            onModifiersConsumed?()
        }
    }

    /// Sends bytes exactly as given (used for Screen's Ctrl+A prefix
    /// macros). Ghostty's raw input path would forward them unchanged
    /// anyway, so they go straight to the PTY.
    func sendRaw(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        _ = onWrite?(bytes)
    }

    /// Pastes text, bracketed when the remote application asked for it.
    func pasteText(_ text: String) {
        guard !text.isEmpty else { return }
        if native?.control.sendPaste(text) != true {
            sendRaw(Data(text.utf8))
        }
    }

    static func controlByte(for character: Character) -> UInt8? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case 0x61...0x7A: return ascii - 0x60          // a-z
        case 0x40...0x5F: return ascii - 0x40          // @ A-Z [ \ ] ^ _
        case 0x20: return 0x00                         // Ctrl+Space
        case 0x3F: return 0x7F                         // Ctrl+?
        default: return nil
        }
    }

    private static func fallbackSequence(for key: Key) -> Data {
        let sequence: String
        switch key {
        case .arrowUp: sequence = "\u{1B}[A"
        case .arrowDown: sequence = "\u{1B}[B"
        case .arrowRight: sequence = "\u{1B}[C"
        case .arrowLeft: sequence = "\u{1B}[D"
        case .home: sequence = "\u{1B}[H"
        case .end: sequence = "\u{1B}[F"
        case .pageUp: sequence = "\u{1B}[5~"
        case .pageDown: sequence = "\u{1B}[6~"
        case .backspace: sequence = "\u{7F}"
        case .escape: sequence = "\u{1B}"
        case .tab: sequence = "\t"
        case .enter: sequence = "\r"
        }
        return Data(sequence.utf8)
    }

    // MARK: UIKeyInput

    var hasText: Bool { true }

    func insertText(_ text: String) {
        send(text: text)
    }

    func deleteBackward() {
        send(key: .backspace)
    }

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default

    override var canBecomeFirstResponder: Bool { true }

    private var accessoryView: UIView?
    override var inputAccessoryView: UIView? {
        get { accessoryView }
        set { accessoryView = newValue }
    }

    // Hardware keyboard keys that UIKeyInput does not deliver as text.
    override var keyCommands: [UIKeyCommand]? {
        let pairs: [(String, Selector)] = [
            (UIKeyCommand.inputUpArrow, #selector(keyUp)),
            (UIKeyCommand.inputDownArrow, #selector(keyDown)),
            (UIKeyCommand.inputLeftArrow, #selector(keyLeft)),
            (UIKeyCommand.inputRightArrow, #selector(keyRight)),
            (UIKeyCommand.inputEscape, #selector(keyEscape)),
            (UIKeyCommand.inputPageUp, #selector(keyPageUp)),
            (UIKeyCommand.inputPageDown, #selector(keyPageDown)),
            (UIKeyCommand.inputHome, #selector(keyHome)),
            (UIKeyCommand.inputEnd, #selector(keyEnd)),
        ]
        var commands = pairs.map { input, action in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: action)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        // Ctrl+letter from a hardware keyboard.
        for scalar in UnicodeScalar("a").value...UnicodeScalar("z").value {
            let letter = String(UnicodeScalar(scalar)!)
            let command = UIKeyCommand(input: letter, modifierFlags: .control, action: #selector(keyControlLetter(_:)))
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        return commands
    }

    @objc private func keyUp() { send(key: .arrowUp) }
    @objc private func keyDown() { send(key: .arrowDown) }
    @objc private func keyLeft() { send(key: .arrowLeft) }
    @objc private func keyRight() { send(key: .arrowRight) }
    @objc private func keyEscape() { send(key: .escape) }
    @objc private func keyPageUp() { send(key: .pageUp) }
    @objc private func keyPageDown() { send(key: .pageDown) }
    @objc private func keyHome() { send(key: .home) }
    @objc private func keyEnd() { send(key: .end) }
    @objc private func keyControlLetter(_ command: UIKeyCommand) {
        guard let input = command.input?.first, let byte = Self.controlByte(for: input) else { return }
        sendRaw(Data([byte]))
    }

    override func paste(_ sender: Any?) {
        if let text = UIPasteboard.general.string { pasteText(text) }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(paste(_:)) ? UIPasteboard.general.hasStrings : super.canPerformAction(action, withSender: sender)
    }

    // MARK: Gestures

    @objc private func handleTap() {
        if isFirstResponder {
            resignFirstResponder()
        } else {
            becomeFirstResponder()
        }
    }

    @objc private func handleTwoFingerTap() {
        onTwoFingerTap?()
    }

    @objc private func handleTwoFingerSwipe(_ gesture: UISwipeGestureRecognizer) {
        onTwoFingerSwipe?(gesture.direction)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartFontSize = fontSize
        case .changed, .ended:
            guard let start = pinchStartFontSize else { return }
            let proposed = (start * Float32(gesture.scale)).rounded()
            let clamped = min(max(proposed, Self.minimumFontSize), Self.maximumFontSize)
            if clamped != fontSize {
                fontSize = clamped
                rebuildIfNeeded(force: true)
            }
            if gesture.state == .ended { pinchStartFontSize = nil }
        default:
            pinchStartFontSize = nil
        }
    }

    func setFontSize(_ size: Float32) {
        let clamped = min(max(size, Self.minimumFontSize), Self.maximumFontSize)
        guard clamped != fontSize else { return }
        fontSize = clamped
        rebuildIfNeeded(force: true)
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        native?.view.frame = bounds
        guard bounds.size != lastLayoutSize else { return }
        lastLayoutSize = bounds.size
        rebuildIfNeeded(force: false)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            setNeedsLayout()
            native?.setVisible(true)
        } else {
            native?.setVisible(false)
        }
    }

    private var effectiveScale: CGFloat {
        max(window?.screen.scale ?? traitCollection.displayScale, 1)
    }

    private func rebuildIfNeeded(force: Bool) {
        guard let runtime, bounds.width > 1, bounds.height > 1 else { return }
        let metrics = GhosttySurfaceDisplayMetrics(size: bounds.size, scale: effectiveScale)
        var config = runtime.makeTmuxBaseSurfaceConfig()
        config.scale_factor = metrics.contentScale
        config.width_px = metrics.pixelWidth
        config.height_px = metrics.pixelHeight
        config.font_size = fontSize
        var measured = ghostty_surface_size_s()
        guard ghostty_terminal_surface_measure(runtime.appHandle, &config, &measured)
                == GHOSTTY_TERMINAL_SURFACE_RESULT_OK,
              measured.columns > 0, measured.rows > 0
        else { return }

        let newGrid = Grid(
            columns: Int(measured.columns),
            rows: Int(measured.rows),
            pixelWidth: Int(metrics.pixelWidth),
            pixelHeight: Int(metrics.pixelHeight)
        )

        if !force, let native, newGrid.columns == grid?.columns, newGrid.rows == grid?.rows {
            native.setPixelSize(width: metrics.pixelWidth, height: metrics.pixelHeight)
            grid = newGrid
            return
        }

        native?.view.removeFromSuperview()
        native = nil
        let view = GhosttyKitSurfaceView(frame: bounds)
        view.contentScaleFactor = metrics.contentScale
        view.applyTerminalTheme(settings.theme)
        view.isUserInteractionEnabled = false
        insertSubview(view, at: 0)
        do {
            native = try NativeTerminal(
                runtime: runtime,
                view: view,
                writeBox: writeBox,
                columns: measured.columns,
                rows: measured.rows,
                metrics: metrics,
                fontSize: fontSize,
                visible: window != nil,
                focused: true
            )
            view.alignGhosttyRendererSublayers()
        } catch {
            view.removeFromSuperview()
            onRendererFailure?("The terminal renderer could not start (\(error)).")
            return
        }
        grid = newGrid
        onGridChange?(newGrid)
    }

    fileprivate func deliverWrite(_ data: Data) -> Bool {
        onWrite?(data) ?? false
    }

    fileprivate func rendererBecameUnhealthy() {
        onRendererFailure?("The terminal renderer stopped responding.")
    }
}

// MARK: - Native ownership

private final class WriteBox: @unchecked Sendable {
    /// Main-thread only; see ghostty.h's write_cb contract.
    weak var view: ScreenTerminalSurfaceView?

    static let writeCallback: ghostty_terminal_surface_write_cb = { userdata, pointer, count in
        guard let userdata else { return false }
        guard count > 0 else { return true }
        guard let pointer else { return false }
        let box = Unmanaged<WriteBox>.fromOpaque(userdata).takeUnretainedValue()
        let data = Data(bytes: pointer, count: count)
        return MainActor.assumeIsolated {
            box.view?.deliverWrite(data) ?? false
        }
    }

    static let healthCallback: ghostty_terminal_surface_renderer_health_cb = { userdata, health in
        guard health == GHOSTTY_RENDERER_HEALTH_UNHEALTHY, let userdata else { return }
        let box = Unmanaged<WriteBox>.fromOpaque(userdata).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { box.view?.rendererBecameUnhealthy() }
        }
    }
}

/// Owns one producer, its retained terminal and one renderer surface. All
/// three are freed together; Ghostty allows freeing them in any order.
@MainActor
private final class NativeTerminal {
    enum CreationError: Error {
        case producer(ghostty_terminal_producer_result_e)
        case terminal(ghostty_terminal_producer_result_e)
        case surface(ghostty_terminal_surface_result_e)
    }

    let control: GhosttyKitControlSurface
    let view: GhosttyKitSurfaceView

    private let producer: ghostty_terminal_producer_t
    private let terminal: ghostty_terminal_t
    private let surface: ghostty_terminal_surface_t
    // Retained so the userdata pointer handed to Ghostty stays valid until
    // ghostty_terminal_surface_free returns.
    private let writeBox: WriteBox

    init(
        runtime: GhosttyKitRuntime,
        view: GhosttyKitSurfaceView,
        writeBox: WriteBox,
        columns: UInt16,
        rows: UInt16,
        metrics: GhosttySurfaceDisplayMetrics,
        fontSize: Float32,
        visible: Bool,
        focused: Bool
    ) throws {
        var producerConfig = ghostty_terminal_producer_config_new()
        producerConfig.columns = columns
        producerConfig.rows = rows
        // Screen keeps its own scrollback (copy mode); a local buffer would
        // only hold stale repaints.
        producerConfig.max_scrollback = 0

        var createdProducer: ghostty_terminal_producer_t?
        let producerResult = ghostty_terminal_producer_new(&producerConfig, &createdProducer)
        guard producerResult == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK, let createdProducer else {
            throw CreationError.producer(producerResult)
        }

        var createdTerminal: ghostty_terminal_t?
        let terminalResult = ghostty_terminal_producer_retain_terminal(createdProducer, &createdTerminal)
        guard terminalResult == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK, let createdTerminal else {
            ghostty_terminal_producer_free(createdProducer)
            throw CreationError.terminal(terminalResult)
        }

        var config = runtime.makeTmuxBaseSurfaceConfig()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
            uiview: Unmanaged.passUnretained(view).toOpaque()
        ))
        config.userdata = Unmanaged.passUnretained(writeBox).toOpaque()
        config.write_cb = WriteBox.writeCallback
        config.renderer_health_cb = WriteBox.healthCallback
        config.scale_factor = metrics.contentScale
        config.width_px = metrics.pixelWidth
        config.height_px = metrics.pixelHeight
        config.font_size = fontSize
        config.visible = visible
        config.focused = focused

        var createdSurface: ghostty_terminal_surface_t?
        let surfaceResult = ghostty_terminal_surface_new(
            runtime.appHandle,
            createdTerminal,
            &config,
            &createdSurface
        )
        guard surfaceResult == GHOSTTY_TERMINAL_SURFACE_RESULT_OK, let createdSurface else {
            ghostty_terminal_release(createdTerminal)
            ghostty_terminal_producer_free(createdProducer)
            throw CreationError.surface(surfaceResult)
        }

        producer = createdProducer
        terminal = createdTerminal
        surface = createdSurface
        self.writeBox = writeBox
        self.view = view
        control = GhosttyKitControlSurface(
            surface: createdSurface,
            scaleFactor: metrics.contentScale,
            onFailure: { failure in
                GhosttyRuntimeTrace.diagnostics("screen.surface failure=\(failure)")
            }
        )
    }

    deinit {
        MainActor.assumeIsolated {
            control.invalidate()
            ghostty_terminal_surface_free(surface)
            ghostty_terminal_release(terminal)
            ghostty_terminal_producer_free(producer)
            _ = writeBox
        }
    }

    func feed(_ data: Data) {
        let result = data.withUnsafeBytes { bytes in
            ghostty_terminal_producer_feed(
                producer,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count
            )
        }
        guard result == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK else {
            GhosttyRuntimeTrace.diagnostics("screen.feed failed result=\(result.rawValue)")
            return
        }
        // Feeding does not notify renderers (ghostty.h); a failed wake is
        // retried by the next feed.
        _ = ghostty_terminal_surface_terminal_changed(surface)
    }

    func setPixelSize(width: UInt32, height: UInt32) {
        _ = ghostty_terminal_surface_set_size(surface, max(width, 1), max(height, 1))
    }

    func setVisible(_ visible: Bool) {
        _ = ghostty_terminal_surface_set_visible(surface, visible)
    }
}
