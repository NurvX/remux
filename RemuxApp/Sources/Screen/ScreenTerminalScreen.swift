import SwiftUI
import UIKit

/// Full-screen terminal attached to one GNU Screen session.
struct ScreenTerminalScreen: View {
    @ObservedObject var model: ScreenTerminalModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                ScreenTerminalRepresentable(model: model)
                    .ignoresSafeArea(.container, edges: .bottom)
                statusOverlay
            }
        }
        .background(Color(model.terminalView.backgroundColor ?? .black))
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .onChange(of: model.state) { _, state in
            // A clean detach returns to the dashboard.
            if case .ended = state, model.didRequestDetach {
                dismiss()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                model.close()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Close")

            VStack(alignment: .leading, spacing: 1) {
                Text(model.title)
                    .font(.subheadline.monospaced().weight(.semibold))
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.isInCopyMode {
                Button("Exit Scrollback") { model.exitCopyMode() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
            }

            Button {
                model.detach()
            } label: {
                Label("Detach", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .disabled(!model.isLive)
            .accessibilityHint("Detaches with Control A, D and returns to the session list")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var statusText: String {
        switch model.state {
        case .waitingForLayout, .connecting: return "Connecting\u{2026}"
        case .connected:
            let server = model.service.server.displayName
            if let grid = model.terminalView.grid {
                return "\(server) \u{00B7} \(grid.columns)\u{00D7}\(grid.rows)"
            }
            return server
        case .ended(let reason): return reason
        case .failed: return "Disconnected"
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch model.state {
        case .waitingForLayout, .connecting:
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        case .connected:
            EmptyView()
        case .ended(let reason):
            overlayCard(title: reason, message: "The session is still running on the server.")
        case .failed(let failure):
            overlayCard(title: "Connection Lost", message: failure.message)
        }
    }

    private func overlayCard(title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Close") {
                    model.close()
                    dismiss()
                }
                .buttonStyle(.bordered)
                Button("Reattach") { model.reconnect() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
    }
}

/// Hosts the UIKit terminal view and installs the Screen key bar as its
/// keyboard accessory.
private struct ScreenTerminalRepresentable: UIViewRepresentable {
    let model: ScreenTerminalModel

    func makeUIView(context: Context) -> ScreenTerminalSurfaceView {
        let view = model.terminalView
        view.inputAccessoryView = ScreenKeyboardAccessoryBar(model: model)
        DispatchQueue.main.async {
            view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: ScreenTerminalSurfaceView, context: Context) {}

    static func dismantleUIView(_ uiView: ScreenTerminalSurfaceView, coordinator: ()) {
        uiView.resignFirstResponder()
    }
}
