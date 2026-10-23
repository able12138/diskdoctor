# DiskDoctor

**macOS 硬盘检测与分区工具** — 一个工具覆盖硬盘检测的完整链路：介质类型判定 → 健康检测 → 硬件编码 → 分区格式化。

原生 SwiftUI 界面 + 完整命令行支持，零第三方运行时依赖。

```
┌─ 磁盘列表 ──────┬─ 检测详情 ────────────────────────────┐
│ SSD disk0  ✓   │  容量 465.92 GB   协议 PCI-Express      │
│ SSD disk2  ✓   │  介质 固态硬盘    寿命消耗 13%          │
│ SSD disk4  !   │  ┌─ 硬件编码 ──────────────────────┐   │
│                 │  │ 序列号 C02934500AJM5XN1B        │   │
│                 │  │ 固件   1310                    │   │
│                 │  └────────────────────────────────┘   │
│                 │  ┌─ 检测明细 ──────────────────────┐   │
│                 │  │ ✓ SMART 总体状态  通过          │   │
│                 │  │ ✓ 介质与数据完整性错误  0        │   │
│                 │  │ ! 异常断电次数  74              │   │
│                 │  └────────────────────────────────┘   │
└─────────────────┴──────────────────────────────────────┘
```

---

## 特性

### 1. SSD / HDD 自动区分

不依赖单一信号，而是**多源交叉判定**，每条结论都给出依据与置信度：

| 依据来源 | 可靠性 | 说明 |
|---|---|---|
| NVMe 协议 | 最高 | 协议本身即定义在闪存之上，权重加倍 |
| ATA 旋转率 | 最高 | IDENTIFY 设备的 rotation rate，0 = 固态，>0 = RPM |
| IOKit 介质类型 | 高 | `Device Characteristics` 里的 `Medium Type`（Solid State / Magnetic） |
| diskutil 属性 | 中 | `Solid State = Yes/No`，来自系统缓存 |
| 型号启发式 | 兜底 | 厂商与系列关键词，仅在其他信号缺失时使用 |

若 USB 桥接芯片屏蔽了 SMART，工具会明确提示「这是硬盘盒限制，不是硬盘故障」，而不是笼统报「检测失败」。

### 2. 针对性检测项

**固态盘（SSD / NVMe）**

- 寿命消耗（Percentage Used）与预计剩余寿命
- 备用空间与告警阈值（Available Spare）
- 介质与数据完整性错误（Media and Data Integrity Errors）
- 错误日志条目、异常断电次数
- 累计写入量 / 读取量
- 温度、通电时长

**机械盘（HDD）**

- 重映射扇区（坏道主指标，分级提示）
- 待定扇区、不可校正扇区
- 寻道错误率、寻道错误计数
- 硬件 ECC 纠错次数
- 上次自检结果

**通用**

- SMART 总体健康（PASSED / FAILED）
- 工作温度（分档提示：>50℃ 注意、>60℃ 警告、>70℃ 严重）
- 累计通电时长
- 硬件编码完整度

> SATA 接口的固态盘走 ATA 属性表路径，检查重映射 / 待定 / 不可校正扇区。

### 3. 硬件编码采集

从四个来源交叉获取，全部可读时形成完整的设备指纹：

- **硬盘序列号**（SMART 层，最权威，USB 盘也能读到）
- **硬件 UUID**（IOPlatformUUID，整机标识）
- **WWN** 世界唯一标识
- **厂商 / 固件版本**
- **PCI 厂商与子系统 ID**
- **USB VID / PID / 序列号 / 设备名**（硬盘盒芯片信息）
- **设备路径**（IORegistry 完整路径，便于溯源）

### 4. 分区与格式化

- 分区表方案：**GPT**（推荐，支持 2TB 以上与 UEFI 启动）、**MBR**、**Apple APFS**
- 文件系统：**APFS**、**ExFAT**、**FAT32**、**HFS+**、**MS-DOS(FAT)**、**NTFS**（仅可读，macOS 原生不支持写入）
- 单卷格式化（不影响其他分区）、整盘抹盘分区
- 文件系统校验与修复
- 挂载 / 卸载、设为启动盘

### 5. 安全防护

分区与格式化是**不可逆**操作，工具设置了四道防线：

1. **系统盘保护** —— 自动识别当前系统盘与启动卷，直接拒绝操作并说明原因
2. **目标盘锁定** —— 内置盘一律禁止整盘操作
3. **人工确认** —— 必须手动输入磁盘标识（如 `disk2`）才能执行，输入不匹配即取消
4. **系统提权确认** —— 通过 macOS 原生授权弹窗请求管理员密码，不静默提权

格式化单个卷时也需二次确认，且该卷名与分区结构会明确列出。

---

## 安装

### 图形界面版

下载 `DiskDoctor.app` 拖入「应用程序」即可。

> macOS 15 之后，未公证（notarized）的应用首次打开会提示「无法验证开发者」。
> 在「系统设置 → 隐私与安全性」中点击「仍要打开」即可。
> 或使用命令行版（无此限制）。

### 命令行版

```bash
chmod +x diskdoctor
./diskdoctor list
```

---

## 命令行用法

