// swift-tools-version: 5.8
// Callio iOS SDK: in-app calling, chat and location. `import InCallSDK`, and `import InCallUI` for the
// ready-made SwiftUI screens. WebRTC (the media engine) is pulled in by default; set INCALL_NO_WEBRTC=1 to
// build only the signalling and chat core (used by CI on hosts without the WebRTC binary).
import PackageDescription
import Foundation

let webrtc = ProcessInfo.processInfo.environment["INCALL_NO_WEBRTC"] == nil

let package = Package(
    name: "InCallSDK",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "InCallSDK", targets: ["InCallSDK"]),
        .library(name: "InCallUI", targets: ["InCallUI"]),
    ],
    dependencies: webrtc ? [
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "155.0.0"),
    ] : [],
    targets: [
        .target(name: "InCallSDK",
                dependencies: webrtc ? [.product(name: "WebRTC", package: "WebRTC")] : [],
                path: "ios/Sources/InCallSDK"),
        .target(name: "InCallUI", dependencies: ["InCallSDK"], path: "ios/Sources/InCallUI"),
        .testTarget(name: "InCallSDKTests", dependencies: ["InCallSDK"], path: "ios/Tests/InCallSDKTests"),
        .testTarget(name: "InCallUITests", dependencies: ["InCallUI", "InCallSDK"], path: "ios/Tests/InCallUITests"),
    ]
)
