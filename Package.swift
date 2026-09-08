// swift-tools-version: 6.2
// LocalNook — a local-first macOS notch utility.
// Copyright (C) 2026 Krish Kowli
// Derived from boring.notch (c) The Boring Team, licensed GPL-3.0-or-later.
// This program is free software under the GNU GPL v3 or later. See LICENSE.

import PackageDescription

let package = Package(
    name: "LocalNook",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "LocalNook", targets: ["LocalNook"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "LocalNook",
            path: "Sources/LocalNook",
            swiftSettings: [
                // The entire app is UI-bound; main-actor-by-default lets us adopt
                // Swift 6 strict concurrency without annotating every type.
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v6),
            ]
        )
    ]
)
