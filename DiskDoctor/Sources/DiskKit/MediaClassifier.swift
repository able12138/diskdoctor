import Foundation

/// 存储介质类型。
public enum MediaKind: String, Codable, CaseIterable, Sendable {
    case ssd = "固态硬盘 (SSD)"
    case hdd = "机械硬盘 (HDD)"
    case nvme = "NVMe 固态盘"
    case external = "外置存储"
    case unknown = "未知"

    /// 是否属于固态类介质（不含机械盘）。
    public var isSolidState: Bool {
        switch self {
        case .ssd, .nvme: return true
        case .hdd, .external, .unknown: return false
        }
    }

    public var shortLabel: String {
        switch self {
        case .ssd: return "SSD"
        case .hdd: return "HDD"
        case .nvme: return "NVMe"
        case .external: return "EXT"
        case .unknown: return "?"
        }
    }
}

/// 判定介质类型时依据的来源，用于向用户解释结论是怎么得出的。
public struct MediaKindEvidence: Codable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable {
        case nvmeProtocol
        case ataRotationRate
        case diskutilSolidState
        case ioregMediumType
        case modelNameHint
        case usbTransport
    }

    public var id: String { source.rawValue }
    public let source: Source
    public let value: String
    /// 该来源给出的判断，nil 表示无法判定。
    public let implied: MediaKind?

    public init(source: Source, value: String, implied: MediaKind?) {
        self.source = source
        self.value = value
        self.implied = implied
    }

    public var sourceLabel: String {
        switch source {
        case .nvmeProtocol: return "NVMe 协议"
        case .ataRotationRate: return "ATA 转速"
        case .diskutilSolidState: return "diskutil 属性"
        case .ioregMediumType: return "IOKit 属性"
        case .modelNameHint: return "型号推断"
        case .usbTransport: return "USB 传输"
        }
    }
}

/// 多源交叉判定的结果。
public struct MediaClassification: Codable, Sendable {
    public let kind: MediaKind
    public let confidence: Confidence
    public let evidence: [MediaKindEvidence]

    public enum Confidence: String, Codable, Sendable {
        case high = "高"
        case medium = "中"
        case low = "低"

        public var symbolName: String {
            switch self {
            case .high: return "checkmark.seal.fill"
            case .medium: return "exclamationmark.triangle.fill"
            case .low: return "questionmark.circle.fill"
            }
        }
    }

    public init(kind: MediaKind, confidence: Confidence, evidence: [MediaKindEvidence]) {
        self.kind = kind
        self.confidence = confidence
        self.evidence = evidence
    }
}

/// 介质类型判定器。
///
/// macOS 上不能只依赖单一信号：
/// - NVMe 设备必然是固态（协议本身即定义在闪存之上）；
/// - ATA 设备读取 IDENTIFY 的 rotation rate 是权威依据；
/// - `diskutil info` 的 SolidState 属性来自系统缓存，仅作交叉参考；
/// - USB 外置盘常因桥接芯片屏蔽 SAT 而读不到 SMART，此时退回型号启发式。
public struct MediaClassifier {

    private let runner: CommandRunner

