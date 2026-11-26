# Overview

Remux is an iOS app for remote tmux sessions.

It keeps the app model close to tmux instead of treating tmux as one
full-screen terminal attachment:

- `Server`: a saved SSH destination
- `Workspace`: a tmux session on a saved server
- `Window`: a tmux window
- `Pane`: a tmux pane rendered by Ghostty

A saved server can have multiple workspaces. A workspace can have windows and
panes. That maps cleanly to tmux, while still leaving room for iOS navigation
and controls.

## GNU Screen

Servers that use GNU Screen instead of tmux get a separate dashboard
(server detail, "Screen Sessions"). Screen has no control mode, so it is
handled differently from tmux:

- Management (`screen -ls`, `-dmS`, `-X quit`, `-X stuff`, `-wipe`) runs as
  ordinary SSH exec commands.
- Attaching runs `screen -U -d -r <pid>.<name>` on an SSH channel with a
  PTY, and Ghostty renders that byte stream as one full-screen terminal.

## Current Scope

The app can save SSH connection details, store terminal settings, and open
tmux control-mode sessions over SSH. Ghostty owns tmux command generation,
control-mode parsing, reconciliation, pane projection, terminal rendering, and
input.

Mosh is planned, but it is not implemented yet.

## Non-Goals

- A Swift-side terminal renderer
- A raw `tmux attach-session` terminal UI as the product surface
- An SSH-backed placeholder for mosh
