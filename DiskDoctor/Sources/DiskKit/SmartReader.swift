import Foundation

/// SMART 总体健康状态。
public enum SmartHealth: String, Codable, Sendable {
    case passed = "通过"
    case failed = "失败"
    case unknown = "未知"
    case unsupported = "不支持"

    public var symbolName: String {
        switch self {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        case .unsupported: return "minus.circle"
        }
    }
}

/// SMART 报告。统一 NVMe 与 ATA 两套数据结构。
public struct SmartReport: Codable, Sendable {
    public var health: SmartHealth = .unknown
    public var modelName: String?
    public var serialNumber: String?
    public var firmwareVersion: String?
    public var temperatureCelsius: Int?
    public var powerOnHours: Int?
    public var powerCycleCount: Int?
    public var unsafeShutdowns: Int?

    /// NVMe 专有字段
    public var nvme: NVMeHealth?
    /// ATA 专有字段
    public var ata: ATAHealth?
    /// ATA 旋转率（0 = SSD）
    public var ataRotationRate: Int?
    /// 是否成功读到 SMART（false 表示设备/桥接不支持）
    public var isReadable: Bool = false
    /// 读取失败原因
    public var readError: String?
    /// PCI 厂商/子系统 ID（NVMe）
    public var pciVendorSubsystem: String?
    /// 原始 JSON（以 JSON Data 存储以保持 Codable 兼容性）
    public var rawJSONData: Data?

    public init() {}

    /// 原始 JSON 字典
    public var rawJSON: [String: Any]? {
        guard let rawJSONData,
              let obj = try? JSONSerialization.jsonObject(with: rawJSONData) as? [String: Any]
        else { return nil }
        return obj
    }
}

/// NVMe 健康信息（SMART/Health Log Page 0x02）。
public struct NVMeHealth: Codable, Sendable {
    public var criticalWarning: Int?
    public var percentageUsed: Int?
    public var availableSpare: Int?
    public var availableSpareThreshold: Int?
    public var dataUnitsRead: UInt64?
    public var dataUnitsWritten: UInt64?
    public var hostReads: UInt64?
    public var hostWrites: UInt64?
    public var controllerBusyTime: UInt64?
    public var mediaErrors: UInt64?
    public var numErrorLogEntries: UInt64?

    /// 已写入数据量（字节）
    ///
    /// NVMe 规范中 1 个 Data Unit = 1000 × 512 字节（十进制，非 1024）。
    public var bytesWritten: UInt64? {
        dataUnitsWritten.map { $0 * 1000 * 512 }
    }
    /// 已读取数据量（字节）
    public var bytesRead: UInt64? {
        dataUnitsRead.map { $0 * 1000 * 512 }
    }
}

/// ATA 健康信息（传统 SMART 属性表）。
public struct ATAHealth: Codable, Sendable {
    public struct Attribute: Codable, Sendable, Identifiable {
        public var id: Int
        public var name: String
        public var rawValue: Int64
        public var value: Int
        public var worst: Int
        public var threshold: Int
        public var failing: Bool
        /// 原始 RAW 值文本（有些属性是复合编码，需要原样展示）
        public var rawText: String

        public var id_: String { "\(id)" }
    }

    public var attributes: [Attribute] = []
    /// 已执行的自检记录
    public var selfTestLog: [SelfTestEntry] = []

    public struct SelfTestEntry: Codable, Sendable {
        public var description: String
        public var status: String
        public var hoursSince: Int?
        public var lba: Int64?
    }

    /// 关键 ATA 属性值（ID -> RAW）
    public func attribute(id: Int) -> Int64? {
        attributes.first(where: { $0.id == id })?.rawValue
    }

    /// 属性名 -> RAW
    public var attributeMap: [String: Int64] {
        var map: [String: Int64] = [:]
        for a in attributes { map[a.name] = a.rawValue }
        return map
    }
}

/// SMART 采集与解析器。
public struct SmartReader {
    private let runner: CommandRunner
    private let smartctlPath: String?

    public init(runner: CommandRunner = CommandRunner(), smartctlPath: String? = nil) {
        self.runner = runner
        self.smartctlPath = smartctlPath
    }

    /// smartctl 路径。延迟解析，避免在 UI 初始化阶段执行外部命令。
    private var resolvedSmartctlPath: String? {
        if let smartctlPath { return smartctlPath }
        return SmartReader.locateSmartctl()
    }

