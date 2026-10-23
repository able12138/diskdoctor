import Foundation

/// 单项检测结果。
public struct DiagnosticItem: Codable, Sendable, Identifiable {
    public enum Severity: String, Codable, Sendable {
        case pass = "正常"
        case notice = "注意"
        case warning = "警告"
        case critical = "严重"
        case unknown = "未知"

        public var symbolName: String {
            switch self {
            case .pass: return "checkmark.circle.fill"
            case .notice: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .critical: return "xmark.octagon.fill"
            case .unknown: return "minus.circle"
            }
        }
    }

    public var id: String { title }
    public let title: String
    public let value: String
    public let severity: Severity
    /// 判定依据说明
    public let rationale: String?
    /// 针对 SSD/HDD 的建议动作
    public let advice: String?

    public init(title: String, value: String, severity: Severity, rationale: String? = nil, advice: String? = nil) {
        self.title = title
        self.value = value
        self.severity = severity
        self.rationale = rationale
        self.advice = advice
    }
}

/// 检测报告汇总。
public struct DiagnosticReport: Codable, Sendable {
    public var disk: DiskDescriptor
    public var media: MediaClassification
    public var smart: SmartReport
    public var items: [DiagnosticItem] = []
    public var generatedAt: Date = Date()

    public var overallSeverity: DiagnosticItem.Severity {
        let order: [DiagnosticItem.Severity] = [.critical, .warning, .notice, .unknown, .pass]
        for s in order {
            if items.contains(where: { $0.severity == s }) { return s }
        }
        return .pass
    }

    public var summaryText: String {
        switch overallSeverity {
        case .pass: return "硬盘状态良好，未发现异常。"
        case .notice: return "硬盘整体正常，存在需要注意的项目。"
        case .warning: return "检测到警告项，建议尽快安排数据备份。"
        case .critical: return "检测到严重问题，请立即备份数据并考虑更换硬盘。"
        case .unknown: return "无法获取足够的检测数据。"
        }
    }

    public var passCount: Int { items.filter { $0.severity == .pass }.count }
    public var issueCount: Int { items.filter { $0.severity != .pass && $0.severity != .unknown }.count }
}

/// 检测引擎：依据介质类型执行差异化检查。
public struct DiagnosticEngine {
    private let smartReader: SmartReader
    private let classifier: MediaClassifier

    public init(smartReader: SmartReader = SmartReader(), classifier: MediaClassifier = MediaClassifier()) {
        self.smartReader = smartReader
        self.classifier = classifier
    }

    /// 对单块磁盘执行完整检测。
    public func analyze(disk: DiskDescriptor) -> DiagnosticReport {
        var smart = smartReader.read(device: disk.deviceNode)

        // SMART 层序列号最权威（硬盘本体），补进硬件编码。
        var resolvedDisk = disk
        if let serial = smart.serialNumber, !serial.isEmpty {
            resolvedDisk.identity.serialNumber = serial
        }
        if resolvedDisk.identity.firmwareRevision == nil,
           let fw = smart.firmwareVersion {
            resolvedDisk.identity.firmwareRevision = fw
        }
        if resolvedDisk.identity.pciVendorSubsystem == nil,
           let pci = smart.pciVendorSubsystem {
            resolvedDisk.identity.pciVendorSubsystem = pci
        }

        let media = classifier.classify(disk: resolvedDisk, smart: smart)

        var items: [DiagnosticItem] = []

        // 通用项
        items.append(contentsOf: commonItems(disk: resolvedDisk, smart: smart, media: media))

        // 介质专属项
        switch media.kind {
        case .ssd, .nvme:
            items.append(contentsOf: ssdItems(smart: smart))
        case .hdd:
            items.append(contentsOf: hddItems(smart: smart))
        case .external, .unknown:
            items.append(contentsOf: fallbackItems(smart: smart, media: media))
        }

        return DiagnosticReport(disk: resolvedDisk, media: media, smart: smart, items: items)
    }

