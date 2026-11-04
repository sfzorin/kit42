// swift-tools-version:5.9
import PackageDescription

// Suite42: PDF42, DOC42, XLS42, IMG42. Every app shares Kit42 (menus, toolbar, look, localization).
let package = Package(
    name: "Suite42",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Kit42", targets: ["Kit42"]),
        .executable(name: "PDF42", targets: ["PDF42"]),
        .executable(name: "XLS42", targets: ["XLS42"]),
        .executable(name: "DOC42", targets: ["DOC42"]),
        .executable(name: "IMG42", targets: ["IMG42"]),
    ],
    targets: [
        .target(name: "Kit42", path: "Sources/Kit42"),
        .executableTarget(name: "PDF42", dependencies: ["Kit42"], path: "Sources/PDF42"),
        .executableTarget(name: "XLS42", dependencies: ["Kit42"], path: "Sources/XLS42"),
        .executableTarget(name: "DOC42", dependencies: ["Kit42"], path: "Sources/DOC42"),
        .executableTarget(name: "IMG42", dependencies: ["Kit42"], path: "Sources/IMG42"),
    ]
)