```bash
diskdoctor list                    # 列出全部物理磁盘（自动区分 SSD/HDD）
diskdoctor info <diskN>            # 单盘概况 + 介质判定依据 + 硬件编码
diskdoctor scan <diskN>            # 完整检测报告（文本）
diskdoctor export <diskN> [路径]   # 导出 JSON 报告
diskdoctor volumes <diskN>         # 分区与卷列表
diskdoctor selftest <diskN> [short|long]   # 发起 SMART 自检
diskdoctor selftest-log <diskN>    # 查看 SMART 自检日志
diskdoctor errorlog <diskN>        # 查看 SMART 错误日志
diskdoctor partition <diskN>       # 交互式分区 / 格式化
```

示例输出：

```
$ diskdoctor list
DiskDoctor —— 物理磁盘清单
============================================================================================
标识     类型     容量        协议         位置     型号                      序列号
--------------------------------------------------------------------------------------------
disk0   SSD     465.92 GB   PCI-Express  内置      APPLE SSD AP0512M         C02934500AJM5XN1B
disk2   SSD     931.51 GB   USB          外置      SNV2S1000G                012938052BC0
============================================================================================
```

**快捷键**（图形界面）：`⌘R` 刷新磁盘列表，`⌘D` 检测当前磁盘，`⇧⌘D` 检测全部磁盘。

---

## 从源码构建

### 依赖

- macOS 13 或更高（Intel / Apple Silicon 通用）
- Xcode Command Line Tools：`xcode-select --install`
- Python 3（仅用于生成应用图标）

### 构建

```bash
git clone https://github.com/<owner>/diskdoctor.git
cd diskdoctor
./build.sh
```

脚本会依次完成：

1. 下载并编译 smartmontools（SMART 引擎）
2. 编译 Swift 工程（Release）
3. 组装 `.app` bundle
4. 生成应用图标
5. 输出到 `dist/`

构建产物：

```
dist/DiskDoctor.app      图形界面应用
dist/diskdoctor          命令行版本
```

---

## 技术说明

### 为什么自带 smartmontools

macOS 没有系统自带的 SMART 读取工具。读取真实 SMART 数据必须走 IOKit 通道：

- **ATA/SATA**：`IOATASMARTLib`（`kIOATASMARTUserClientTypeID`）
- **NVMe**：`IONVMeSMARTInterface`（`kIONVMeSMARTUserClientTypeID`）

smartmontools 的 Darwin 后端正是基于这两个接口。本项目从源码自行编译 smartmontools 并随 App 分发（`Contents/Resources/smartmontools/smartctl`），因此**不依赖 Homebrew，也不依赖网络**（构建时除外）。

> smartmontools 遵循 GPL-2.0-or-later，本项目以 GPL-2.0-or-later 发布。

### NVMe 写入量单位换算

NVMe 规范中 1 个 Data Unit = **1000 × 512 字节**（十进制），不是 512 字节。工具按规范换算，与 smartctl 输出口径一致。

### 代码结构

```
DiskDoctor/
├── Package.swift
└── Sources/
    ├── DiskKit/             核心库
    │   ├── CommandRunner.swift       外部命令执行
    │   ├── DiskEnumerator.swift       磁盘枚举（diskutil plist）
    │   ├── IdentityCollector.swift    硬件编码采集（IOKit）
    │   ├── SmartReader.swift          SMART 读取与解析（smartctl JSON）
    │   ├── MediaClassifier.swift      SSD/HDD 多源交叉判定
    │   ├── DiagnosticEngine.swift     差异化检测引擎
    │   ├── PartitionManager.swift     分区与格式化（含安全防护）
    │   ├── ReportExporter.swift       报告导出
    │   └── ByteFormat.swift           字节格式化
    ├── DiskDoctorCLI/       命令行入口
    └── DiskDoctorUI/        SwiftUI 图形界面
```

---

## 已知限制

| 情况 | 原因 | 应对 |
|---|---|---|
| USB 硬盘盒读不到 SMART | 桥接芯片不透传 SAT 命令 | 换用支持 SMART 直通的硬盘盒；或 SATA 直连主板 |
| U 盘无 SMART | U 盘控制器普遍不实现 SMART | 属正常现象，工具会明确标注 |
| macOS 无法写 NTFS | 系统仅支持读取 | 安装 Paragon NTFS / Tuxera |
| 系统盘无法分区格式化 | 出于安全设计 | 工具直接拒绝并说明原因 |

### 关于代码签名

在 macOS 15 上，SwiftUI 应用经 `codesign` 签名后会出现**无法创建可见窗口**的现象——进程存活、主线程事件循环正常，但窗口服务器中查不到任何窗口。实测 `codesign --deep` 与单文件 `codesign` 均能复现，完全不签名则正常。

因此 `build.sh` **主动移除签名**。本地构建的 app 无 quarantine 属性，可直接运行；如需分发给其他机器，请自行评估公证流程。

---

## 免责声明

本工具执行的操作中，**分区与格式化会永久销毁目标磁盘上的全部数据**。虽然工具内置了系统盘保护与人工确认机制，但使用者仍须自行确认目标磁盘正确。误操作造成的数据损失，开发者不承担责任。

本工具读取的 SMART 数据由硬盘固件提供，个别劣质硬盘可能上报不实数据。请勿将检测结果作为唯一的数据安全依据 —— **重要数据请务必保持备份**。

---

## 许可证

GPL-2.0-or-later。详见 [LICENSE](LICENSE)。

Copyright (C) 2026 DiskDoctor contributors
