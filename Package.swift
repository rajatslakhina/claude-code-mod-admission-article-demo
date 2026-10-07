// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ModAdmission",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ModAdmission", targets: ["ModAdmission"])
    ],
    targets: [
        .target(name: "ModAdmission"),
        .testTarget(name: "ModAdmissionTests", dependencies: ["ModAdmission"])
    ]
)