    /// 定位 smartctl 可执行文件。
    ///
    /// 查找顺序：
    /// 1. App bundle 内置副本（Contents/Resources/smartmontools/smartctl）——保证脱离
    ///    终端 PATH 也能工作；
    /// 2. 从当前可执行文件位置向上查找同级的 .app bundle（CLI 与 .app 同目录时的场景）；
    /// 3. 常见安装路径；
    /// 4. PATH 查找。
    public static func locateSmartctl() -> String? {
        var candidates: [String] = []

        // App bundle 内置副本
        if let bundleResources = Bundle.main.resourceURL?.appendingPathComponent("smartmontools") {
            candidates.append(bundleResources.appendingPathComponent("smartctl").path)
        }
        if let aux = Bundle.main.path(forAuxiliaryExecutable: "smartctl") {
            candidates.append(aux)
        }

        // 从可执行文件位置向上查找：dist/diskdoctor → dist/DiskDoctor.app/...
        let exePath = Bundle.main.executablePath
            ?? CommandLine.arguments.first
        if let exePath {
            let exeURL = URL(fileURLWithPath: exePath)
            // 情形一：可执行文件本身在 .app/Contents/MacOS/ 下
            let macOSDir = exeURL.deletingLastPathComponent()
            if macOSDir.lastPathComponent == "MacOS" {
                let appBundle = macOSDir.deletingLastPathComponent().deletingLastPathComponent()
                candidates.append(appBundle
                    .appendingPathComponent("Contents/Resources/smartmontools/smartctl").path)
            }
            // 情形二：可执行文件与 .app 同级（如 dist/diskdoctor 与 dist/DiskDoctor.app）
            let parentDir = exeURL.deletingLastPathComponent()
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: parentDir.path) {
                for entry in entries where entry.hasSuffix(".app") {
                    candidates.append(parentDir
                        .appendingPathComponent(entry)
                        .appendingPathComponent("Contents/Resources/smartmontools/smartctl").path)
                }
            }
        }

        // 常见安装路径
        candidates.append(contentsOf: [
            "/usr/local/bin/smartctl",
            "/opt/homebrew/bin/smartctl",
            "/usr/local/opt/smartmontools/bin/smartctl"
        ])

