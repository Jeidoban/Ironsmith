// swift-tools-version: 6.3

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .define("DEBUG", .when(configuration: .debug)),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .swiftLanguageMode(.v5),
]

let package = Package(
    name: "Ironsmith",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(name: "Ironsmith", targets: ["Ironsmith"]),
    ],
    dependencies: [
        .package(url: "https://github.com/huggingface/AnyLanguageModel", from: "0.8.0"),
        .package(url: "https://github.com/mattt/JSONSchema", from: "1.3.1"),
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.5.1"),
        .package(url: "https://github.com/vtourraine/AcknowList", from: "3.4.2"),
    ],
    targets: [
        .executableTarget(
            name: "Ironsmith",
            dependencies: [
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
                .product(name: "JSONSchema", package: "JSONSchema"),
                .product(name: "Supabase", package: "supabase-swift"),
                .product(name: "AcknowList", package: "AcknowList"),
            ],
            path: "Ironsmith",
            exclude: [
                "Info.plist",
                "Resources",
            ],
            sources: [
                "App",
                "Core",
                "Features",
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "IronsmithTests",
            dependencies: [
                "Ironsmith",
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
                .product(name: "Supabase", package: "supabase-swift"),
            ],
            path: "IronsmithTests",
            swiftSettings: swiftSettings
        ),
    ]
)
