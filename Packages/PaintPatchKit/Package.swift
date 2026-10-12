// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaintPatchKit",
    platforms: [.iOS("26.0")],
    products: [.library(name: "PaintPatchKit", targets: ["PaintPatchKit"])],
    targets: [
        .target(name: "PaintPatchKit"),
        .testTarget(name: "PaintPatchKitTests", dependencies: ["PaintPatchKit"]),
    ]
)