        // PATH 查找
        if let path = try? runnerShell("command -v smartctl") {
            let t = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { candidates.append(t) }
        }

        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return nil
    }

    private static func runnerShell(_ cmd: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// 读取指定磁盘的完整 SMART 信息。
    public func read(device: String) -> SmartReport {
        var report = SmartReport()

        guard let smartctl = resolvedSmartctlPath else {
            report.health = .unsupported
            report.readError = "未找到 smartctl 可执行文件，无法读取 SMART 数据。"
            return report
        }

        let r = (try? runner.run(smartctl, ["-j", "-a", device])) ?? CommandRunner.Result(
            status: -1, stdout: "", stderr: "无法启动 smartctl")

        var json: [String: Any] = [:]
        if let data = r.stdout.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = obj
        }

        report.rawJSONData = r.stdout.data(using: .utf8)

        // smartctl 用 exit code 表达设备状态，bit 0 表示命令执行失败。
        if json.isEmpty {
            report.health = .unsupported
            let detail = Self.extractError(from: r.stderr)
            report.readError = detail.map { "\($0)（该设备可能不支持 SMART，常见于 U 盘与部分 USB 桥接硬盘盒）" }
                ?? "SMART 数据不可读（设备或桥接芯片不支持 SMART）"
            return report
        }

        report.isReadable = true
        report.modelName = json["model_name"] as? String
        report.serialNumber = json["serial_number"] as? String
        report.firmwareVersion = json["firmware_version"] as? String

        // PCI 厂商/子系统 ID（NVMe 盘）
        if let vendor = json["nvme_pci_vendor"] as? String, !vendor.isEmpty {
            report.pciVendorSubsystem = vendor
        }

        // 健康状态
        if let status = json["smart_status"] as? [String: Any] {
            if let passed = status["passed"] as? Bool {
                report.health = passed ? .passed : .failed
            }
        } else if json["smart_support"] as? [String: Any] != nil {
            report.health = .unknown
        }

        // 温度
        if let t = (json["temperature"] as? [String: Any])?["current"] as? Int {
            report.temperatureCelsius = t
        }
        if let t = json["temperature"] as? Int {
            report.temperatureCelsius = t
        }

        // 通电时长与次数
        if let poh = json["power_on_time"] as? [String: Any] {
            report.powerOnHours = poh["hours"] as? Int
        }
        if let poh = json["power_on_hours"] as? Int {
            report.powerOnHours = poh
        }
        if let pc = json["power_cycle_count"] as? Int {
            report.powerCycleCount = pc
        }

        // NVMe 健康日志
        if let nv = json["nvme_smart_health_information_log"] as? [String: Any] {
            report.nvme = NVMeHealth(
                criticalWarning: nv["critical_warning"] as? Int,
                percentageUsed: nv["percentage_used"] as? Int,
                availableSpare: nv["available_spare"] as? Int,
                availableSpareThreshold: nv["available_spare_threshold"] as? Int,
                dataUnitsRead: (nv["data_units_read"] as? NSNumber)?.uint64Value,
                dataUnitsWritten: (nv["data_units_written"] as? NSNumber)?.uint64Value,
                hostReads: (nv["host_reads"] as? NSNumber)?.uint64Value,
                hostWrites: (nv["host_writes"] as? NSNumber)?.uint64Value,
                controllerBusyTime: (nv["controller_busy_time"] as? NSNumber)?.uint64Value,
                mediaErrors: (nv["media_errors"] as? NSNumber)?.uint64Value,
                numErrorLogEntries: (nv["num_err_log_entries"] as? NSNumber)?.uint64Value
            )
            if report.health == .unknown { report.health = .passed }
        }

        // ATA 属性表
        if let table = json["ata_smart_attributes"] as? [String: Any],
           let tableArray = table["table"] as? [[String: Any]] {
            var attrs: [ATAHealth.Attribute] = []
            for row in tableArray {
                guard let id = (row["id"] as? NSNumber)?.intValue else { continue }
                let name = row["name"] as? String ?? "Unknown_Attribute"
                let raw = (row["raw"] as? [String: Any]) ?? [:]
                let rawValue = (raw["value"] as? NSNumber)?.int64Value ?? 0
                let rawText = String(describing: raw["string"] ?? rawValue)
                let failing = ((row["when_failed"] as? String) ?? "").contains("Failing")
                    || ((row["thresh"] as? NSNumber)?.intValue ?? 0) != 0
                        && ((row["value"] as? NSNumber)?.intValue ?? 255) <= ((row["thresh"] as? NSNumber)?.intValue ?? 0)
                attrs.append(ATAHealth.Attribute(
                    id: id,
                    name: name,
                    rawValue: rawValue,
                    value: (row["value"] as? NSNumber)?.intValue ?? 0,
                    worst: (row["worst"] as? NSNumber)?.intValue ?? 0,
                    threshold: (row["thresh"] as? NSNumber)?.intValue ?? 0,
                    failing: failing,
                    rawText: rawText
                ))
            }
            var ata = ATAHealth()
            ata.attributes = attrs

            // 自检日志
            if let log = json["ata_smart_error_log"] as? [String: Any],
               let tableLog = log["table"] as? [[String: Any]] {
                var entries: [ATAHealth.SelfTestEntry] = []
                for row in tableLog {
                    entries.append(ATAHealth.SelfTestEntry(
                        description: row["description"] as? String ?? "",
                        status: row["status"] as? String ?? "",
                        hoursSince: (row["hours_since"] as? NSNumber)?.intValue,
                        lba: (row["lba"] as? NSNumber)?.int64Value
                    ))
                }
                ata.selfTestLog = entries
            }
            report.ata = ata

            // 转速：部分驱动在 device 或 rotation_rate 字段给出
            if let rate = (json["rotation_rate"] as? NSNumber)?.intValue {
                report.ataRotationRate = rate
            } else if let rate = (json["ata_rotation_rate"] as? NSNumber)?.intValue {
                report.ataRotationRate = rate
            }
        }

        // 不安全断电次数（NVMe）
        if let unsafe = report.nvme.map({ _ in 0 }) { _ = unsafe }
        if let smartLog = json["nvme_smart_health_information_log"] as? [String: Any],
           let unsafe = (smartLog["unsafe_shutdowns"] as? NSNumber)?.intValue {
            report.unsafeShutdowns = unsafe
        }

        return report
    }

    /// 发起 SMART 自检（short / long）。
    public func startSelfTest(device: String, extended: Bool) -> String {
        guard let smartctl = resolvedSmartctlPath else {
            return "未找到 smartctl，无法发起自检。"
        }
        let r = (try? runner.run(smartctl, ["-t", extended ? "long" : "short", device]))
            ?? CommandRunner.Result(status: -1, stdout: "", stderr: "无法启动 smartctl")
        return r.combined
    }

    /// 读取自检执行日志。
    public func selfTestLog(device: String) -> String {
        guard let smartctl = resolvedSmartctlPath else { return "未找到 smartctl。" }
        let r = (try? runner.run(smartctl, ["-l", "selftest", device]))
            ?? CommandRunner.Result(status: -1, stdout: "", stderr: "")
        return r.combined
    }

    /// 读取错误日志。
    public func errorLog(device: String) -> String {
        guard let smartctl = resolvedSmartctlPath else { return "未找到 smartctl。" }
        let r = (try? runner.run(smartctl, ["-l", "error", device]))
            ?? CommandRunner.Result(status: -1, stdout: "", stderr: "")
        return r.combined
    }

    private static func extractError(from stderr: String) -> String? {
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let line = lines.first(where: { $0.contains("failed:") }) {
            return line
        }
        return lines.first(where: { !$0.isEmpty })
    }
}
