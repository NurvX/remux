import Foundation

/// Builds the SSH exec commands Remux runs for GNU Screen.
///
/// Every command has the same shape as the tmux builders:
///
///     exec /bin/sh -c '<fixed script>' remux <octal args...>
///
/// The login shell only parses that wrapper, so fish and csh users are
/// supported. All user-controlled values (executable path, session names,
/// stuffed text) travel as octal-escaped arguments that the fixed script
/// decodes with `printf %b`, which keeps them out of shell syntax entirely.
enum ScreenCommandBuilder {
    static let screenNotFoundMarker = "remux: screen executable not found"
    static let screenNotExecutableMarker = "remux: screen executable cannot be executed"
    static let defaultExecutable = "screen"
    static let terminalType = "xterm-256color"

    enum Action: Equatable, Sendable {
        case list
        case create(name: ScreenSessionName, initialInput: ScreenStuffText?)
        case kill(selector: ScreenSessionSelector)
        case stuff(selector: ScreenSessionSelector, text: ScreenStuffText)
        case wipe
        /// Interactive attach. Must run on a channel with a PTY.
        case attach(selector: ScreenSessionSelector)
    }

    private static let fallbackRemotePath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func command(_ action: Action, screenExecutable: String = defaultExecutable) -> String {
        var arguments = [octalEncodedArgument(screenExecutable)]
        switch action {
        case .list:
            arguments.append("list")
        case .create(let name, let initialInput):
            arguments.append("create")
            arguments.append(octalEncodedArgument(name.rawValue))
            if let initialInput {
                arguments.append(octalEncodedArgument(initialInput.encoded))
            }
        case .kill(let selector):
            arguments.append("kill")
            arguments.append(octalEncodedArgument(selector.rawValue))
        case .stuff(let selector, let text):
            arguments.append("stuff")
            arguments.append(octalEncodedArgument(selector.rawValue))
            arguments.append(octalEncodedArgument(text.encoded))
        case .wipe:
            arguments.append("wipe")
        case .attach(let selector):
            arguments.append("attach")
            arguments.append(octalEncodedArgument(selector.rawValue))
        }
        return (["exec /bin/sh -c '\(script)' remux"] + arguments).joined(separator: " ")
    }

    /// `$1` executable, `$2` action, `$3`/`$4` action arguments.
    ///
    /// The script contains no single quotes so it can be wrapped in one pair.
    private static let script = [
        #"PATH="${PATH:+$PATH:}\#(fallbackRemotePath)""#,
        "export PATH",
        #"screen=$(printf %b "$1")"#,
        #"resolved=$(command -v "$screen" 2> /dev/null)"#,
        #"if [ ! -x "$resolved" ]; then if [ -e "$screen" ]; then echo "\#(screenNotExecutableMarker): $screen" >&2; exit 126; fi; echo "\#(screenNotFoundMarker): $screen" >&2; exit 127; fi"#,
        #"case "$2" in"#,
        #"list) LC_ALL=C; export LC_ALL; exec "$resolved" -ls;;"#,
        #"wipe) LC_ALL=C; export LC_ALL; exec "$resolved" -wipe;;"#,
        #"create) name=$(printf %b "$3"); "$resolved" -dmS "$name" || exit $?; if [ -n "$4" ]; then text=$(printf %b "$4"); exec "$resolved" -S "$name" -X stuff "$text"; fi; exit 0;;"#,
        #"kill) target=$(printf %b "$3"); exec "$resolved" -S "$target" -X quit;;"#,
        #"stuff) target=$(printf %b "$3"); text=$(printf %b "$4"); exec "$resolved" -S "$target" -X stuff "$text";;"#,
        #"attach) target=$(printf %b "$3"); TERM=\#(terminalType); export TERM; exec "$resolved" -U -d -r "$target";;"#,
        #"*) echo "remux: unknown screen action: $2" >&2; exit 2;;"#,
        "esac",
    ].joined(separator: "; ")
        // `;;` must not be followed by `;`, and `case ... in;` is invalid.
        .replacingOccurrences(of: ";;; ", with: ";; ")
        .replacingOccurrences(of: " in; ", with: " in ")

