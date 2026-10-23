import SwiftUI
import AppKit

/// 应用入口。
///
/// 说明：SwiftUI 的 `WindowGroup` 在 .app bundle 内运行时能正常创建窗口；
/// 而手动创建 NSWindow + NSHostingView 的方式在该环境下窗口不显示。
/// 因此保留 SwiftUI 生命周期，仅用 AppDelegate 负责「窗口呈现完成后触发数据加载」，
/// 避免磁盘枚举（多次外部命令）与窗口首次呈现产生竞争。
@main
struct DiskDoctorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("硬盘体检工具") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("磁盘") {
                Button("刷新磁盘列表") {
                    state.refreshDisks()
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("检测当前磁盘") {
                    if let disk = state.selectedDisk {
                        Task { await state.scan(disk) }
                    }
                }
                .keyboardShortcut("d", modifiers: .command)

                Divider()

                Button("检测全部磁盘") {
                    Task { await state.scanAll() }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}

/// 应用代理：负责启动后的异步初始化。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 延后一拍，确保窗口已完全呈现后再开始加载数据
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NotificationCenter.default.post(name: .diskDoctorReady, object: nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

extension Notification.Name {
    /// 应用就绪、可以开始加载磁盘数据。
    static let diskDoctorReady = Notification.Name("com.workbuddy.diskdoctor.ready")
}
