// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Dayleaf",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Dayleaf", targets: ["Dayleaf"]),
        // 命令行：在任何终端里查看笔记、日志，并通过运行中的应用写入。
        .executable(name: "sched", targets: ["sched"]),
    ],
    dependencies: [
        // 内置 zsh 窗口的终端模拟器和 PTY；其余部分仍然没有第三方依赖。
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.9.0"),
    ],
    targets: [
        .target(name: "DayleafCore"),
        .executableTarget(name: "Dayleaf", dependencies: ["DayleafCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .target(name: "SchedKit", dependencies: ["DayleafCore"]),
        .executableTarget(name: "sched", dependencies: ["SchedKit"]),
        .testTarget(name: "DayleafCoreTests", dependencies: ["DayleafCore"]),
        .testTarget(name: "SchedKitTests", dependencies: ["SchedKit", "DayleafCore"]),
        .testTarget(name: "DayleafUITests", dependencies: ["Dayleaf", "SchedKit", .product(name: "SwiftTerm", package: "SwiftTerm")])
    ]
)
