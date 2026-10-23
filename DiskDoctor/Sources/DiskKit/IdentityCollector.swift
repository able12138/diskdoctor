import Foundation

/// 通过 IOKit 注册表采集硬件编码。
///
/// macOS 上硬件编码分散在多个来源：
/// - `IOBlockStorageDevice` 的 `Device Characteristics` 字典：厂商、型号、序列号、介质类型；
/// - `IOUSBHostDevice`：USB 桥接芯片的 VID/PID/序列号；
/// - `IOPlatformExpertDevice`：整机硬件 UUID；
/// - SMART 层：硬盘本体序列号（最权威，USB 桥接盘也能读到）。
///
/// 这些来源通过「型号 + 节点类型」交叉匹配到具体磁盘。
public struct IdentityCollector {
    private let runner: CommandRunner

    public init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner
    }

    /// 读取 IOKit 报告的介质类型原文（如 "Solid State" / "Magnetic"）。
    public func mediumType(for disk: DiskDescriptor) -> String? {
        ioRegistryStorageNode(for: disk)?.mediumType
    }

    public func collect(for disk: DiskDescriptor) -> HardwareIdentity {
        var identity = HardwareIdentity()

        // 1) 整机硬件 UUID。
        identity.hardwareUUID = platformUUID()

        // 2) IOKit 存储节点特征。
        let node = ioRegistryStorageNode(for: disk)
        if let node {
            identity.ioServicePath = node.path
            identity.worldWideName = node.properties["WorldWideName"] ?? node.properties["wwn"]
            identity.vendor = node.vendor
            identity.firmwareRevision = node.properties["Product Revision Level"]
                ?? node.properties["Revision"]
                ?? node.properties["Firmware Revision"]
            if identity.serialNumber == nil {
                identity.serialNumber = node.serialNumber
            }
            // USB 节点上的桥接信息
            identity.usbVendorID = node.properties["USB Vendor ID"]
            identity.usbProductID = node.properties["USB Product ID"]
            identity.usbSerialNumber = node.properties["USB Serial Number"]
            identity.usbProductName = node.properties["USB Product Name"]
        }
        // 3) 全局 USB 设备清单兜底：按型号匹配。
        if identity.usbSerialNumber == nil || identity.usbProductName == nil {
            if let usb = usbDevices(), let model = disk.modelName {
                let normalizedModel = model.trimmingCharacters(in: .whitespaces)
                let matches = usb.filter { device in
                    let product = (device["productName"] ?? "").trimmingCharacters(in: .whitespaces)
                    guard !product.isEmpty else { return false }
                    return product.localizedCaseInsensitiveContains(normalizedModel)
                        || normalizedModel.localizedCaseInsensitiveContains(product)
                }
                if let match = matches.first {
                    identity.usbVendorID = identity.usbVendorID ?? match["vendorID"]
                    identity.usbProductID = identity.usbProductID ?? match["productID"]
                    identity.usbSerialNumber = identity.usbSerialNumber ?? match["serial"]
                    identity.usbProductName = identity.usbProductName ?? match["productName"]
                }
            }
        }

        // 4) USB 外置盘的兜底：型号是盘体型号（SNV2S1000G），与硬盘盒型号
        //    （Ugreen Storage Device）不同。此时取「唯一的外置 USB 存储设备」。
        if disk.isExternal && identity.usbSerialNumber == nil {
            if let usb = usbDevices() {
                let storageDevices = usb.filter { device in
                    let name = (device["productName"] ?? "").lowercased()
                    return name.contains("storage")
                        || name.contains("disk")
                        || name.contains("ssd")
                        || name.contains("hdd")
                        || name.contains("device")
                }
                if storageDevices.count == 1, let only = storageDevices.first {
                    identity.usbVendorID = only["vendorID"]
                    identity.usbProductID = only["productID"]
                    identity.usbSerialNumber = only["serial"]
                    identity.usbProductName = only["productName"]
                }
            }
        }

        return identity
    }

    // MARK: - 私有实现

    /// IOKit 存储节点。
    private struct StorageNode {
        let path: String?
        let properties: [String: String]
        let deviceCharacteristics: [String: String]

        subscript(key: String) -> String? {
            properties[key] ?? deviceCharacteristics[key]
        }

        var serialNumber: String? { deviceCharacteristics["Serial Number"] ?? properties["Serial Number"] }
        var vendor: String? { deviceCharacteristics["Vendor Name"] ?? properties["Vendor Name"] }
        /// 介质类型原文，例如 "Solid State"
        var mediumType: String? { deviceCharacteristics["Medium Type"] }
    }

    /// 定位与该磁盘匹配的 IOKit 存储节点。
    private func ioRegistryStorageNode(for disk: DiskDescriptor) -> StorageNode? {
        guard let data = try? runner.run("/usr/sbin/ioreg", ["-r", "-c", "IOBlockStorageDevice", "-l", "-a"]).stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Any]]
        else { return nil }

        // 收集所有候选节点，按型号匹配度择优。
        var candidates: [StorageNode] = []
        for entry in plist {
            var props: [String: String] = [:]
            for (key, value) in entry {
                if let s = value as? String {
                    props[key] = s
                } else if let n = value as? NSNumber {
                    props[key] = n.stringValue
                }
            }
            var chars: [String: String] = [:]
            if let dc = entry["Device Characteristics"] as? [String: Any] {
                for (k, v) in dc {
                    if let s = v as? String { chars[k] = s }
                }
            }
            candidates.append(StorageNode(
                path: entry["IORegistryEntryPath"] as? String,
                properties: props,
                deviceCharacteristics: chars
            ))
        }

        guard let model = disk.modelName?.trimmingCharacters(in: .whitespaces), !model.isEmpty else {
            return candidates.first
        }

        // 优先精确匹配 Product Name
        if let exact = candidates.first(where: {
            ($0.deviceCharacteristics["Product Name"] ?? "").trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare(model) == .orderedSame
        }) {
            return exact
        }
        // 退化到包含匹配
        if let partial = candidates.first(where: {
            let product = ($0.deviceCharacteristics["Product Name"] ?? "").trimmingCharacters(in: .whitespaces)
            return !product.isEmpty && (model.localizedCaseInsensitiveContains(product)
                || product.localizedCaseInsensitiveContains(model))
        }) {
            return partial
        }
        return nil
    }

    /// 全局 USB 设备清单。
    private func usbDevices() -> [[String: String]]? {
        guard let data = try? runner.run("/usr/sbin/ioreg", ["-r", "-c", "IOUSBHostDevice", "-l", "-a"]).stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Any]]
        else { return nil }

        return plist.map { entry in
            var out: [String: String] = [:]
            if let v = entry["idVendor"] as? NSNumber {
                out["vendorID"] = String(format: "0x%04x", v.intValue)
            } else if let v = entry["idVendor"] as? String {
                out["vendorID"] = v
            }
            if let v = entry["idProduct"] as? NSNumber {
                out["productID"] = String(format: "0x%04x", v.intValue)
            } else if let v = entry["idProduct"] as? String {
                out["productID"] = v
            }
            if let v = entry["USB Serial Number"] as? String { out["serial"] = v }
            if let v = entry["USB Product Name"] as? String {
                out["productName"] = v
            } else if let v = entry["USB Vendor Name"] as? String {
                out["productName"] = v
            }
            return out
        }
    }

    /// IOPlatformUUID。
    private func platformUUID() -> String? {
        guard let data = try? runner.run("/usr/sbin/ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"]).stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Any]]
        else { return nil }
        for entry in plist {
            if let uuid = entry["IOPlatformUUID"] as? String { return uuid }
        }
        return nil
    }
}
