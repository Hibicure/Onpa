// swift-tools-version: 5.9
// Onpa Lab：iPhoneで「通話しながら音楽」を確かめるためのテストアプリ
// Xcodeでこのフォルダ（OnpaLab.swiftpm）を開くと、そのままiPhoneで動かせます。

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "OnpaLab",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "Onpa Lab",
            targets: ["AppModule"],
            bundleIdentifier: "net.onpa.lab",
            teamIdentifier: "",
            displayVersion: "0.1",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .music),
            accentColor: .presetColor(.indigo),
            supportedDeviceFamilies: [
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait
            ],
            capabilities: [
                .microphone(purposeString: "Onpaで通話するためにマイクを使います。"),
                .camera(purposeString: "Onpaはカメラを使いません（通話の部品が必要とするため記載しています）。")
            ]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/livekit/client-sdk-swift.git", "2.5.0"..<"3.0.0")
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            dependencies: [
                .product(name: "LiveKit", package: "client-sdk-swift")
            ],
            path: "."
        )
    ]
)
