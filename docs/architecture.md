# Architecture

Remux keeps the iOS app shell separate from the tmux transport and the
Ghostty terminal runtime.

SwiftUI owns presentation and user intent. The transport layer moves bytes.
Ghostty renders terminal surfaces. Persistence is hidden behind repository and
store interfaces.

## Main Types

- `RemuxRootModel`: top-level app coordinator for the library, setup flow,
  terminal sessions, and settings.
- `ConnectionProfileRepository`: persisted saved servers and tmux workspaces.
- `SSHCredentialStore`: saved SSH credentials, backed by Keychain in live builds.
- `TrustedHostStore`: SSH host identity persistence and validation.
- `TerminalSettingsRepository`: persisted terminal appearance settings.
- `TmuxControlTransport`: byte-stream transport boundary for a bare `tmux -C`
  control-mode exec channel.
- `TmuxSessionController`: wrapper around Ghostty's tmux session API. Ghostty
  owns command generation, control-mode parsing, reconciliation, and pane
  projection.
- `TmuxScreenModel`: terminal screen coordinator that connects a target,
  transport, and Ghostty tmux session runtime.
- `GhosttyRuntimeSurfaceRegistry`: tracks runtime-created Ghostty surfaces and
  focused pane state.

## Runtime Flow

```text
Saved server + workspace
-> TmuxConnectionTarget
-> TmuxScreenModel
-> TmuxSessionController
-> TmuxControlTransport
-> SSH exec channel running tmux -C
-> Ghostty tmux session callbacks
-> Ghostty pane projections
-> SwiftUI/UIKit shell
```

Transport code does not import UI concepts. Ghostty surface views do not read
repositories directly.

## GNU Screen

GNU Screen support lives in `RemuxApp/Sources/Screen` and shares the SSH
connection pool, credentials, and host-key trust with tmux.

- `ScreenCommandBuilder`: builds `exec /bin/sh -c` commands with octal-encoded
  arguments, the same injection-safe shape as the tmux builders. It also
  escapes Screen's own `stuff` metacharacters (`^`, `\`, `$`).
- `ScreenSessionListParser`: parses `screen -ls`, where a non-zero exit status
  is normal.
- `ScreenSessionService`: list, create, kill, stuff, wipe, and attach for one
  saved server, over `RemuxAppDependencies`.
- `ScreenTerminalSurfaceView`: a Ghostty terminal *producer* fed with raw PTY
  bytes, drawn by a renderer-only Ghostty surface. Input leaves through the
  surface's `write_cb`. Producers have a fixed grid, so a size or font change
  rebuilds the producer and surface. The model then sends an SSH
  `window-change` (or Ctrl+A l when the grid is unchanged) so Screen repaints.
- `ScreenTerminalModel`: owns the PTY exec channel
  (`RemuxSSHExecSession.openInteractive`), keeps inbound and outbound bytes in
  order, and requests a background task while attached.

```text
Saved server
-> ScreenSessionService
-> SSH exec channel + PTY running screen -r
-> Ghostty terminal producer (VT parser)
-> Ghostty renderer surface
```

## Persistence

Live builds store app data under the app's application-support root:

- saved servers in JSON
- saved workspaces in JSON
- terminal settings in JSON
- SSH credentials (password or private key) in Keychain
- trusted host identities in the trusted-host store

UI tests use in-memory repositories and deterministic transports when possible.

## Transport

SSH is the implemented transport. Unsupported transports fail explicitly
instead of silently falling back to SSH.

Authentication is per-identity and supports password, private key, or
Tailscale SSH. Tailscale SSH offers SSH's `none` user-auth method and stores no
credential in Keychain. This path currently supports Tailscale SSH rules with
the `accept` action and browser reauthentication for `check` rules. For
`check`, Remux validates the Tailscale verification URL from the SSH banner,
offers to open it in the user's browser, and keeps authentication pending while
the user completes verification. Background prewarming is disabled for this
authentication method so it cannot produce an unsolicited browser prompt.

WireGuard only supplies a network path. Ordinary SSH servers reached through
WireGuard still require whatever password or key authentication they normally
use.

The transport boundary is small: prepare/start, write outbound bytes, stream
inbound bytes, report liveness when available, and close. It deliberately does
not allocate a PTY or inject tmux commands. Client size, tmux command
semantics, control-mode parsing, reconciliation, and pane materialization stay
inside Ghostty's tmux session API; terminal rendering stays out of generic app
views.
