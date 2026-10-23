import Foundation

/// 一块物理磁盘的描述信息。
public struct DiskDescriptor: Codable, Sendable, Identifiable, Hashable {
    public var id: String { deviceIdentifier }

    /// 例如 disk2
    public let deviceIdentifier: String
    /// 例如 /dev/disk2
    public let deviceNode: String
    public var modelName: String?
    public var sizeBytes: Int64
    public var busProtocol: String?
    public var contentType: String?
    public var isInternal: Bool
    public var isExternal: Bool
    public var isEjectable: Bool
    public var isVirtual: Bool
    public var isWholeDisk: Bool
    public var solidState: Bool?
    public var smartStatus: String?
    public var deviceBlockSize: Int?
    public var ioKitMediumType: String?
    /// 硬件编码集合
    public var identity: HardwareIdentity

    public var formattedSize: String {
        ByteFormat.string(fromBytes: sizeBytes)
    }

    public init(deviceIdentifier: String,
                deviceNode: String,
                modelName: String?,
                sizeBytes: Int64,
                busProtocol: String?,
                contentType: String?,
                isInternal: Bool,
                isExternal: Bool,
                isEjectable: Bool,
                isVirtual: Bool,
                isWholeDisk: Bool,
                solidState: Bool?,
                smartStatus: String?,
                deviceBlockSize: Int?,
                ioKitMediumType: String?,
                identity: HardwareIdentity = HardwareIdentity()) {
        self.deviceIdentifier = deviceIdentifier
        self.deviceNode = deviceNode
        self.modelName = modelName
        self.sizeBytes = sizeBytes
        self.busProtocol = busProtocol
        self.contentType = contentType
        self.isInternal = isInternal
        self.isExternal = isExternal
        self.isEjectable = isEjectable
        self.isVirtual = isVirtual
        self.isWholeDisk = isWholeDisk
        self.solidState = solidState
        self.smartStatus = smartStatus
        self.deviceBlockSize = deviceBlockSize
        self.ioKitMediumType = ioKitMediumType
        self.identity = identity
    }
}

/// 硬件编码：序列号、UUID、PCI/USB 标识、固件版本等可追溯标识。
public struct HardwareIdentity: Codable, Sendable, Hashable {
    /// 硬盘厂商序列号（SMART 层，最权威）
    public var serialNumber: String?
    /// Apple 的硬件 UUID（IOPlatformUUID）
    public var hardwareUUID: String?
    /// WWN 世界唯一标识
    public var worldWideName: String?
    /// 厂商标识
    public var vendor: String?
    /// PCI 厂商/子系统 ID
    public var pciVendorSubsystem: String?
    /// USB 厂商 ID
    public var usbVendorID: String?
    /// USB 产品 ID
    public var usbProductID: String?
    /// USB 桥接芯片序列号
    public var usbSerialNumber: String?
    /// 固件版本
    public var firmwareRevision: String?
    /// 设备路径（IOService 路径）
    public var ioServicePath: String?
    /// USB 设备名称
    public var usbProductName: String?

    public init(serialNumber: String? = nil,
                hardwareUUID: String? = nil,
                worldWideName: String? = nil,
                vendor: String? = nil,
                pciVendorSubsystem: String? = nil,
                usbVendorID: String? = nil,
                usbProductID: String? = nil,
                usbSerialNumber: String? = nil,
                firmwareRevision: String? = nil,
                ioServicePath: String? = nil,
                usbProductName: String? = nil) {
        self.serialNumber = serialNumber
        self.hardwareUUID = hardwareUUID
        self.worldWideName = worldWideName
        self.vendor = vendor
        self.pciVendorSubsystem = pciVendorSubsystem
        self.usbVendorID = usbVendorID
        self.usbProductID = usbProductID
        self.usbSerialNumber = usbSerialNumber
        self.firmwareRevision = firmwareRevision
        self.ioServicePath = ioServicePath
        self.usbProductName = usbProductName
    }

    /// 有值的编码条目，用于展示。
    public var entries: [(label: String, value: String)] {
        var out: [(String, String)] = []
        func add(_ label: String, _ value: String?) {
            if let v = value, !v.isEmpty { out.append((label, v)) }
        }
        add("序列号", serialNumber)
        add("硬件 UUID", hardwareUUID)
        add("WWN", worldWideName)
        add("厂商", vendor)
        add("PCI 厂商/子系统", pciVendorSubsystem)
        add("USB VID", usbVendorID)
        add("USB PID", usbProductID)
        add("USB 序列号", usbSerialNumber)
        add("固件版本", firmwareRevision)
        add("USB 设备", usbProductName)
        add("设备路径", ioServicePath)
        return out
    }
}

/// 磁盘枚举器。
public struct DiskEnumerator {
    private let runner: CommandRunner

