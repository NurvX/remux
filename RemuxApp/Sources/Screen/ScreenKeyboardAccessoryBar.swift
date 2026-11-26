import Combine
import UIKit

/// The row of keys shown above the iOS keyboard while attached to a Screen
/// session. It covers what a touchscreen keyboard lacks: Screen's Ctrl+A
/// prefix and common prefix commands, Esc/Tab, one-shot Ctrl/Alt
/// modifiers and arrow keys.
@MainActor
final class ScreenKeyboardAccessoryBar: UIInputView {
    enum Item: CaseIterable {
        case prefix, detach, ctrl, alt, escape, tab
        case left, down, up, right
        case copyMode, windowList, newWindow, previousWindow, nextWindow
        case paste, hideKeyboard

        var title: String? {
            switch self {
            case .prefix: return "^A"
            case .detach: return "Detach"
            case .ctrl: return "Ctrl"
            case .alt: return "Alt"
            case .escape: return "Esc"
            case .tab: return "Tab"
            default: return nil
            }
        }

        var systemImage: String? {
            switch self {
            case .left: return "arrow.left"
            case .down: return "arrow.down"
            case .up: return "arrow.up"
            case .right: return "arrow.right"
            case .copyMode: return "scroll"
            case .windowList: return "list.bullet"
            case .newWindow: return "plus.rectangle"
            case .previousWindow: return "chevron.left.2"
            case .nextWindow: return "chevron.right.2"
            case .paste: return "doc.on.clipboard"
            case .hideKeyboard: return "keyboard.chevron.compact.down"
            default: return nil
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .prefix: return "Screen prefix, Control A"
            case .detach: return "Detach session"
            case .ctrl: return "Control"
            case .alt: return "Alt"
            case .escape: return "Escape"
            case .tab: return "Tab"
            case .left: return "Left arrow"
            case .down: return "Down arrow"
            case .up: return "Up arrow"
            case .right: return "Right arrow"
            case .copyMode: return "Scrollback, copy mode"
            case .windowList: return "Window list"
            case .newWindow: return "New window"
            case .previousWindow: return "Previous window"
            case .nextWindow: return "Next window"
            case .paste: return "Paste"
            case .hideKeyboard: return "Hide keyboard"
            }
        }

        /// Keys that repeat while held.
        var repeats: Bool {
            switch self {
            case .left, .down, .up, .right: return true
            default: return false
            }
        }
    }

    private weak var model: ScreenTerminalModel?
    private var buttons: [Item: UIButton] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var repeatTimer: Timer?

    init(model: ScreenTerminalModel) {
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false
        buildLayout()

        model.$ctrlLatched
            .combineLatest(model.$altLatched)
            .receive(on: RunLoop.main)
            .sink { [weak self] ctrl, alt in
                self?.setHighlighted(.ctrl, ctrl)
                self?.setHighlighted(.alt, alt)
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 48)
    }

    private func buildLayout() {
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 36),
        ])

        let groups: [[Item]] = [
            [.prefix, .detach],
            [.ctrl, .alt, .escape, .tab],
            [.left, .down, .up, .right],
            [.copyMode, .windowList, .previousWindow, .nextWindow, .newWindow],
            [.paste, .hideKeyboard],
        ]
        for (index, group) in groups.enumerated() {
            if index > 0 {
                let separator = UIView()
                separator.backgroundColor = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
                separator.heightAnchor.constraint(equalToConstant: 22).isActive = true
                stack.addArrangedSubview(separator)
            }
            for item in group {
                let button = makeButton(for: item)
                buttons[item] = button
                stack.addArrangedSubview(button)
            }
        }
    }

    private func makeButton(for item: Item) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        if let title = item.title {
            var attributes = AttributeContainer()
            attributes.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
            configuration.attributedTitle = AttributedString(title, attributes: attributes)
        }
        if let image = item.systemImage {
            configuration.image = UIImage(
                systemName: image,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            )
        }
        if item == .prefix || item == .detach {
            configuration.baseForegroundColor = .tintColor
        }
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = item.accessibilityLabel
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true

        if item.repeats {
            button.addAction(UIAction { [weak self] _ in self?.beginRepeat(item) }, for: .touchDown)
            button.addAction(UIAction { [weak self] _ in self?.endRepeat() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        } else {
            button.addAction(UIAction { [weak self] _ in self?.perform(item) }, for: .touchUpInside)
        }
        return button
    }

    private func setHighlighted(_ item: Item, _ highlighted: Bool) {
        guard let button = buttons[item] else { return }
        var configuration = highlighted ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        configuration.cornerStyle = .medium
        configuration.contentInsets = button.configuration?.contentInsets ?? .zero
        configuration.attributedTitle = button.configuration?.attributedTitle
        button.configuration = configuration
    }

    private func beginRepeat(_ item: Item) {
        perform(item)
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.perform(item) }
                }
            }
        }
    }

    private func endRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func perform(_ item: Item) {
        guard let model else { return }
        UIDevice.current.playInputClick()
        let terminal = model.terminalView
        switch item {
        case .prefix: model.sendPrefix()
        case .detach: model.detach()
        case .ctrl: model.ctrlLatched.toggle()
        case .alt: model.altLatched.toggle()
        case .escape: terminal.send(key: .escape)
        case .tab: terminal.send(key: .tab)
        case .left: terminal.send(key: .arrowLeft)
        case .down: terminal.send(key: .arrowDown)
        case .up: terminal.send(key: .arrowUp)
        case .right: terminal.send(key: .arrowRight)
        case .copyMode: model.enterCopyMode()
        case .windowList: model.sendPrefixed("\"")
        case .newWindow: model.sendPrefixed("c")
        case .previousWindow: model.sendPrefixed("p")
        case .nextWindow: model.sendPrefixed("n")
        case .paste:
            if let text = UIPasteboard.general.string { terminal.pasteText(text) }
        case .hideKeyboard: terminal.resignFirstResponder()
        }
    }
}

extension ScreenKeyboardAccessoryBar: UIInputViewAudioFeedback {
    nonisolated var enableInputClicksWhenVisible: Bool { true }
}
