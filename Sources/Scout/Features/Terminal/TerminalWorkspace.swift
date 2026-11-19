#if !APPSTORE
import AppKit
import SwiftTerm
import SwiftUI

/// Hosts the session's terminal view (the same view each time the workspace appears).
struct TerminalHost: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let terminal = TerminalSession.shared.ensureView()
        terminal.removeFromSuperview()
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        nsView.subviews.forEach { $0.removeFromSuperview() }
    }
}

/// Terminal workspace: a real shell (SwiftTerm) sized to the open notch.
struct TerminalWorkspaceView: View {
    @ObservedObject private var session = TerminalSession.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .bottom) {
                if ScoutRuntime.isScripted {
                    TerminalMock()
                } else {
                    TerminalHost()
                }
                if let code = session.exitCode, !session.isRunning {
                    HStack(spacing: 10) {
                        Text(code == 0 ? "The shell ended." : "The shell ended (code \(code)).").font(.system(size: 12, weight: .medium))
                        Button("Restart") { session.restart() }.buttonStyle(NotchPillButtonStyle(prominent: true, compact: true))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.85)).overlay(Capsule().stroke(NotchInk.hairline)))
                    .padding(.bottom, 10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 10).padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .notchContent()
        .onAppear { session.workspaceAppeared() }
        .onDisappear { session.workspaceDisappeared() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
            Text(session.title.isEmpty ? (TerminalSession.shellPath as NSString).lastPathComponent : session.title)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(NotchInk.secondary).lineLimit(1)
            Spacer()
            if session.focused { Text("Typing: the notch stays open").font(.system(size: 10)).foregroundStyle(NotchInk.tertiary) }
            Button { session.restart() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(NotchIconButtonStyle(size: 20)).help("Restart the shell")
            Button { SettingsWindowController.shared.show(.terminal) } label: { Image(systemName: "gearshape") }.buttonStyle(NotchIconButtonStyle(size: 20)).help("Terminal settings")
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 6)
    }
}

/// What offscreen renders and scripted runs show instead of a live shell.
struct TerminalMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            line("~ % ", "ls Projects")
            Text(verbatim: "Scout   notes   site   tools").foregroundStyle(Color(white: 0.9))
            line("~ % ", "cd Projects/Scout && git status -sb")
            Text(verbatim: "## lane-c").foregroundStyle(Color.green.opacity(0.85))
            line("Scout % ", "swift build")
            Text(verbatim: "Build complete! (4.21s)").foregroundStyle(Color(white: 0.9))
            HStack(spacing: 0) {
                Text(verbatim: "Scout % ").foregroundStyle(Theme.accent)
                Rectangle().fill(Theme.accent).frame(width: 7, height: 14)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
    }

    private func line(_ prompt: String, _ command: String) -> some View {
        HStack(spacing: 0) {
            Text(prompt).foregroundStyle(Theme.accent)
            Text(command).foregroundStyle(.white)
        }
    }
}
#endif