    public init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner
    }

    /// 枚举所有物理磁盘（排除合成分区容器）。
    ///
    /// `diskutil list -plist` 只提供精简字段，完整信息（含介质类型、SMART 状态、
    /// 硬件编码线索）需逐盘执行 `diskutil info -plist` 获取。
    public func listPhysicalDisks() -> [DiskDescriptor] {
        guard let data = try? runPlist(["list", "-plist"]),
              let root = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any],
              let wholeDisks = root["WholeDisks"] as? [String]
        else { return [] }

        var results: [DiskDescriptor] = []
        for identifier in wholeDisks {
            guard let info = self.info(plistFor: identifier) else { continue }
            // 跳过虚拟磁盘（APFS 容器、虚拟镜像等）
            if (info["VirtualOrPhysical"] as? String) == "Virtual" { continue }
            // 跳过非整盘条目
            if Self.boolValue(info["WholeDisk"]) != true { continue }
            // 跳过 RAID 分片
            if Self.boolValue(info["RAIDSlice"]) == true { continue }

            var descriptor = DiskDescriptor(
                deviceIdentifier: identifier,
                deviceNode: info["DeviceNode"] as? String ?? "/dev/\(identifier)",
                modelName: (info["MediaName"] as? String) ?? (info["IORegistryEntryName"] as? String),
                sizeBytes: (info["Size"] as? NSNumber)?.int64Value ?? 0,
                busProtocol: info["BusProtocol"] as? String,
                contentType: info["Content"] as? String,
                isInternal: Self.boolValue(info["Internal"]) ?? false,
                isExternal: !(Self.boolValue(info["Internal"]) ?? false),
                isEjectable: Self.boolValue(info["Ejectable"]) ?? false,
                isVirtual: false,
                isWholeDisk: true,
                solidState: nil,
                smartStatus: nil,
                deviceBlockSize: nil,
                ioKitMediumType: nil
            )
            descriptor = merge(info: info, into: descriptor)
            let collector = IdentityCollector(runner: runner)
            // IOKit 介质类型（"Solid State" / "Magnetic"）是可靠的介质信号
            if let medium = collector.mediumType(for: descriptor) {
                descriptor.ioKitMediumType = medium
            }
            descriptor.identity = collector.collect(for: descriptor)
            results.append(descriptor)
        }
        return results.sorted { $0.deviceIdentifier < $1.deviceIdentifier }
    }

    /// plist 中的布尔值可能以 Bool 或 NSNumber(0/1) 形式出现，统一转换。
    static func boolValue(_ any: Any?) -> Bool? {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        return nil
    }

    /// 读取单盘 info plist。
    public func info(plistFor identifier: String) -> [String: Any]? {
        guard let data = try? runPlist(["info", "-plist", identifier]),
              let dict = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        // diskutil 成功时不返回 ExitCode；返回则说明失败
        if let code = dict["ExitCode"] as? Int, code != 0 { return nil }
        if dict["DeviceIdentifier"] == nil { return nil }
        return dict
    }

    private func merge(info: [String: Any], into d: DiskDescriptor) -> DiskDescriptor {
        var result = d
        // 型号：MediaName 最准确，其次 IORegistryEntryName
        if let name = info["MediaName"] as? String, !name.isEmpty {
            result.modelName = name
        } else if let name = info["IORegistryEntryName"] as? String, !name.isEmpty {
            result.modelName = name
        }
        if let size = (info["Size"] as? NSNumber)?.int64Value, size > 0 {
            result.sizeBytes = size
        }
        if let proto = info["BusProtocol"] as? String { result.busProtocol = proto }
        if let solid = Self.boolValue(info["SolidState"]) { result.solidState = solid }
        if let status = info["SMARTStatus"] as? String { result.smartStatus = status }
        if let bs = (info["DeviceBlockSize"] as? NSNumber)?.intValue { result.deviceBlockSize = bs }
        if let isInt = Self.boolValue(info["Internal"]) {
            result.isInternal = isInt
            result.isExternal = !isInt
        }
        if let ejectable = Self.boolValue(info["Ejectable"]) { result.isEjectable = ejectable }
        if let content = info["Content"] as? String { result.contentType = content }
        // 中文系统 MediaType 常为“通用”，仅在有实际含义时采纳
        if let media = info["MediaType"] as? String, media != "通用", !media.isEmpty {
            result.ioKitMediumType = result.ioKitMediumType ?? media
        }
        return result
    }

    /// 执行 diskutil 并返回 plist 数据。
    ///
    /// 参数数组的第 0 项是子命令名（不是可执行文件名），可执行文件固定为
    /// `/usr/sbin/diskutil`——不能用相对路径，否则会因 PATH 缺失而失败。
    private func runPlist(_ args: [String]) throws -> Data {
        let r = try runner.run("/usr/sbin/diskutil", args)
        // diskutil 即使成功也可能返回非零退出码，以 stdout 是否含 plist 为准
        guard r.stdout.contains("<?xml"), r.stdout.contains("<plist") else {
            throw CommandRunner.Failure(command: args.joined(separator: " "), result: r)
        }
        return Data(r.stdout.utf8)
    }
}
