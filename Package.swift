// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CourseRecorder",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CourseRecorder",
            path: "Sources/CourseRecorder"
        )
    ]
)
