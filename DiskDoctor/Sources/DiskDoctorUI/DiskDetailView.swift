import SwiftUI
import DiskKit

/// 磁盘详情页。
struct DiskDetailView: View {
    let disk: DiskDescriptor
    let report: DiagnosticReport?
    let volumes: [VolumeInfo]
    let isScanning: Bool
    let onScan: () -> Void
    let onPartition: () -> Void
    let onLoadVolumes: () -> Void
    let onEraseVolume: (VolumeInfo) -> Void
    let onVerifyVolume: (VolumeInfo) -> Void
    let onExportText: (DiagnosticReport) -> Void
    let onExportJSON: (DiagnosticReport) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerCard
                if let report {
                    conclusionCard(report)
                    hardwareCard(report)
                    diagnosticsCard(report)
                } else {
                    placeholderCard
                }
                volumesCard
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 头部

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(disk.modelName ?? disk.deviceIdentifier)
                        .font(.title2.weight(.semibold))
                    Text("\(disk.deviceIdentifier)  ·  \(disk.deviceNode)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isScanning {
                    ProgressView().controlSize(.small)
                }
                Button(action: onScan) {
                    Label("开始检测", systemImage: "stethoscope")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isScanning)
            }

            Divider()

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], alignment: .leading, spacing: 10) {
                infoTile("容量", disk.formattedSize, icon: "internaldrive")
                infoTile("协议", disk.busProtocol ?? "未知", icon: "cable.connector")
                infoTile("位置", disk.isInternal ? "内置" : (disk.isEjectable ? "外置 · 可弹出" : "外置"), icon: "laptopcomputer")
                infoTile("分区表", disk.contentType ?? "未知", icon: "square.grid.3x3")
                if let kind = report?.media.kind {
                    infoTile("介质类型", kind.rawValue, icon: kind == .hdd ? "externaldrive" : "ssd")
                }
                if let t = report?.smart.temperatureCelsius {
                    infoTile("温度", "\(t) °C", icon: "thermometer.medium")
                }
                if let h = report?.smart.powerOnHours {
                    infoTile("通电时长", ByteFormat.duration(hours: h), icon: "clock")
                }
                if let s = report?.smart.health {
                    infoTile("SMART", s.rawValue, icon: "checkmark.shield")
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func infoTile(_ title: String, _ value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout.weight(.medium)).lineLimit(1)
            }
        }
    }

    // MARK: - 结论

    private func conclusionCard(_ report: DiagnosticReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("检测结论", systemImage: "checkmark.shield")
                .font(.headline)
            HStack(spacing: 10) {
                Image(systemName: report.overallSeverity.symbolName)
                    .font(.title2)
                    .foregroundStyle(severityColor(report.overallSeverity))
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.summaryText).font(.body.weight(.medium))
                    Text("正常 \(report.passCount) 项 · 异常 \(report.issueCount) 项 · 介质判定置信度 \(report.media.confidence.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack {
                Button {
                    onExportText(report)
                } label: {
                    Label("导出文本报告", systemImage: "doc.text")
                }
                Button {
                    onExportJSON(report)
                } label: {
                    Label("导出 JSON", systemImage: "curlybraces")
                }
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 硬件编码

    private func hardwareCard(_ report: DiagnosticReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("硬件编码", systemImage: "barcode")
                .font(.headline)

            let entries = report.disk.identity.entries
            if entries.isEmpty {
                Text("未读取到硬件编码")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // 键值对齐展示
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entries, id: \.label) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(entry.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 130, alignment: .leading)
                            Text(entry.value)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 检测明细

    private func diagnosticsCard(_ report: DiagnosticReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("检测明细", systemImage: "list.bullet.clipboard")
                    .font(.headline)
                Spacer()
                Text("\(report.items.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(report.items) { item in
                DiagnosticItemView(item: item)
            }

            if !report.media.evidence.isEmpty {
                Divider()
                MediaEvidenceView(evidence: report.media.evidence)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var placeholderCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "stethoscope")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("尚未检测")
                .font(.headline)
            Text("点击右上角「开始检测」读取该盘的 SMART 健康数据与硬件编码")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(30)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 分区

    private var volumesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("分区与卷", systemImage: "square.grid.3x3")
                    .font(.headline)
                Spacer()
                Button(action: onLoadVolumes) {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                Button(action: onPartition) {
                    Label("分区 / 格式化整盘", systemImage: "wrench.and.screwdriver")
                }
                .buttonStyle(.bordered)
            }

            if volumes.isEmpty {
                Text("点击「刷新」加载分区列表")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(volumes) { v in
                    VolumeRow(volume: v,
                              onErase: { onEraseVolume(v) },
                              onVerify: { onVerifyVolume(v) })
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
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

/// 介质类型判定依据展示。
struct MediaEvidenceView: View {
    let evidence: [MediaKindEvidence]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("介质类型判定依据")
                .font(.subheadline.weight(.medium))
            ForEach(evidence) { e in
                EvidenceRow(evidence: e)
            }
        }
    }
}

/// 单条判定依据。
struct EvidenceRow: View {
    let evidence: MediaKindEvidence

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: evidence.implied == nil ? "minus.circle" : "checkmark.circle")
                .font(.caption)
                .foregroundStyle(evidence.implied == nil ? Color.secondary : Color.green)
            Text(evidence.sourceLabel)
                .font(.caption.weight(.medium))
                .frame(width: 100, alignment: .leading)
            Text(evidence.value)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

/// 单条检测结果。
struct DiagnosticItemView: View {
    let item: DiagnosticItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.severity.symbolName)
                .font(.callout)
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.callout.weight(.medium))
                    Text(item.value)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let r = item.rationale, !r.isEmpty {
                    Text(r)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let a = item.advice, !a.isEmpty {
                    Label(a, systemImage: "lightbulb")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
    }

    private var color: Color {
        switch item.severity {
        case .pass: return .green
        case .notice: return .orange
        case .warning: return .orange
        case .critical: return .red
        case .unknown: return .secondary
        }
    }
}

/// 卷行。
struct VolumeRow: View {
    let volume: VolumeInfo
    let onErase: () -> Void
    let onVerify: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: volume.isWholeDisk ? "internaldrive" : "externaldrive.badge.wifi")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(volume.deviceIdentifier)
                        .font(.callout.monospaced())
                    if let name = volume.volumeName, !name.isEmpty {
                        Text(name)
                            .font(.callout)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                    }
                    if volume.isMounted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .help("已挂载")
                    }
                }
                Text("\(volume.formattedSize)  ·  \(volume.fileSystem ?? "未知文件系统")"
                     + (volume.mountPoint.map { "  ·  \($0)" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !volume.isWholeDisk {
                Button("校验", action: onVerify)
                    .buttonStyle(.borderless)
                Button("格式化…", action: onErase)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 3)
    }
}
