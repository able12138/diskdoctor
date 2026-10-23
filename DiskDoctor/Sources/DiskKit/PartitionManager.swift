import Foundation

/// 分区表方案。
public enum PartitionScheme: String, Codable, CaseIterable, Sendable {
    case guid = "GUID (GPT)"
    case mbr = "MBR"
    case apple = "Apple (APFS)"

    public var diskutilValue: String {
        switch self {
        case .guid: return "GPT"
        case .mbr: return "MBR"
        case .apple: return "Apple_APFS"
        }
    }
}

/// 可用文件系统。
public enum FileSystemKind: String, Codable, CaseIterable, Sendable {
    case apfs = "APFS"
    case exfat = "ExFAT"
    case fat32 = "FAT32"
    case hfsPlus = "Mac OS 扩展 (HFS+)"
    case ntfs = "NTFS (只读挂载)"
    case msdos = "MS-DOS (FAT)"

    public var diskutilValue: String {
        switch self {
        case .apfs: return "APFS"
        case .exfat: return "ExFAT"
        case .fat32: return "FAT32"
        case .hfsPlus: return "HFS+"
        case .ntfs: return "NTFS"
        case .msdos: return "MS-DOS"
        }
    }

    /// macOS 原生可写的文件系统。NTFS 在 macOS 上只能读不能写。
    public var isWritableNatively: Bool {
        self != .ntfs
    }

    public var note: String? {
        switch self {
        case .ntfs: return "macOS 原生仅支持读取 NTFS，写入需安装第三方驱动（如 Paragon NTFS、Tuxera）"
        case .msdos: return "FAT 系列单文件上限 4GB，不适合大于 4GB 的文件"
        default: return nil
        }
    }
}

/// 卷/分区信息。
public struct VolumeInfo: Codable, Sendable, Identifiable {
    public var id: String { deviceIdentifier }
    public let deviceIdentifier: String
    public let deviceNode: String
    public let volumeName: String?
    public let fileSystem: String?
    public let sizeBytes: Int64
    public let isMounted: Bool
    public let mountPoint: String?
    public let isWritable: Bool
    public let isWholeDisk: Bool
    public let contentType: String?
    public let protocolType: String?

    public var formattedSize: String { ByteFormat.string(fromBytes: sizeBytes) }
}

/// 分区与格式化操作结果。
public struct PartitionOperationResult: Sendable {
    public let success: Bool
    public let message: String
    public let output: String

    public init(success: Bool, message: String, output: String = "") {
        self.success = success
        self.message = message
        self.output = output
    }
}

/// 危险操作防护策略。
public struct SafetyGuard {
    /// 启动盘标识符（不可操作）
    public let bootVolumeIdentifier: String?
    /// 系统所在物理盘标识符（不可操作）
    public let systemDiskIdentifier: String?

    public init(bootVolumeIdentifier: String?, systemDiskIdentifier: String?) {
        self.bootVolumeIdentifier = bootVolumeIdentifier
        self.systemDiskIdentifier = systemDiskIdentifier
    }

    /// 判断目标盘是否受保护。
    public func protectionReason(for disk: DiskDescriptor) -> String? {
        if disk.deviceIdentifier == systemDiskIdentifier {
            return "该磁盘是当前系统启动所在的物理磁盘（\(disk.deviceIdentifier)），操作会摧毁正在运行的系统，已禁止。"
        }
        if disk.deviceIdentifier == bootVolumeIdentifier {
            return "该磁盘包含当前启动卷，已禁止操作。"
        }
        if disk.isInternal && disk.isWholeDisk {
            return "该磁盘为内置硬盘且承载系统，出于安全考虑已禁止直接操作。"
        }
        return nil
    }
}

/// 分区与格式化管理器。
public struct PartitionManager {
    private let runner: CommandRunner
    private let enumerator: DiskEnumerator

    public init(runner: CommandRunner = CommandRunner(), enumerator: DiskEnumerator? = nil) {
        self.runner = runner
        self.enumerator = enumerator ?? DiskEnumerator(runner: runner)
    }

    // MARK: - 查询

