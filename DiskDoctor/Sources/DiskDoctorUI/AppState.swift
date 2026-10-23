import SwiftUI
import DiskKit

/// 应用状态模型：负责磁盘枚举、检测触发与 UI 状态同步。
@MainActor
final class AppState: ObservableObject {
    @Published var disks: [DiskDescriptor] = []
    @Published var reports: [String: DiagnosticReport] = [:]
    @Published var volumes: [String: [VolumeInfo]] = [:]
    @Published var selectedDiskID: String?
    @Published var isScanning = false
    @Published var statusMessage = "准备就绪"
    @Published var lastError: String?
    /// 正在执行耗时操作的目标磁盘
    @Published var busyDiskID: String?

    private let enumerator = DiskEnumerator()
    private let smartReader = SmartReader()
    private let classifier = MediaClassifier()
    private let engine: DiagnosticEngine
    private let partitionManager = PartitionManager()

    init() {
        engine = DiagnosticEngine(smartReader: smartReader, classifier: classifier)
    }

    var selectedDisk: DiskDescriptor? {
        guard let selectedDiskID else { return nil }
        return disks.first(where: { $0.deviceIdentifier == selectedDiskID })
    }

    var selectedReport: DiagnosticReport? {
        guard let selectedDiskID else { return nil }
        return reports[selectedDiskID]
    }

    /// 枚举磁盘。
    public func refreshDisks() {
        statusMessage = "正在枚举物理磁盘…"
        let found = enumerator.listPhysicalDisks()
        disks = found
        if let current = selectedDiskID, found.contains(where: { $0.deviceIdentifier == current }) {
            // 保持选择
        } else {
            selectedDiskID = found.first?.deviceIdentifier
        }
        statusMessage = found.isEmpty
            ? "未检测到物理磁盘"
            : "检测到 \(found.count) 块物理磁盘"
        if let first = found.first, reports[first.deviceIdentifier] == nil {
            selectedDiskID = first.deviceIdentifier
        }
    }

    /// 启动流程：异步枚举磁盘并自动检测第一块盘。
    func bootstrap() async {
        let enumerator = self.enumerator
        let found = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: enumerator.listPhysicalDisks())
            }
        }
        disks = found
        statusMessage = found.isEmpty
            ? "未检测到物理磁盘"
            : "检测到 \(found.count) 块物理磁盘"
        selectedDiskID = found.first?.deviceIdentifier
        if let first = found.first {
            await scan(first)
        }
    }

    /// 对指定磁盘执行完整检测。
    func scan(_ disk: DiskDescriptor) async {
        isScanning = true
        busyDiskID = disk.deviceIdentifier
        statusMessage = "正在检测 \(disk.deviceIdentifier)…"
        defer {
            isScanning = false
            busyDiskID = nil
            statusMessage = "检测完成"
        }

        // 放到后台线程，避免阻塞主线程
        let engine = self.engine
        let report = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: engine.analyze(disk: disk))
            }
        }
        reports[disk.deviceIdentifier] = report
        lastError = nil
    }

    /// 扫描全部磁盘。
    func scanAll() async {
        for disk in disks {
            await scan(disk)
        }
    }

    /// 加载分区列表。
    func loadVolumes(for disk: DiskDescriptor) {
        volumes[disk.deviceIdentifier] = partitionManager.listVolumes(of: disk)
    }

    /// 当前系统的安全防护。
    var safetyGuard: SafetyGuard {
        partitionManager.currentSafetyGuard()
    }

    /// 目标磁盘是否被安全策略禁止操作。
    func protectionReason(for disk: DiskDescriptor) -> String? {
        safetyGuard.protectionReason(for: disk)
    }

    /// 执行抹盘。
    func eraseDisk(_ disk: DiskDescriptor,
                   scheme: PartitionScheme,
                   fileSystem: FileSystemKind,
                   volumeName: String) async -> PartitionOperationResult {
        busyDiskID = disk.deviceIdentifier
        statusMessage = "正在执行磁盘操作…"
        defer {
            busyDiskID = nil
            statusMessage = "磁盘操作已结束"
        }
        let manager = self.partitionManager
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = manager.eraseDisk(
                    disk: disk, scheme: scheme, fileSystem: fileSystem, volumeName: volumeName
                )
                continuation.resume(returning: result)
            }
        }
    }

    /// 格式化指定卷。
    func eraseVolume(_ volume: VolumeInfo,
                     fileSystem: FileSystemKind,
                     volumeName: String?) async -> PartitionOperationResult {
        statusMessage = "正在格式化 \(volume.deviceIdentifier)…"
        defer { statusMessage = "磁盘操作已结束" }
        let manager = self.partitionManager
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = manager.eraseVolume(
                    volume: volume, fileSystem: fileSystem, volumeName: volumeName
                )
                continuation.resume(returning: result)
            }
        }
    }

    /// 校验文件系统。
    func verifyVolume(_ volume: VolumeInfo) async -> PartitionOperationResult {
        statusMessage = "正在校验 \(volume.deviceIdentifier)…"
        defer { statusMessage = "校验结束" }
        let manager = self.partitionManager
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = manager.verifyVolume(volume: volume)
                continuation.resume(returning: result)
            }
        }
    }

    /// 导出文本报告。
    func exportTextReport(_ report: DiagnosticReport) {
        let exporter = ReportExporter()
        let text = exporter.textReport(for: report)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(report.disk.deviceIdentifier)-检测报告.txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
            self.statusMessage = "报告已导出到 \(url.path)"
        }
    }

    /// 导出 JSON 报告。
    func exportJSONReport(_ report: DiagnosticReport) {
        let exporter = ReportExporter()
        let json = exporter.jsonReport(for: report)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(report.disk.deviceIdentifier)-检测报告.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? json.write(to: url, atomically: true, encoding: .utf8)
            self.statusMessage = "报告已导出到 \(url.path)"
        }
    }
}