    // MARK: - 通用检测项

    private func commonItems(disk: DiskDescriptor, smart: SmartReport, media: MediaClassification) -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []

        // SMART 健康
        items.append(DiagnosticItem(
            title: "SMART 总体状态",
            value: smart.health.rawValue,
            severity: severityForHealth(smart.health),
            rationale: smart.isReadable ? "读取自硬盘 SMART 自评状态" : (smart.readError ?? "无法读取"),
            advice: smart.health == .failed ? "立即备份数据" : nil
        ))

        // diskutil 报告的 SMART 支持状态：解释为何读不到
        if let status = disk.smartStatus, !status.isEmpty, !status.contains("Verified") {
            items.append(DiagnosticItem(
                title: "SMART 接口支持",
                value: status,
                severity: .notice,
                rationale: "系统（diskutil）对该盘 SMART 通路的判定",
                advice: status.contains("Not Supported")
                    ? "该盘通过 USB 桥接连接，桥接芯片未透传 SMART 命令，属硬件盒限制而非硬盘故障"
                    : nil
            ))
        }

        // 介质类型
        items.append(DiagnosticItem(
            title: "介质类型判定",
            value: media.kind.rawValue,
            severity: media.confidence == .low ? .notice : .pass,
            rationale: media.evidence.map { "\($0.sourceLabel)：\($0.value)" }.joined(separator: "；"),
            advice: media.confidence == .low ? "该盘 SMART 不可读，介质类型依据型号推断，建议更换支持 SAT 直通的硬盘盒复测" : nil
        ))

        // 温度
        if let t = smart.temperatureCelsius {
            let sev: DiagnosticItem.Severity
            let advice: String?
            switch t {
            case ..<35: sev = .pass; advice = nil
            case 35..<50: sev = .pass; advice = "温度偏高，注意散热"
            case 50..<60: sev = .notice; advice = "温度较高，建议改善通风或检查散热硅胶"
            case 60..<70: sev = .warning; advice = "温度过高，长期高温会显著加速硬盘老化"
            default: sev = .critical; advice = "温度严重过高，立即停止使用并检查散热"
            }
            items.append(DiagnosticItem(
                title: "工作温度",
                value: "\(t) °C",
                severity: sev,
                rationale: "来自 SMART 温度传感器",
                advice: advice
            ))
        } else {
            items.append(DiagnosticItem(
                title: "工作温度",
                value: "不可读",
                severity: .unknown,
                rationale: smart.readError ?? "设备未提供温度数据"
            ))
        }

        // 通电时长
        if let h = smart.powerOnHours {
            let sev: DiagnosticItem.Severity = h > 35000 ? .notice : .pass
            items.append(DiagnosticItem(
                title: "累计通电时长",
                value: ByteFormat.duration(hours: h),
                severity: sev,
                rationale: "\(h) 小时",
                advice: sev == .notice ? "通电时间较长，建议检查机械部件磨损与散热" : nil
            ))
        }

        // 硬件编码完整性
        let identityEntries = disk.identity.entries.count
        items.append(DiagnosticItem(
            title: "硬件编码识别",
            value: "\(identityEntries) 项可读",
            severity: identityEntries >= 2 ? .pass : .notice,
            rationale: disk.identity.entries.map { "\($0.label)=\($0.value)" }.joined(separator: "；"),
            advice: identityEntries < 2 ? "可识别编码偏少，通常是 USB 桥接芯片屏蔽所致" : nil
        ))

