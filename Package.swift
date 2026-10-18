// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MunbynEasyPrint",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MunbynEasyPrint", targets: ["MunbynEasyPrint"]),
    ],
    targets: [
        // Pure encoding / decoding: LZO, TSPL, rasterizing, IPP wire format.
        .target(name: "PrintCore"),
        // The menu bar app: IPP server, CUPS queue, IOBluetooth transport, UI.
        .executableTarget(name: "MunbynEasyPrint", dependencies: ["PrintCore"]),
        .testTarget(name: "PrintCoreTests", dependencies: ["PrintCore"]),
    ]
)