    static func octalEncodedArgument(_ value: String) -> String {
        let bytes = value.utf8.map { byte in
            let digits = String(byte, radix: 8)
            return "\\0" + String(repeating: "0", count: 3 - digits.count) + digits
        }
        return "'\(bytes.joined())'"
    }
}

/// A name accepted for new sessions.
///
/// Screen joins `<pid>.<name>` with a dot and treats whitespace and slashes
/// specially, so new names are restricted to letters, digits, `-` and `_`.
struct ScreenSessionName: Equatable, Hashable, Sendable {
    static let maximumLength = 64

    let rawValue: String

    /// Returns nil when nothing usable is left after sanitizing.
    init?(sanitizing input: String) {
        var output = ""
        var lastWasSeparator = false
        for scalar in input.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            if scalar.isASCII,
               CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                output.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if scalar == "-" || scalar == " " || scalar == "." || scalar == "/" {
                if !lastWasSeparator, !output.isEmpty {
                    output.append("-")
                    lastWasSeparator = true
                }
            }
        }
        while output.hasSuffix("-") { output.removeLast() }
        if output.count > Self.maximumLength {
            output = String(output.prefix(Self.maximumLength))
            while output.hasSuffix("-") { output.removeLast() }
        }
        guard !output.isEmpty else { return nil }
        rawValue = output
    }
}

/// The `<pid>.<name>` selector of an existing session.
struct ScreenSessionSelector: Equatable, Hashable, Sendable {
    let rawValue: String

    init(_ session: ScreenSession) {
        rawValue = session.id
    }

    /// Accepts only `<digits>.<non-empty name without whitespace>`.
    init?(rawValue: String) {
        guard let dot = rawValue.firstIndex(of: "."),
              !rawValue[..<dot].isEmpty,
              rawValue[..<dot].allSatisfy(\.isASCII),
              rawValue[..<dot].allSatisfy(\.isNumber),
              rawValue.index(after: dot) < rawValue.endIndex,
              !rawValue.contains(where: \.isWhitespace)
        else { return nil }
        self.rawValue = rawValue
    }
}

/// Text for Screen's `stuff` command, which injects input into a window as if
/// typed.
///
/// `stuff` interprets `^X` as a control character, `\` as an escape and
/// `$VAR` as an environment variable, so literal text has all three escaped.
/// Verified against GNU Screen 4.09.
struct ScreenStuffText: Equatable, Hashable, Sendable {
    let encoded: String

    private init(encoded: String) {
        self.encoded = encoded
    }

    /// Literal text, optionally followed by Return.
    static func literal(_ text: String, pressReturn: Bool = true) -> ScreenStuffText {
        var encoded = ""
        for character in text {
            switch character {
            case "\\": encoded += "\\\\"
            case "^": encoded += "\\^"
            // Screen expands $VAR and ${VAR} in command arguments.
            case "$": encoded += "\\$"
            case "\r\n", "\n", "\r": encoded += "^M"
            default: encoded.append(character)
            }
        }
        if pressReturn { encoded += "^M" }
        return ScreenStuffText(encoded: encoded)
    }

    /// A single control character, e.g. `control("C")` for Ctrl+C.
    static func control(_ letter: Character) -> ScreenStuffText? {
        guard let upper = letter.uppercased().first,
              letter.uppercased().count == 1,
              let ascii = upper.asciiValue,
              (0x40...0x5F).contains(ascii) // @ A-Z [ \ ] ^ _
        else { return nil }
        let escaped = upper == "\\" ? "\\\\" : (upper == "^" ? "\\^" : String(upper))
        return ScreenStuffText(encoded: "^" + escaped)
    }
}
