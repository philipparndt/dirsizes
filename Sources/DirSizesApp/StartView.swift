import SwiftUI

/// Start screen: all mounted disks with their free space, plus folder shortcuts.
struct StartView: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("Choose a disk to scan")
                    .font(.title2.weight(.semibold))
                    .padding(.bottom, 6)

                FullDiskAccessBanner()

                ForEach(model.volumes) { volume in
                    VolumeCard(volume: volume)
                }

                HStack(spacing: 12) {
                    Button("Scan Folder…", systemImage: "folder") { model.chooseFolder() }
                    Button("Home Folder", systemImage: "house") {
                        model.scan(path: NSHomeDirectory())
                    }
                }
                .controlSize(.large)
                .padding(.top, 8)
            }
            .frame(maxWidth: 620)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .onAppear { model.loadVolumes() }
    }
}

private struct VolumeCard: View {
    @Environment(ScanModel.self) private var model
    let volume: VolumeInfo
    @State private var isHovered = false

    init(volume: VolumeInfo) {
        self.volume = volume
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(volume.name)
                        .font(.headline)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Scan") { scan() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

            CapacityBar(fraction: volume.usedFraction)
                .frame(height: 10)

            HStack {
                Text("\(formatBytes(volume.usedBytes)) used")
                Spacer()
                Text("\(formatBytes(volume.availableBytes)) free of \(formatBytes(volume.totalBytes))")
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary.opacity(isHovered ? 0.9 : 0.5))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { scan() }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(volume.url.path)
    }

    private func scan() {
        model.scan(volume: volume)
    }

    private var icon: String {
        switch volume.kind {
        case .internalDisk: "internaldrive.fill"
        case .externalDisk: "externaldrive.fill"
        case .network: "externaldrive.connected.to.line.below.fill"
        }
    }

    private var subtitle: String {
        let kind = switch volume.kind {
        case .internalDisk: "Internal"
        case .externalDisk: "External"
        case .network: "Network"
        }
        return volume.format.isEmpty ? kind : "\(kind) · \(volume.format)"
    }
}

/// Used-space bar; turns orange and red as the disk fills up.
private struct CapacityBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(proxy.size.width * fraction, proxy.size.height))
            }
        }
    }

    private var colors: [Color] {
        switch fraction {
        case ..<0.75: [.blue, .purple]
        case ..<0.9: [.purple, .orange]
        default: [.orange, .red]
        }
    }
}
