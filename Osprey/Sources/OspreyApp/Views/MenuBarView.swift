import SwiftUI

struct MenuBarView: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Osprey").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(manager.activeCount) active").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                Text(Format.speed(manager.totalSpeed)).font(.system(size: 30, weight: .medium, design: .monospaced))
            }
            .padding(16)
            Divider()
            VStack(spacing: 4) {
                ForEach(manager.items.filter { $0.status == .downloading || $0.status == .queued }.prefix(4)) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.snapshot.fileName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text(item.status == .queued ? "Queued" : Format.speed(item.snapshot.bytesPerSecond))
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                        }
                        ProgressView(value: item.progress).tint(Theme.accent)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
            .padding(.vertical, 6)
            Divider()
            HStack {
                Button("Pause all") { manager.pauseAll() }
                Spacer()
                Button("Open Osprey") { openWindow(id: "main"); NSApp.activate() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            .padding(12)
        }
        .frame(width: 340)
    }
}
