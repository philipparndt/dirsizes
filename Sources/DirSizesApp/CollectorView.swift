import DirScanner
import SwiftUI

/// Drop zone for items to delete, like DaisyDisk's collector. Accepts drags from the chart, the
/// list and Finder (for paths inside the scanned folder).
struct CollectorView: View {
    @Environment(ScanModel.self) private var model
    @State private var isTargeted = false
    @State private var pendingDeletion: ScanModel.DeletionMode?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Collector", systemImage: "tray.full")
                    .font(.headline)
                Spacer()
                if !model.collected.isEmpty {
                    Text(formatBytes(model.collectedBytes))
                        .font(.headline.monospacedDigit())
                        .contentTransition(.numericText())
                        .animation(.default, value: model.collectedBytes)
                }
            }

            if model.collected.isEmpty {
                Text("Drag files and folders here,\nor right-click › Add to Collector.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 64)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.collected, id: \.self) { node in
                            CollectedRow(node: node)
                        }
                    }
                }
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Clear") { model.clearCollector() }
                    Spacer()
                    if model.isDeleting {
                        ProgressView().controlSize(.small)
                    }
                    Menu {
                        Button("Delete Immediately…", role: .destructive) { pendingDeletion = .permanent }
                    } label: {
                        Text("Move to Trash")
                    } primaryAction: {
                        pendingDeletion = .trash
                    }
                    .fixedSize()
                    .disabled(model.isDeleting)
                }
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isTargeted ? Color.accentColor : .secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: model.collected.isEmpty ? [5, 4] : []))
                .background(RoundedRectangle(cornerRadius: 10).fill(isTargeted ? Color.accentColor.opacity(0.08) : .clear))
        }
        .padding(10)
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            model.collect(urls: urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .confirmationDialog(confirmationTitle, isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            if pendingDeletion == .permanent {
                Button("Delete Immediately", role: .destructive) { model.deleteCollected(mode: .permanent) }
            } else {
                Button("Move to Trash", role: .destructive) { model.deleteCollected(mode: .trash) }
            }
        } message: {
            Text(pendingDeletion == .permanent
                 ? "This permanently deletes them and cannot be undone."
                 : "You can restore them from the Trash. Space is freed when you empty the Trash.")
        }
    }

    private var confirmationTitle: String {
        let count = model.collected.count
        let items = count == 1 ? "1 item" : "\(count) items"
        let size = formatBytes(model.collectedBytes)
        return pendingDeletion == .permanent
            ? "Permanently delete \(items) (\(size))?"
            : "Move \(items) (\(size)) to the Trash?"
    }
}

private struct CollectedRow: View {
    @Environment(ScanModel.self) private var model
    let node: Int32

    var body: some View {
        if let tree = model.tree {
            let item = tree.nodes[Int(node)]
            HStack(spacing: 6) {
                Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                Text(tree.name(of: node))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(tree.path(of: node))
                Spacer()
                Text(formatBytes(item.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button {
                    model.uncollect(node)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove from Collector")
            }
            .font(.callout)
            .padding(.vertical, 2)
            .contextMenu {
                Button("Reveal in Finder") { model.revealInFinder(node) }
                Button("Remove from Collector") { model.uncollect(node) }
            }
        }
    }
}
