import Foundation
import DiskKit

/// 命令行入口。
///
/// 用法：
///   diskdoctor list                    列出全部物理磁盘与介质类型
///   diskdoctor info <diskN>            查看磁盘概况与硬件编码
///   diskdoctor scan <diskN>            执行完整检测并输出报告
///   diskdoctor selftest <diskN> [short|long]   发起 SMART 自检
///   diskdoctor selftest-log <diskN>    查看自检日志
///   diskdoctor errorlog <diskN>        查看错误日志
///   diskdoctor volumes <diskN>         列出分区与卷
///   diskdoctor partition <diskN>       交互式分区与格式化
///   diskdoctor export <diskN> [路径]    导出 JSON 报告
enum CLIError: Error {
    case usage(String)
    case failed(String)
}

struct CLI {
    let runner: CommandRunner
    let enumerator: DiskEnumerator
    let smartReader: SmartReader
    let classifier: MediaClassifier
    let engine: DiagnosticEngine
    let partitionManager: PartitionManager
    let exporter = ReportExporter()

    init() {
        let r = CommandRunner()
        runner = r
        enumerator = DiskEnumerator(runner: r)
        smartReader = SmartReader(runner: r)
        classifier = MediaClassifier(runner: r)
        engine = DiagnosticEngine(smartReader: smartReader, classifier: classifier)
        partitionManager = PartitionManager(runner: r)
    }

