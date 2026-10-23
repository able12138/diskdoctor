import Foundation

/// 字节格式化工具。
public enum ByteFormat {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.includesUnit = true
        f.isAdaptive = true
        return f
    }()

    public static func string(fromBytes bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        return formatter.string(fromByteCount: bytes)
    }

    public static func string(fromBytes bytes: UInt64) -> String {
        string(fromBytes: Int64(clamping: bytes))
    }

    /// 精确的 TB/GB 表示（1 TB = 10^12 字节，用于厂商标称对比）。
    public static func decimalTB(_ bytes: UInt64) -> String {
        String(format: "%.2f TB", Double(bytes) / 1_000_000_000_000.0)
    }

    /// 小时数 -> 可读时长
    public static func duration(hours: Int) -> String {
        let days = hours / 24
        let months = days / 30
        let years = months / 12
        if years > 0 { return "\(years) 年 \(months % 12) 个月" }
        if months > 0 { return "\(months) 个月 \(days % 30) 天" }
        if days > 0 { return "\(days) 天 \(hours % 24) 小时" }
        return "\(hours) 小时"
    }
}
