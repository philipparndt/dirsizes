import AppKit
import SwiftUI

/// Toolbar popover with the command that connects Claude Code to this app.
struct MCPSetupView: View {
    @Environment(DirSizesMCP.self) private var mcp
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Use with Claude", systemImage: "sparkles")
                .font(.headline)

            Text("Run this in a terminal to let Claude Code scan, explore and fill the collector. "
                 + "It can't delete anything: you review the collector and decide.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 8) {
                Text(mcp.setupCommand)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(mcp.setupCommand, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
                .controlSize(.large)
            }

            Group {
                if let port = mcp.port {
                    Label("Server running on 127.0.0.1:\(String(port))", systemImage: "circle.fill")
                        .foregroundStyle(.green)
                } else if let error = mcp.startError {
                    Label("Server not running: \(error)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label("Starting server…", systemImage: "circle.dotted")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .labelStyle(StatusLabelStyle())

            Text("Other MCP clients: add a stdio server that runs the same program with the argument mcp.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 440)
    }
}

/// Small status dot in front of the text.
private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.imageScale(.small)
            configuration.title.foregroundStyle(.secondary)
        }
    }
}
