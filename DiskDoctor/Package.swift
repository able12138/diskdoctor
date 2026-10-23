// swift-tools-version: 5.9
import PackageDescription

// 注意：产品名与 target 名刻意使用不同的大小写/命名。
// 早期版本用 "DiskDoctor" 同时作为产品名与 CLI 产品名（"diskdoctor"），
// 在 SwiftPM 上仅差大小写会导致产物映射错乱、链接到错误的 main 符号。
let package = Package(
    name: "DiskDoctor",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DiskKit", targets: ["DiskKit"]),
        .executable(name: "diskdoctor-cli", targets: ["DiskDoctorCLI"]),
        .executable(name: "DiskDoctorApp", targets: ["DiskDoctorUI"]),
    ],
    targets: [
        .target(name: "DiskKit"),
        .executableTarget(name: "DiskDoctorCLI", dependencies: ["DiskKit"]),
        .executableTarget(
            name: "DiskDoctorUI",
            dependencies: ["DiskKit"],
            linkerSettings: [.unsafeFlags(["-framework", "IOKit", "-framework", "AppKit"])]
        ),
    ]
)
