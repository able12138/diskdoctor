import Foundation

/// 报告导出：生成人类可读文本与结构化 JSON。
public struct ReportExporter {

    public init() {}

    /// 生成文本报告。
    public func textReport(for report: DiagnosticReport) -> String {
        var lines: [String] = []
        let disk = report.disk

        lines.append("DiskDoctor 硬盘检测报告")
        lines.append(String(repeating: "=", count: 46))
        lines.append("生成时间：\(dateString(report.generatedAt))")
        lines.append("")

        lines.append("【磁盘概况】")
        lines.append("  设备标识    ：\(disk.deviceIdentifier)  (\(disk.deviceNode))")
        lines.append("  型号        ：\(disk.modelName ?? "未知")")
        lines.append("  容量        ：\(disk.formattedSize)  (\(disk.sizeBytes) 字节)")
        lines.append("  总线协议    ：\(disk.busProtocol ?? "未知")")
        lines.append("  位置        ：\(disk.isInternal ? "内置" : "外置")\(disk.isEjectable ? " / 可弹出" : "")")
        lines.append("  分区表      ：\(disk.contentType ?? "未知")")
        lines.append("  介质类型    ：\(report.media.kind.rawValue)  （置信度：\(report.media.confidence.rawValue)）")
        lines.append("")

        lines.append("【介质类型判定依据】")
        for e in report.media.evidence {
            let implied = e.implied?.rawValue ?? "不构成判定"
            lines.append("  · \(e.sourceLabel)：\(e.value)  → \(implied)")
        }
        lines.append("")

        lines.append("【硬件编码】")
        let entries = disk.identity.entries
        if entries.isEmpty {
            lines.append("  （未读取到硬件编码）")
        } else {
            for e in entries {
                lines.append("  \(e.label.padding(toLength: max(14, e.label.count * 2), withPad: " ", startingAt: 0))：\(e.value)")
            }
        }
        lines.append("")

        lines.append("【检测结论】")
        lines.append("  总体评级：\(report.overallSeverity.rawValue)")
        lines.append("  \(report.summaryText)")
        lines.append("  正常项 \(report.passCount) 项，异常项 \(report.issueCount) 项")
        lines.append("")

        lines.append("【检测明细】")
        for item in report.items {
            let mark: String
            switch item.severity {
            case .pass: mark = "[√]"
            case .notice: mark = "[!]"
            case .warning: mark = "[×]"
            case .critical: mark = "[!!]"
            case .unknown: mark = "[?]"
            }
            lines.append("  \(mark) \(item.title)：\(item.value)  —— \(item.severity.rawValue)")
            if let r = item.rationale, !r.isEmpty {
                lines.append("       依据：\(r)")
            }
            if let a = item.advice, !a.isEmpty {
                lines.append("       建议：\(a)")
            }
        }
        lines.append("")
        lines.append(String(repeating: "=", count: 46))

        return lines.joined(separator: "\n")
    }

    /// 生成 JSON 报告。
    public func jsonReport(for report: DiagnosticReport) -> String {
        struct Payload: Encodable {
            let generatedAt: Date
            let disk: DiskDescriptor
            let media: MediaClassification
            let smart: SmartReport
            let items: [DiagnosticItem]
        }
        let payload = Payload(
            generatedAt: report.generatedAt,
            disk: report.disk,
            media: report.media,
            smart: report.smart,
            items: report.items
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: date)
    }
}
