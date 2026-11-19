// swift-tools-version: 5.10
// Scout: the notch island for your AI agents, in one menu-bar app.
// Built with SwiftPM (no Xcode project). `scripts/build-app.sh` turns the binary into Scout.app.
// The App Store edition (`scripts/build-app.sh … appstore`, which sets SCOUT_APPSTORE=1) leaves SwiftTerm out:
// the sandboxed build has no terminal tabs.
import Foundation
import PackageDescription

let appStore = ProcessInfo.processInfo.environment["SCOUT_APPSTORE"] == "1"

let package = Package(
    name: "Scout",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Scout", targets: ["Scout"]),
    ],
    dependencies: appStore ? [] : [
        // SwiftTerm: the Terminal workspace (MIT). Full edition only.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", .upToNextMinor(from: "1.99.3")),
    ],
    targets: [
        .executableTarget(
            name: "Scout",
            dependencies: appStore ? [] : [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/Scout"
        ),
    ]
)
