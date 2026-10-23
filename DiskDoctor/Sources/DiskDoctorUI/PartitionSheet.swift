import SwiftUI
import DiskKit

/// 整盘分区 / 格式化向导。
///
/// 三重防护：
/// 1. 系统盘保护（SafetyGuard）；
/// 2. 明确展示将要执行的操作；
/// 3. 必须手动输入磁盘标识确认。
struct PartitionSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss

    let disk: DiskDescriptor

    @State private var scheme: PartitionScheme = .guid
    @State private var fileSystem: FileSystemKind = .exfat
    @State private var volumeName: String = "新卷"
    @State private var confirmationText: String = ""
    @State private var isWorking = false
    @State private var resultMessage: String?
    @State private var resultSucceeded: Bool?

    private var protectionReason: String? {
        state.protectionReason(for: disk)
    }

    private var canExecute: Bool {
        protectionReason == nil
            && !volumeName.trimmingCharacters(in: .whitespaces).isEmpty
            && confirmationText == disk.deviceIdentifier
            && !isWorking
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let reason = protectionReason {
                        warningBox(
                            icon: "hand.raised.fill",
                            title: "此操作已被安全策略禁止",
                            message: reason,
                            color: .red
                        )
                    } else {
                        warningBox(
                            icon: "exclamationmark.triangle.fill",
                            title: "此操作将永久删除目标磁盘上的全部数据",
                            message: "磁盘 \(disk.deviceIdentifier)（\(disk.modelName ?? "未知型号")，\(disk.formattedSize)）上的所有分区与文件都会被销毁，且无法撤销。若其中有需要保留的数据，请立即取消并先完成备份。",
                            color: .orange
                        )
                    }

                    targetCard

                    if protectionReason == nil {
                        schemePicker
                        fileSystemPicker
                        nameField
                        confirmField
                        if let msg = resultMessage {
                            resultBox(msg, succeeded: resultSucceeded ?? false)
                        }
                    }
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 620)
    }

    // MARK: - 组件

    private var header: some View {
        HStack {
            Image(systemName: "wrench.and.screwdriver")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("分区与格式化").font(.headline)
                Text("\(disk.deviceIdentifier)  ·  \(disk.modelName ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
    }

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("目标磁盘").font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("标识").font(.caption).foregroundStyle(.secondary)
                    Text(disk.deviceIdentifier).font(.callout.monospaced())
                }
                GridRow {
                    Text("型号").font(.caption).foregroundStyle(.secondary)
                    Text(disk.modelName ?? "未知").font(.callout)
                }
                GridRow {
                    Text("容量").font(.caption).foregroundStyle(.secondary)
                    Text(disk.formattedSize).font(.callout)
                }
                GridRow {
                    Text("当前分区表").font(.caption).foregroundStyle(.secondary)
                    Text(disk.contentType ?? "未知").font(.callout)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var schemePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("分区表方案").font(.subheadline.weight(.semibold))
            Picker("", selection: $scheme) {
                ForEach(PartitionScheme.allCases, id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.radioGroup)
            Text("GPT 支持 2TB 以上磁盘与 UEFI 启动，是当前推荐方案；MBR 兼容性最好但容量上限 2TB。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var fileSystemPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("文件系统").font(.subheadline.weight(.semibold))
            Picker("", selection: $fileSystem) {
                ForEach(FileSystemKind.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.radioGroup)
            if let note = fileSystem.note {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("卷名称").font(.subheadline.weight(.semibold))
            TextField("新卷", text: $volumeName)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var confirmField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("确认").font(.subheadline.weight(.semibold))
            Text("请输入磁盘标识 \(disk.deviceIdentifier) 以确认执行：")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("", text: $confirmationText)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
            if !confirmationText.isEmpty && confirmationText != disk.deviceIdentifier {
                Text("输入不匹配。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("执行时系统会弹出授权窗口，请输入本机密码。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                execute()
            } label: {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("抹盘并创建分区")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!canExecute)
            .keyboardShortcut(.defaultAction)
        }
        .padding(18)
    }

    private func warningBox(icon: String, title: String, message: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(color)
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private func resultBox(_ msg: String, succeeded: Bool) -> some View {
        Label(msg, systemImage: succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
            .font(.callout)
            .foregroundStyle(succeeded ? .green : .red)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((succeeded ? Color.green : Color.red).opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 7))
    }

    private func execute() {
        isWorking = true
        Task {
            let result = await state.eraseDisk(disk, scheme: scheme, fileSystem: fileSystem, volumeName: volumeName)
            resultSucceeded = result.success
            resultMessage = result.success
                ? "操作成功完成。"
                : (result.output.isEmpty ? result.message : "\(result.message)\n\(result.output)")
            isWorking = false
            if result.success {
                state.loadVolumes(for: disk)
            }
        }
    }
}

/// 单卷格式化表单。
struct EraseVolumeSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss

    let volume: VolumeInfo

    @State private var fileSystem: FileSystemKind = .exfat
    @State private var volumeName: String = ""
    @State private var isWorking = false
    @State private var resultMessage: String?
    @State private var resultSucceeded: Bool?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("格式化卷").font(.headline)
                    Text("\(volume.deviceIdentifier)  ·  \(volume.volumeName ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                warningBox
                VStack(alignment: .leading, spacing: 6) {
                    Text("目标文件系统").font(.subheadline.weight(.semibold))
                    Picker("", selection: $fileSystem) {
                        ForEach(FileSystemKind.allCases, id: \.self) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.menu)
                    if let note = fileSystem.note {
                        Label(note, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("新卷名（留空则沿用原名）").font(.subheadline.weight(.semibold))
                    TextField(volume.volumeName ?? "", text: $volumeName)
                        .textFieldStyle(.roundedBorder)
                }
                if let msg = resultMessage {
                    Label(msg, systemImage: resultSucceeded == true ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.callout)
                        .foregroundStyle(resultSucceeded == true ? .green : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)

            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    execute()
                } label: {
                    if isWorking { ProgressView().controlSize(.small) } else { Text("格式化") }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isWorking)
                .keyboardShortcut(.defaultAction)
            }
            .padding(18)
        }
        .frame(width: 500)
    }

    private var warningBox: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("格式化会清空该卷上的全部文件。其他分区不受影响。")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private func execute() {
        isWorking = true
        Task {
            let result = await state.eraseVolume(
                volume,
                fileSystem: fileSystem,
                volumeName: volumeName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : volumeName
            )
            resultSucceeded = result.success
            resultMessage = result.success
                ? "格式化完成。"
                : (result.output.isEmpty ? result.message : "\(result.message)\n\(result.output)")
            isWorking = false
        }
    }
}
