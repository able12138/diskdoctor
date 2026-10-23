import SwiftUI
import DiskKit

/// 主窗口：左侧磁盘列表 + 右侧详情。
struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var showingPartitionSheet = false
    @State private var showingEraseVolumeSheet = false
    @State private var targetVolume: VolumeInfo?

    var body: some View {
        NavigationSplitView {
            diskList
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        } detail: {
            detailView
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await state.scanAll() }
                } label: {
                    Label("检测全部", systemImage: "checkmark.shield")
                }
                .disabled(state.isScanning)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.refreshDisks()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(state.isScanning)
            }
        }
        .sheet(isPresented: $showingPartitionSheet) {
            if let disk = state.selectedDisk {
                PartitionSheet(disk: disk)
            }
        }
        .sheet(isPresented: $showingEraseVolumeSheet) {
            if let volume = targetVolume {
                EraseVolumeSheet(volume: volume)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .diskDoctorReady)) { _ in
            // 由 AppDelegate 在窗口呈现完成后触发，避免与 SwiftUI 首次渲染竞争
            Task { await state.bootstrap() }
        }
    }

    // MARK: - 左侧列表

    private var diskList: some View {
        VStack(spacing: 0) {
            List(selection: $state.selectedDiskID) {
                Section("物理磁盘") {
                    ForEach(state.disks) { disk in
                        DiskRow(disk: disk, report: state.reports[disk.deviceIdentifier])
                            .tag(disk.deviceIdentifier)
                            .contextMenu {
                                Button("立即检测") {
                                    Task { await state.scan(disk) }
                                }
                                Button("加载分区信息") {
                                    state.loadVolumes(for: disk)
                                }
                            }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack {
                if state.isScanning {
                    ProgressView().controlSize(.small)
                    Text(state.statusMessage).font(.caption).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(state.statusMessage).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - 右侧详情

    @ViewBuilder
    private var detailView: some View {
        if let disk = state.selectedDisk {
            DiskDetailView(
                disk: disk,
                report: state.selectedReport,
                volumes: state.volumes[disk.deviceIdentifier] ?? [],
                isScanning: state.isScanning && state.busyDiskID == disk.deviceIdentifier,
                onScan: { Task { await state.scan(disk) } },
                onPartition: { showingPartitionSheet = true },
                onLoadVolumes: { state.loadVolumes(for: disk) },
                onEraseVolume: { volume in
                    targetVolume = volume
                    showingEraseVolumeSheet = true
                },
                onVerifyVolume: { volume in
                    Task { _ = await state.verifyVolume(volume) }
                },
                onExportText: { report in state.exportTextReport(report) },
                onExportJSON: { report in state.exportJSONReport(report) }
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 42))
                    .foregroundStyle(.tertiary)
                Text("请选择一块磁盘")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 列表中的单块磁盘行。
struct DiskRow: View {
    let disk: DiskDescriptor
    let report: DiagnosticReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                Text(disk.modelName ?? disk.deviceIdentifier)
                    .font(.body)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let report {
                    Image(systemName: report.overallSeverity.symbolName)
                        .foregroundStyle(severityColor(report.overallSeverity))
                        .help(report.summaryText)
                }
            }
            HStack(spacing: 8) {
                Text(disk.deviceIdentifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(disk.formattedSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(disk.isInternal ? "内置" : "外置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let kind = report?.media.kind {
                    Text(kind.shortLabel)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(iconColor.opacity(0.16), in: Capsule())
                        .foregroundStyle(iconColor)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var iconName: String {
        guard let kind = report?.media.kind else { return "internaldrive" }
        switch kind {
        case .ssd: return "ssd"
        case .nvme: return "bolt.horizontal.circle"
        case .hdd: return "externaldrive.connected.to.line.below"
        case .external: return "externaldrive"
        case .unknown: return "questionmark.square.dashed"
        }
    }

    private var iconColor: Color {
        guard let kind = report?.media.kind else { return .secondary }
        switch kind {
        case .ssd, .nvme: return .blue
        case .hdd: return .purple
        case .external: return .teal
        case .unknown: return .secondary
        }
    }

    private func severityColor(_ s: DiagnosticItem.Severity) -> Color {
        switch s {
        case .pass: return .green
        case .notice: return .orange
        case .warning: return .orange
        case .critical: return .red
        case .unknown: return .secondary
        }
    }
}