    /// 列出某物理磁盘下的所有卷与分区。
    ///
    /// `diskutil list -plist` 的分区层级信息不完整，故解析 `diskutil list <disk>`
    /// 的文本输出，再逐个补齐挂载点等细节。
    public func listVolumes(of disk: DiskDescriptor) -> [VolumeInfo] {
        let r = (try? runner.run("/usr/sbin/diskutil", ["list", disk.deviceIdentifier])) ?? nil
        guard let output = r?.stdout, !output.isEmpty else { return [] }

        var out: [VolumeInfo] = []
        for line in output.split(separator: "\n") {
            // 形如：   1:       Microsoft Basic Data 备份                    1.0 TB     disk2s1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("0:") || trimmed.hasPrefix("1:") || trimmed.hasPrefix("2:")
                    || trimmed.hasPrefix("3:") || trimmed.hasPrefix("4:") || trimmed.hasPrefix("5:")
                    || trimmed.hasPrefix("6:") || trimmed.hasPrefix("7:") || trimmed.hasPrefix("8:")
                    || trimmed.hasPrefix("9:") else { continue }
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }

            let indexPart = String(trimmed[trimmed.startIndex..<colonIdx])
            let rest = String(trimmed[trimmed.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespaces)

            // 末尾的 IDENTIFIER
            let parts = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let identifier = parts.last, identifier.hasPrefix(disk.deviceIdentifier) else { continue }

            // 倒推 TYPE / NAME / SIZE：用正则从尾部剥离 size 与 identifier
            let head = rest.dropLast(identifier.count).trimmingCharacters(in: .whitespaces)
            let (sizeText, typeAndName) = splitSize(from: head)
            let (type, name) = splitTypeAndName(typeAndName)

            let isWhole = (identifier == disk.deviceIdentifier)
            let contentType = type.isEmpty ? nil : type

            // 补齐挂载点等细节
            let info = enumerator.info(plistFor: identifier)
            let mountPoint = info?["MountPoint"] as? String
            let isMounted = !(mountPoint?.isEmpty ?? true)
            let volumeName = (info?["VolumeName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
            let fileSystem = (info?["FileSystem"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (type.isEmpty ? nil : type)
            let size = (info?["Size"] as? NSNumber)?.int64Value ?? 0

            out.append(VolumeInfo(
                deviceIdentifier: identifier,
                deviceNode: info?["DeviceNode"] as? String ?? "/dev/\(identifier)",
                volumeName: volumeName,
                fileSystem: fileSystem,
                sizeBytes: size,
                isMounted: isMounted,
                mountPoint: mountPoint,
                isWritable: (info?["WritableVolume"] as? Bool) ?? false,
                isWholeDisk: isWhole,
                contentType: contentType,
                protocolType: disk.busProtocol
            ))
        }
        return out
    }

    /// 从行首剥离容量文本，返回 (容量文本, 剩余部分)。
    private func splitSize(from text: String) -> (String, String) {
        // 容量以形如 "1.0 TB" / "500.3 GB" / "314.6 MB" 结尾
        let pattern = #"([0-9]+(?:\.[0-9]+)?\s+(?:B|KB|MB|GB|TB|PB))\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return ("", text) }
        let sizeText = String(text[range])
        let head = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        return (sizeText, head)
    }

    /// 拆分 TYPE 与 NAME。TYPE 由已知类型关键字识别，其余为卷名。
    private func splitTypeAndName(_ text: String) -> (type: String, name: String?) {
        let known = ["GUID_partition_scheme", "EFI", "Apple_APFS", "Apple_HFS", "Apple_CoreStorage",
                     "Microsoft Basic Data", "Apple Free Space", "Apple RAID", "Linux Filesystem",
                     "MBR Partition Scheme", "ZFS", "Microsoft Reserved", "Apple VM"]
        for k in known {
            if text.hasPrefix(k) {
                let rest = String(text.dropFirst(k.count)).trimmingCharacters(in: .whitespaces)
                return (k, rest.isEmpty ? nil : rest)
            }
        }
        return (text.isEmpty ? "" : text, nil)
    }

    /// 构造当前系统的安全防护。
    public func currentSafetyGuard() -> SafetyGuard {
        var bootVolume: String?
        var systemDisk: String?

        // 通过 diskutil info rootVolume 找到启动卷
        if let data = try? runPlist(["info", "-plist", "/"]),
           let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            bootVolume = info["DeviceIdentifier"] as? String
            // APFS 物理存储即系统盘
            if let store = info["APFSPhysicalStore"] as? String {
                systemDisk = store
            }
        }
        // 兜底：bootVolume 形如 disk1s1，其所属整盘为 disk1
        if systemDisk == nil, let bv = bootVolume {
            let stripped = bv.replacingOccurrences(of: "s", with: "")
            let digits = stripped.drop(while: { !$0.isNumber })
            if !digits.isEmpty { systemDisk = "disk\(digits)" }
        }
        return SafetyGuard(bootVolumeIdentifier: bootVolume, systemDiskIdentifier: systemDisk)
    }

    // MARK: - 分区操作

    /// 抹盘并按指定方案创建单一分区。
    ///
    /// - Parameters:
    ///   - disk: 目标物理磁盘
    ///   - scheme: 分区表方案
    ///   - fileSystem: 文件系统
    ///   - volumeName: 卷名
    ///   - requiresPrivilege: 是否需要管理员权限（磁盘操作通常需要）
    public func eraseDisk(disk: DiskDescriptor,
                          scheme: PartitionScheme,
                          fileSystem: FileSystemKind,
                          volumeName: String,
                          requiresPrivilege: Bool = true) -> PartitionOperationResult {
        let guardResult = currentSafetyGuard()
        if let reason = guardResult.protectionReason(for: disk) {
            return PartitionOperationResult(success: false, message: reason)
        }
        if !fileSystem.isWritableNatively {
            return PartitionOperationResult(success: false,
                message: "\(fileSystem.rawValue) 无法在 macOS 上由 diskutil 直接创建。\(fileSystem.note ?? "")")
        }

        let args = [
            "eraseDisk", scheme.diskutilValue, fileSystem.diskutilValue,
            volumeName, disk.deviceNode
        ]
        return executePrivileged(args: args, description: "抹盘并创建 \(scheme.rawValue) / \(fileSystem.rawValue) 卷")
    }

    /// 格式化单个已有分区/卷（不清除其他分区）。
    public func eraseVolume(volume: VolumeInfo,
                            fileSystem: FileSystemKind,
                            volumeName: String?,
                            requiresPrivilege: Bool = true) -> PartitionOperationResult {
        if !fileSystem.isWritableNatively {
            return PartitionOperationResult(success: false,
                message: "\(fileSystem.rawValue) 无法在 macOS 上由 diskutil 直接创建。\(fileSystem.note ?? "")")
        }
        var args = ["eraseVolume", fileSystem.diskutilValue]
        if let volumeName, !volumeName.isEmpty { args.append(volumeName) }
        args.append(volume.deviceNode)
        return executePrivileged(args: args, description: "格式化 \(volume.deviceIdentifier)")
    }

    /// 调整分区大小（仅对最后一个分区之外的分区无效，macOS 限制）。
    public func resizeVolume(volume: VolumeInfo, size: String) -> PartitionOperationResult {
        let args = ["resizeVolume", volume.deviceNode, size]
        return executePrivileged(args: args, description: "调整 \(volume.deviceIdentifier) 容量")
    }

    /// 卸载卷。
    public func unmount(volume: VolumeInfo) -> PartitionOperationResult {
        let r = (try? runner.run("/usr/sbin/diskutil", ["unmount", volume.deviceNode]))
            ?? CommandRunner.Result(status: -1, stdout: "", stderr: "无法执行 diskutil")
        return PartitionOperationResult(success: r.succeeded,
                                        message: r.succeeded ? "已卸载 \(volume.deviceIdentifier)" : "卸载失败",
                                        output: r.combined)
    }

    /// 挂载卷。
    public func mount(volume: VolumeInfo) -> PartitionOperationResult {
        let r = (try? runner.run("/usr/sbin/diskutil", ["mount", volume.deviceNode]))
            ?? CommandRunner.Result(status: -1, stdout: "", stderr: "无法执行 diskutil")
        return PartitionOperationResult(success: r.succeeded,
                                        message: r.succeeded ? "已挂载 \(volume.deviceIdentifier)" : "挂载失败",
                                        output: r.combined)
    }

    /// 文件系统校验（不需要 SMART 也能做）。
    public func verifyVolume(volume: VolumeInfo) -> PartitionOperationResult {
        let r = (try? runner.run("/usr/sbin/diskutil", ["verifyVolume", volume.deviceNode]))
            ?? CommandRunner.Result(status: -1, stdout: "", stderr: "无法执行 diskutil")
        let ok = r.succeeded && !r.combined.lowercased().contains("error")
        return PartitionOperationResult(success: ok,
                                        message: ok ? "文件系统校验通过" : "发现文件系统错误",
                                        output: r.combined)
    }

    /// 修复文件系统。
    public func repairVolume(volume: VolumeInfo) -> PartitionOperationResult {
        let r = (try? runner.run("/usr/sbin/diskutil", ["repairVolume", volume.deviceNode]))
            ?? CommandRunner.Result(status: -1, stdout: "", stderr: "无法执行 diskutil")
        return PartitionOperationResult(success: r.succeeded,
                                        message: r.succeeded ? "文件系统修复完成" : "修复未完全成功",
                                        output: r.combined)
    }

    /// 设定磁盘为从盘（是否加入启动磁盘选择）。
    public func setBootFlag(disk: DiskDescriptor, enabled: Bool) -> PartitionOperationResult {
        let args = enabled ? ["enableBoot"] : ["disableBoot"]
        let r = (try? runner.run("/usr/sbin/diskutil", args + [disk.deviceNode]))
            ?? CommandRunner.Result(status: -1, stdout: "", stderr: "无法执行 diskutil")
        return PartitionOperationResult(success: r.succeeded,
                                        message: r.succeeded ? (enabled ? "已设为启动盘" : "已取消启动盘") : "操作失败",
                                        output: r.combined)
    }

    // MARK: - 私有

    /// 执行需要管理员权限的 diskutil 命令。
    ///
    /// 通过 `osascript` 提权调用，这样用户只需在系统弹窗中输入一次密码。
    private func executePrivileged(args: [String], description: String) -> PartitionOperationResult {
        let script = "/usr/sbin/diskutil " + args.map(shellQuote).joined(separator: " ")

        // 优先走 osascript 提权（用户看到系统认证弹窗）
        let osaScript = "do shell script \"\(script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        if let r = try? runner.run("/usr/bin/osascript", ["-e", osaScript]) {
            if r.succeeded {
                return PartitionOperationResult(success: true, message: "\(description)成功", output: r.stdout)
            }
            // 权限被拒时把错误带回来
            let msg = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.contains("User canceled") || msg.contains("-128") {
                return PartitionOperationResult(success: false, message: "操作已取消（未获得管理员授权）")
            }
            return PartitionOperationResult(success: false, message: "\(description)失败", output: r.combined)
        }

        // 兜底：若当前进程本身有 root，直接执行
        if ProcessInfo.processInfo.environment["USER"] == "root" {
            let r = (try? runner.run("/usr/sbin/diskutil", args))
                ?? CommandRunner.Result(status: -1, stdout: "", stderr: "")
            return PartitionOperationResult(success: r.succeeded,
                                            message: r.succeeded ? "\(description)成功" : "\(description)失败",
                                            output: r.combined)
        }

        return PartitionOperationResult(success: false, message: "无法提权执行磁盘操作")
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func runPlist(_ args: [String]) throws -> Data {
        let r = try runner.run("/usr/sbin/diskutil", args)
        guard r.stdout.contains("<?xml"), r.stdout.contains("<plist") else {
            throw CommandRunner.Failure(command: args.joined(separator: " "), result: r)
        }
        return Data(r.stdout.utf8)
    }
}