        return items
    }

    // MARK: - SSD 专项

    private func ssdItems(smart: SmartReport) -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []

        guard let nv = smart.nvme else {
            // SATA/SAS SSD：走 ATA 属性
            items.append(contentsOf: ataBasedSSDItems(smart: smart))
            return items
        }

        // 寿命消耗
        if let used = nv.percentageUsed {
            let sev: DiagnosticItem.Severity
            let advice: String?
            switch used {
            case ..<50: sev = .pass; advice = nil
            case 50..<80: sev = .notice; advice = "已消耗过半寿命，注意保持剩余空间充足"
            case 80..<95: sev = .warning; advice = "寿命消耗较高，建议规划更换并做好备份"
            default: sev = .critical; advice = "寿命即将耗尽，立即备份全部数据并准备更换"
            }
            items.append(DiagnosticItem(
                title: "SSD 寿命消耗",
                value: "\(used)%",
                severity: sev,
                rationale: "Percentage Used（NVMe Log 0x02），100% 表示写入寿命耗尽",
                advice: advice
            ))
        }

        // 剩余寿命
        if let used = nv.percentageUsed {
            items.append(DiagnosticItem(
                title: "预计剩余寿命",
                value: "\(max(0, 100 - used))%",
                severity: used >= 80 ? .warning : .pass,
                rationale: "由已消耗百分比推算"
            ))
        }

        // 备用空间
        if let spare = nv.availableSpare, let threshold = nv.availableSpareThreshold {
            let sev: DiagnosticItem.Severity = spare <= threshold ? .warning : .pass
            items.append(DiagnosticItem(
                title: "备用空间",
                value: "\(spare)%（阈值 \(threshold)%）",
                severity: sev,
                rationale: "Available Spare，备用区耗尽将导致无法写入",
                advice: sev == .warning ? "备用空间接近告警线，需尽快更换硬盘" : nil
            ))
        }

        // 介质与数据完整性错误
        if let errors = nv.mediaErrors {
            let sev: DiagnosticItem.Severity = errors > 0 ? .critical : .pass
            items.append(DiagnosticItem(
                title: "介质与数据完整性错误",
                value: "\(errors)",
                severity: sev,
                rationale: "Media and Data Integrity Errors，NVMe 不可纠正的介质层错误",
                advice: sev == .critical ? "出现介质层数据损坏错误，数据已不可信，必须立即备份" : nil
            ))
        }

        // 错误日志条目
        if let entries = nv.numErrorLogEntries {
            let sev: DiagnosticItem.Severity = entries > 0 ? .notice : .pass
            items.append(DiagnosticItem(
                title: "错误日志条目",
                value: "\(entries)",
                severity: sev,
                rationale: "Error Information Log Entries",
                advice: sev == .notice ? "存在控制器错误记录，建议查看错误日志详情" : nil
            ))
        }

        // 写入量
        if let written = nv.bytesWritten {
            items.append(DiagnosticItem(
                title: "累计写入量",
                value: ByteFormat.string(fromBytes: written),
                severity: .pass,
                rationale: "Data Units Written × 1000 × 512 字节（NVMe 规范定义）"
            ))
        }
        if let read = nv.bytesRead {
            items.append(DiagnosticItem(
                title: "累计读取量",
                value: ByteFormat.string(fromBytes: read),
                severity: .pass,
                rationale: "Data Units Read × 1000 × 512 字节（NVMe 规范定义）"
            ))
        }

        // 断电异常
        if let unsafe = smart.unsafeShutdowns {
            let sev: DiagnosticItem.Severity = unsafe > 50 ? .notice : .pass
            items.append(DiagnosticItem(
                title: "异常断电次数",
                value: "\(unsafe)",
                severity: sev,
                rationale: "Unsafe Shutdowns，断电或强制关机次数",
                advice: sev == .notice ? "异常断电较多，建议排查供电与使用习惯" : nil
            ))
        }

        // 温度已在通用项处理，这里不重复。

        return items
    }

    /// SATA 接口的固态盘：以 ATA 属性判断。
    private func ataBasedSSDItems(smart: SmartReport) -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []
        guard let ata = smart.ata else {
            items.append(DiagnosticItem(
                title: "SSD 健康细节",
                value: "不可读",
                severity: .unknown,
                rationale: smart.readError ?? "未取得 NVMe 或 ATA 健康数据"
            ))
            return items
        }

        // 通电次数 / 重映射扇区
        let reallocated = ata.attribute(id: 5)
        if let v = reallocated {
            let sev: DiagnosticItem.Severity = v > 0 ? .warning : .pass
            items.append(DiagnosticItem(
                title: "重映射扇区数",
                value: "\(v)",
                severity: sev,
                rationale: "SMART 属性 5 (Reallocated_Sector_Ct)",
                advice: sev == .warning ? "出现重映射扇区，说明已有坏块被替换，继续增长需更换硬盘" : nil
            ))
        }

        let pending = ata.attribute(id: 197)
        if let v = pending {
            let sev: DiagnosticItem.Severity = v > 0 ? .warning : .pass
            items.append(DiagnosticItem(
                title: "待定扇区数",
                value: "\(v)",
                severity: sev,
                rationale: "SMART 属性 197 (Current_Pending_Sector)",
                advice: sev == .warning ? "存在待重映射扇区，磁盘可能正在发生不可读错误" : nil
            ))
        }

        let uncorrectable = ata.attribute(id: 198)
        if let v = uncorrectable {
            let sev: DiagnosticItem.Severity = v > 0 ? .critical : .pass
            items.append(DiagnosticItem(
                title: "不可校正扇区数",
                value: "\(v)",
                severity: sev,
                rationale: "SMART 属性 198 (Offline_Uncorrectable)",
                advice: sev == .critical ? "存在不可校正错误，强烈建议立即备份" : nil
            ))
        }

        // SSD 通电小时数（属性 9 / 233）
        if let hours = ata.attribute(id: 9), hours > 0 {
            items.append(DiagnosticItem(
                title: "累计通电时长",
                value: ByteFormat.duration(hours: Int(hours)),
                severity: .pass,
                rationale: "SMART 属性 9 (Power_On_Hours)"
            ))
        }

        return items
    }

    // MARK: - HDD 专项

    private func hddItems(smart: SmartReport) -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []

        guard let ata = smart.ata else {
            items.append(DiagnosticItem(
                title: "机械硬盘健康细节",
                value: "不可读",
                severity: .unknown,
                rationale: smart.readError ?? "未取得 ATA 健康数据（常见于 USB 桥接盘）"
            ))
            return items
        }

        // 重映射扇区（坏道代理指标）
        if let v = ata.attribute(id: 5) {
            let sev: DiagnosticItem.Severity
            let advice: String?
            switch v {
            case 0: sev = .pass; advice = nil
            case 1...10: sev = .notice; advice = "出现少量重映射扇区，继续观察增长趋势"
            case 11...100: sev = .warning; advice = "重映射扇区较多，硬盘已出现物理坏道，建议尽快备份并更换"
            default: sev = .critical; advice = "重映射扇区数量严重超标，硬盘随时可能失效"
            }
            items.append(DiagnosticItem(
                title: "重映射扇区（坏道）",
                value: "\(v)",
                severity: sev,
                rationale: "SMART 属性 5 (Reallocated_Sector_Ct)：已被替换的物理坏扇区数量",
                advice: advice
            ))
        }

        // 待定扇区
        if let v = ata.attribute(id: 197) {
            let sev: DiagnosticItem.Severity = v > 0 ? .warning : .pass
            items.append(DiagnosticItem(
                title: "待定扇区",
                value: "\(v)",
                severity: sev,
                rationale: "SMART 属性 197 (Current_Pending_Sector)",
                advice: sev == .warning ? "存在待重映射扇区，读写该区域可能报错" : nil
            ))
        }

        // 不可校正扇区
        if let v = ata.attribute(id: 198) {
            let sev: DiagnosticItem.Severity = v > 0 ? .critical : .pass
            items.append(DiagnosticItem(
                title: "不可校正扇区",
                value: "\(v)",
                severity: sev,
                rationale: "SMART 属性 198 (Offline_Uncorrectable)",
                advice: sev == .critical ? "存在不可校正错误，强烈建议立即备份" : nil
            ))
        }

        // 寻道错误率
        if let v = ata.attribute(id: 7) {
            items.append(DiagnosticItem(
                title: "寻道错误率",
                value: "\(v)",
                severity: .pass,
                rationale: "SMART 属性 7 (Seek_Error_Rate)"
            ))
        }

        // 磁头寻道/寻道超时（机械故障前兆）
        if let v = ata.attribute(id: 199) {
            let sev: DiagnosticItem.Severity = v > 0 ? .warning : .pass
            items.append(DiagnosticItem(
                title: "寻道错误计数",
                value: "\(v)",
                severity: sev,
                rationale: "SMART 属性 199 (UDMA_CRC_Error_Count / Seek_Error_Count)",
                advice: sev == .warning ? "可能存在磁头故障或数据线接触不良" : nil
            ))
        }

        // 螺旋起转时间（机械盘是否正常启动）
        if let v = ata.attribute(id: 2) {
            items.append(DiagnosticItem(
                title: "起转时间",
                value: "\(v)",
                severity: .pass,
                rationale: "SMART 属性 2 (Spin_Up_Time)"
            ))
        }

        // 硬件 ECC 纠错计数
        if let v = ata.attribute(id: 200) {
            let sev: DiagnosticItem.Severity = v > 0 ? .notice : .pass
            items.append(DiagnosticItem(
                title: "硬件 ECC 纠错次数",
                value: "\(v)",
                severity: sev,
                rationale: "SMART 属性 200 (Hardware ECC Corrections)"
            ))
        }

        // 自检记录
        if let ata = smart.ata, !ata.selfTestLog.isEmpty {
            let latest = ata.selfTestLog.first
            let passed = (latest?.status ?? "").contains("Completed")
            items.append(DiagnosticItem(
                title: "上次自检结果",
                value: latest.map { "\($0.status) \($0.description)" } ?? "无记录",
                severity: passed ? .pass : .notice,
                rationale: "读取自 SMART 自检日志"
            ))
        }

        return items
    }

    // MARK: - 兜底

    private func fallbackItems(smart: SmartReport, media: MediaClassification) -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []

        // 已知介质类型但 SMART 读不到：说明是接口/桥接限制，不是硬盘本身故障。
        if media.kind.isSolidState {
            items.append(DiagnosticItem(
                title: "SSD 健康深度检测",
                value: "受限（接口不支持）",
                severity: .notice,
                rationale: smart.readError ?? "该盘未返回可解析的 SMART 数据",
                advice: "介质类型已确认是固态盘，但接口层读不到 SMART。常见于 USB 硬盘盒桥接芯片屏蔽 SAT 直通（部分绿联/Realtek 桥接芯片即如此）。可改用支持 SMART 直通的硬盘盒复测"
            ))
        } else {
            items.append(DiagnosticItem(
                title: "深度健康检测",
                value: "受限",
                severity: .notice,
                rationale: smart.readError ?? "该盘未返回可解析的 SMART 数据",
                advice: "常见原因：USB 硬盘盒桥接芯片不支持 SAT 直通。建议换用支持 SMART 直通的硬盘盒，或将 SATA 盘直连主板后复测"
            ))
        }

        // 即便无 SMART，也可做文件系统级校验
        items.append(DiagnosticItem(
            title: "可用的替代检测",
            value: "文件系统校验 / 分区结构检查",
            severity: .pass,
            rationale: "使用 diskutil verifyVolume 与分区表解析，不依赖 SMART"
        ))
        return items
    }

    private func severityForHealth(_ health: SmartHealth) -> DiagnosticItem.Severity {
        switch health {
        case .passed: return .pass
        case .failed: return .critical
        case .unsupported: return .notice
        case .unknown: return .unknown
        }
    }
}
