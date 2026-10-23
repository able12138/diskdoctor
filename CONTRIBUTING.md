# 贡献指南

感谢关注 DiskDoctor。

## 开发环境

```bash
# 安装 Xcode Command Line Tools
xcode-select --install

# 克隆并初始化
git clone https://github.com/<owner>/diskdoctor.git
cd diskdoctor
./build.sh          # 会自动下载并编译 smartmontools
```

## 目录约定

```
Sources/DiskKit/       核心库 —— 任何可复用逻辑都放这里，不含 UI 依赖
Sources/DiskDoctorCLI/ 命令行入口
Sources/DiskDoctorUI/  SwiftUI 界面
scripts/               构建辅助脚本
```

**原则**：核心库不 import SwiftUI / AppKit。GUI 与 CLI 共用同一套检测逻辑，避免两处实现漂移。

## 代码风格

- Swift 5 语言模式，4 空格缩进
- 公开 API 必须有文档注释（`///`），说明「是什么」与「为什么」而非「怎么做」
- 注释用中文，与现有代码保持一致
- 类型名用 UpperCamelCase，变量与方法用 lowerCamelCase

## 提交前检查

```bash
# 1. 编译无警告
swift build --disable-sandbox -c release

# 2. 命令行冒烟测试（输出应能正常列出本机磁盘）
./dist/diskdoctor list
./dist/diskdoctor scan disk0

# 3. 确认没有把构建产物或敏感信息提交进来
git status --ignored | grep -E "vendor/|\.build/|dist/"
```

## 提交信息

采用 Conventional Commits：

```
feat: 支持 NVMe 温度阈值自定义
fix: 修正 USB 桥接盘介质类型误判
docs: 补充已知限制章节
```

## 报告问题

提交 Issue 时请附上：

1. macOS 版本与机型（`sw_vers` 输出）
2. 磁盘型号与连接方式（内置 SATA / 内置 NVMe / USB 硬盘盒 / 直连）
3. `diskdoctor info diskN` 的完整输出
4. 期望行为与实际行为

> 若涉及 SMART 读取失败，请一并说明硬盘盒型号 —— 多数「读不到 SMART」是桥接芯片的限制，而非工具缺陷。

## 贡献方向

优先级从高到低：

- **磁盘检测准确度**：新的介质判定依据、更多 SMART 属性解读
- **硬件编码完整性**：补充 WWN、USB 拓扑等采集维度
- **分区功能**：多分区自定义布局、非整盘的分区分段调整
- **平台适配**：Apple Silicon 专项验证、macOS 新版本兼容性

## 许可

贡献即表示同意以 GPL-2.0-or-later 许可你的代码。