    public init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner
    }

    /// 综合判定磁盘介质类型。
    public func classify(
        disk: DiskDescriptor,
        smart: SmartReport?
    ) -> MediaClassification {
        var evidence: [MediaKindEvidence] = []
        var votes: [MediaKind: Int] = [:]

        func vote(_ kind: MediaKind?, source: MediaKindEvidence.Source, value: String) {
            evidence.append(MediaKindEvidence(source: source, value: value, implied: kind))
            if let kind { votes[kind, default: 0] += 1 }
        }

        // 1) NVMe 协议：物理层即固态，权重最高。
        if disk.busProtocol?.uppercased().contains("NVME") == true {
            vote(.nvme, source: .nvmeProtocol, value: disk.busProtocol ?? "")
        }

        // 2) ATA 旋转率：0 = SSD，>0 表示 RPM。
        if let rate = smart?.ataRotationRate {
            if rate == 0 {
                vote(.ssd, source: .ataRotationRate, value: "0 RPM（固态）")
            } else {
                vote(.hdd, source: .ataRotationRate, value: "\(rate) RPM")
            }
        }

        // 3) diskutil 的 SolidState 属性。
        if let solid = disk.solidState {
            vote(solid ? .ssd : .hdd, source: .diskutilSolidState, value: solid ? "Solid State = Yes" : "Solid State = No")
        }

        // 4) IOKit 设备特征里的 Medium Type。
        if let medium = disk.ioKitMediumType {
            let normalized = medium.lowercased()
            if normalized.contains("solid") {
                vote(.ssd, source: .ioregMediumType, value: medium)
            } else if normalized.contains("magnetic") || normalized.contains("hdd") || normalized.contains("rotational") {
                vote(.hdd, source: .ioregMediumType, value: medium)
            }
        }

        // 5) 型号启发式：仅在没有更强证据时作为兜底。
        let hint = Self.modelHint(model: disk.modelName, smart: smart)
        if let hint {
            let modelText = disk.modelName ?? (smart?.modelName ?? "未知型号")
            vote(hint.kind, source: .modelNameHint, value: modelText)
        }

        // 6) USB 传输层无法区分介质，仅记录不作票。
        if disk.isExternal && disk.busProtocol?.uppercased().contains("USB") == true {
            evidence.append(MediaKindEvidence(source: .usbTransport,
                                              value: "USB 外置连接（介质类型需由其他信号判定）",
                                              implied: nil))
        }

        // 汇总投票。NVMe 票单独加权为 2 分，因为协议本身即定论。
        var score: [MediaKind: Int] = [:]
        for e in evidence {
            guard let implied = e.implied else { continue }
            let weight = (e.source == .nvmeProtocol) ? 2 : 1
            score[implied, default: 0] += weight
        }

        // 若有 NVMe 协议证据，直接定为 NVMe。
        if disk.busProtocol?.uppercased().contains("NVME") == true {
            return MediaClassification(kind: .nvme,
                                       confidence: .high,
                                       evidence: evidence)
        }

        // NVMe 固件盘（通过 USB 桥接）优先归为外置固态。
        guard let (bestKind, bestScore) = score.max(by: { $0.value < $1.value }) else {
            // 无任何证据：若为外置 USB 且完全读不到 SMART，提示无法区分。
            let fallback: MediaKind = disk.isExternal ? .external : .unknown
            let confidence: MediaClassification.Confidence = disk.isExternal ? .low : .low
            return MediaClassification(kind: fallback, confidence: confidence, evidence: evidence)
        }

        // 存在冲突证据时降低置信度。
        let runnerUp = score.filter { $0.key != bestKind }.values.max() ?? 0
        let confidence: MediaClassification.Confidence
        if bestScore >= 2 && bestScore > runnerUp {
            confidence = .high
        } else if bestScore > runnerUp {
            confidence = .medium
        } else {
            confidence = .low
        }

        // 外置 USB 盘若确认为固态，统一标为 external 便于用户识别场景。
        var finalKind = bestKind
        if disk.isExternal && bestKind.isSolidState {
            finalKind = .ssd
        }

        return MediaClassification(kind: finalKind, confidence: confidence, evidence: evidence)
    }

    /// 型号字符串启发式。
    private static func modelHint(model: String?, smart: SmartReport?) -> (kind: MediaKind, text: String)? {
        let text = (model ?? smart?.modelName ?? "").uppercased()
        guard !text.isEmpty else { return nil }

        // 闪存介质（固态盘 / U 盘 / 移动固态）
        let ssdTokens = ["SSD", "NVME", "SOLID STATE", "M.2", "SAMSUNG SSD", "SNV",
                         "980", "990", "870 EVO", "860 EVO", "SN770", "SN850",
                         "WD_BLUE SSD", "WD GREEN SSD", "CRUCIAL", "SANDISK",
                         "APPLE SSD", "LITEON", "LITE-ON", "PHISON", "YMTC", "BIWIN",
                         // U 盘 / 移动固态：金士顿 DataTraveler 等
                         "DATATRAVELER", "DATA TRAVELER", "FLASH DRIVE", "USB FLASH",
                         "KINGSTON DT", "KINGSTON DXR", "ESD"]
        // 机械介质
        let hddTokens = ["BARRA", "WD HDD", "WD RED", "WD BLUE HDD", "WD BLACK",
                         "HARD DRIVE", "SAMSUNG HDD", "HGST",
                         "SEAGATE", "BARRACUDA", "CONSTELLATION", "SURROUND",
                         "ELEMENTS", "MY PASSPORT", "EXPANSION", "DESKTOP HDD",
                         "KINGSTON DT10", "KINGSTON CANVAS"]

        // 通用固态厂商词表（型号中含这些词且无机械特征词时判为固态）
        let genericSsdVendors = ["KINGSTON", "CRUCIAL", "SANDISK", "BIWIN", "PHISON"]

        for t in ssdTokens where text.contains(t) { return (.ssd, text) }
        for t in hddTokens where text.contains(t) { return (.hdd, text) }

        // 通用厂商词兜底：这类厂商同时生产机械与固态产品，
        // 若型号中无机械特征词（如 HDD/BARRACUDA/ELEMENTS），按固态处理。
        for t in genericSsdVendors where text.contains(t) { return (.ssd, text) }

        return nil
    }
}