    func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            return
        }

        switch command {
        case "list":
            try listDisks()
        case "info":
            let disk = try requireDisk(args)
            try showInfo(disk)
        case "scan":
            let disk = try requireDisk(args)
            try scanDisk(disk)
        case "selftest":
            let disk = try requireDisk(args)
            let mode = args.count > 2 ? args[2] : "short"
            let extended = mode == "long"
            print(smartReader.startSelfTest(device: disk.deviceNode, extended: extended))
        case "selftest-log":
            let disk = try requireDisk(args)
            print(smartReader.selfTestLog(device: disk.deviceNode))
        case "errorlog":
            let disk = try requireDisk(args)
            print(smartReader.errorLog(device: disk.deviceNode))
        case "volumes":
            let disk = try requireDisk(args)
            try listVolumes(disk)
        case "partition":
            let disk = try requireDisk(args)
            try interactivePartition(disk)
        case "export":
            let disk = try requireDisk(args)
            try exportReport(disk, path: args.count > 2 ? args[2] : nil)
        case "help", "-h", "--help":
            printUsage()
        default:
            throw CLIError.usage("未知命令：\(command)")
        }
    }

    // MARK: - 实现

    private func printUsage() {
        print("""
        DiskDoctor —— macOS 硬盘检测与分区工具

        用法：
          diskdoctor list                           列出全部物理磁盘（自动区分 SSD/HDD）
          diskdoctor info <diskN>                   磁盘概况、介质类型判定、硬件编码
          diskdoctor scan <diskN>                   完整检测并输出报告
          diskdoctor selftest <diskN> [short|long]  发起 SMART 自检
          diskdoctor selftest-log <diskN>           查看 SMART 自检日志
          diskdoctor errorlog <diskN>               查看 SMART 错误日志
          diskdoctor volumes <diskN>                列出分区与卷
          diskdoctor partition <diskN>              交互式分区 / 格式化
          diskdoctor export <diskN> [文件路径]      导出 JSON 报告

        说明：磁盘写操作需要管理员权限，本工具会通过系统弹窗请求授权。
        """)
    }

    private func requireDisk(_ args: [String]) throws -> DiskDescriptor {
        guard args.count >= 2 else {
            throw CLIError.usage("缺少磁盘参数，例如 disk2")
        }
        let target = args[1].hasPrefix("/dev/") ? args[1] : "/dev/\(args[1])"
        let disks = enumerator.listPhysicalDisks()
        guard let disk = disks.first(where: { $0.deviceNode == target }) else {
            let available = disks.map { $0.deviceIdentifier }.joined(separator: ", ")
            throw CLIError.failed("找不到磁盘 \(target)。可用物理磁盘：\(available.isEmpty ? "无" : available)")
        }
        return disk
    }

    private func listDisks() throws {
        let disks = enumerator.listPhysicalDisks()
        guard !disks.isEmpty else {
            print("未检测到物理磁盘。")
            return
        }
        print("DiskDoctor —— 物理磁盘清单")
        print(String(repeating: "=", count: 92))
        print("标识     类型     容量        协议         位置     型号                      序列号")
        print(String(repeating: "-", count: 92))

        for disk in disks {
            let smart = smartReader.read(device: disk.deviceNode)
            let media = classifier.classify(disk: disk, smart: smart)
            let serial = disk.identity.serialNumber ?? disk.identity.usbSerialNumber ?? "-"
            let fields = [
                disk.deviceIdentifier,
                media.kind.shortLabel,
                disk.formattedSize,
                disk.busProtocol ?? "-",
                disk.isInternal ? "内置" : "外置",
                String((disk.modelName ?? "-").prefix(24)),
                serial
            ]
            let widths = [8, 8, 12, 13, 8, 26, 20]
            var line = ""
            for (i, f) in fields.enumerated() {
                line += f.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }
            print(line)
        }
        print(String(repeating: "=", count: 92))
        print("提示：使用 diskdoctor info <diskN> 查看单盘详情")
    }

    private func showInfo(_ disk: DiskDescriptor) throws {
        let smart = smartReader.read(device: disk.deviceNode)
        let media = classifier.classify(disk: disk, smart: smart)

        print("【磁盘概况】")
        print("  设备标识  ：\(disk.deviceIdentifier)  (\(disk.deviceNode))")
        print("  型号      ：\(disk.modelName ?? "未知")")
        print("  容量      ：\(disk.formattedSize)")
        print("  总线协议  ：\(disk.busProtocol ?? "未知")")
        print("  位置      ：\(disk.isInternal ? "内置" : "外置")")
        print("  分区表    ：\(disk.contentType ?? "未知")")
        print("  介质类型  ：\(media.kind.rawValue)（置信度 \(media.confidence.rawValue)）")
        print("")
        print("【介质判定依据】")
        for e in media.evidence {
            print("  · \(e.sourceLabel)：\(e.value) → \(e.implied?.rawValue ?? "不构成判定")")
        }
        print("")
        print("【硬件编码】")
        let entries = disk.identity.entries
        if entries.isEmpty {
            print("  （未读取到）")
        } else {
            for e in entries {
                print("  \(e.label)：\(e.value)")
            }
        }
        print("")
        print("【SMART 状态】")
        print("  总体状态  ：\(smart.health.rawValue)")
        if let t = smart.temperatureCelsius { print("  温度      ：\(t) °C") }
        if let h = smart.powerOnHours { print("  通电时长  ：\(h) 小时") }
        if let nv = smart.nvme {
            if let u = nv.percentageUsed { print("  寿命消耗  ：\(u)%") }
            if let e = nv.mediaErrors { print("  介质错误  ：\(e)") }
        }
        if let e = smart.readError { print("  提示      ：\(e)") }
    }

    private func scanDisk(_ disk: DiskDescriptor) throws {
        let report = engine.analyze(disk: disk)
        print(exporter.textReport(for: report))
    }

    private func listVolumes(_ disk: DiskDescriptor) throws {
        let volumes = partitionManager.listVolumes(of: disk)
        guard !volumes.isEmpty else {
            print("该磁盘没有可列出的卷。")
            return
        }
        print("【\(disk.deviceIdentifier) 的分区与卷】")
        for v in volumes {
            let mark = v.isWholeDisk ? "整盘" : (v.isMounted ? "已挂载" : "未挂载")
            let fs = v.fileSystem ?? "-"
            print("  \(v.deviceIdentifier)  \(v.formattedSize)  \(fs)  \(mark)  \(v.volumeName ?? "")")
            if let mp = v.mountPoint, !mp.isEmpty { print("      挂载点：\(mp)") }
        }
    }

    private func interactivePartition(_ disk: DiskDescriptor) throws {
        print("""
        ⚠️  分区 / 格式化操作会销毁目标磁盘上的全部数据。

        目标磁盘：\(disk.deviceIdentifier)  \(disk.modelName ?? "")  \(disk.formattedSize)
        """)
        let guardResult = partitionManager.currentSafetyGuard()
        if let reason = guardResult.protectionReason(for: disk) {
            print("⛔️  \(reason)")
            return
        }
        print("")
        print("可用分区表方案：")
        for (i, s) in PartitionScheme.allCases.enumerated() {
            print("  [\(i + 1)] \(s.rawValue)")
        }
        print("请输入方案编号（直接回车取消）：", terminator: " ")
        guard let schemeInput = readLine()?.trimmingCharacters(in: .whitespaces), !schemeInput.isEmpty else {
            print("已取消。")
            return
        }
        guard let schemeIndex = Int(schemeInput), schemeIndex >= 1, schemeIndex <= PartitionScheme.allCases.count else {
            throw CLIError.failed("无效的方案编号。")
        }
        let scheme = PartitionScheme.allCases[schemeIndex - 1]

        print("")
        print("可用文件系统：")
        for (i, f) in FileSystemKind.allCases.enumerated() {
            let note = f.note.map { "（\($0)）" } ?? ""
            print("  [\(i + 1)] \(f.rawValue) \(note)")
        }
        print("请输入文件系统编号（直接回车取消）：", terminator: " ")
        guard let fsInput = readLine()?.trimmingCharacters(in: .whitespaces), !fsInput.isEmpty else {
            print("已取消。")
            return
        }
        guard let fsIndex = Int(fsInput), fsIndex >= 1, fsIndex <= FileSystemKind.allCases.count else {
            throw CLIError.failed("无效的文件系统编号。")
        }
        let fs = FileSystemKind.allCases[fsIndex - 1]

        print("请输入卷名：", terminator: " ")
        guard let name = readLine()?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            print("已取消。")
            return
        }

        print("")
        print("即将执行：")
        print("  磁盘    ：\(disk.deviceIdentifier)")
        print("  分区表  ：\(scheme.rawValue)")
        print("  文件系统：\(fs.rawValue)")
        print("  卷名    ：\(name)")
        print("  ⚠️ 全部原有数据将被永久删除！")
        print("")
        print("请输入磁盘标识 \(disk.deviceIdentifier) 以确认执行（其他任何输入均取消）：", terminator: " ")
        guard let confirm = readLine()?.trimmingCharacters(in: .whitespaces) else {
            print("已取消。")
            return
        }
        guard confirm == disk.deviceIdentifier else {
            print("输入不匹配，已取消。")
            return
        }

        print("正在执行（会弹出系统授权窗口，请输入本机密码）...")
        let result = partitionManager.eraseDisk(disk: disk, scheme: scheme, fileSystem: fs, volumeName: name)
        print(result.success ? "✅ \(result.message)" : "❌ \(result.message)")
        if !result.output.isEmpty { print(result.output) }
    }

    private func exportReport(_ disk: DiskDescriptor, path: String?) throws {
        let report = engine.analyze(disk: disk)
        let json = exporter.jsonReport(for: report)
        let target = path ?? ("\(FileManager.default.currentDirectoryPath)/\(disk.deviceIdentifier)-report.json")
        try json.write(to: URL(fileURLWithPath: target), atomically: true, encoding: .utf8)
        print("报告已导出：\(target)")
    }
}

// MARK: - 入口

let cli = CLI()
do {
    try cli.run()
} catch let e as CLIError {
    switch e {
    case .usage(let msg):
        FileHandle.standardError.write(Data("参数错误：\(msg)\n".utf8))
        exit(2)
    case .failed(let msg):
        FileHandle.standardError.write(Data("错误：\(msg)\n".utf8))
        exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("未知错误：\(error.localizedDescription)\n".utf8))
    exit(1)
}
