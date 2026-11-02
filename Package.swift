// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "MyTerm",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MyTerm", targets: ["MyTerm"])],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.13.0")],
    targets: [
        .target(name: "CWindCrypto", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-O3"])]),
        .target(name: "WindCore", dependencies: ["CWindCrypto"]),
        .executableTarget(name: "WindAskpass", dependencies: ["WindCore"]),
        .executableTarget(name: "MyTerm", dependencies: ["WindCore", .product(name: "SwiftTerm", package: "SwiftTerm")], path: "Sources/WindNative"),
        .executableTarget(name: "WindNativeChecks", dependencies: ["WindCore", .product(name: "SwiftTerm", package: "SwiftTerm")], path: "Tests/WindCoreTests")
    ]
)
