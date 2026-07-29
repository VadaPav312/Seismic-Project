// swift-tools-version: 6.0
import PackageDescription

// SeismicKit — every piece of logic that is not a view.
//
// Layered so the dependency graph only ever points downwards:
//
//   Services ──┬── Data ──┬── Device ──┐
//              │          │            ├── Core
//              └── Structures ── Signal┘
//                  Geo ────────────────┘
//
// The app target depends on the whole thing; each module is independently
// testable and none of them import SwiftUI.

// The numeric package is optimised in every configuration.
let numericSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .unsafeFlags(["-O"], .when(configuration: .debug)),
]

let package = Package(
    name: "SeismicKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SeismicKit", targets: [
            "SeismicCore", "SeismicSignal", "SeismicStructures",
            "SeismicGeo", "SeismicDevice", "SeismicData", "SeismicServices",
        ]),
    ],
    targets: [
        // Foundation: units, value types, secrets, logging, small math helpers.
        .target(name: "SeismicCore", swiftSettings: numericSettings),

        // Algorithms 1–34: conditioning, picking, spectra, modal, characterisation.
        .target(name: "SeismicSignal", dependencies: ["SeismicCore"],
                swiftSettings: numericSettings),

        // Algorithms 35–38 plus spatial indexing, clustering and footprint geometry.
        .target(name: "SeismicGeo", dependencies: ["SeismicCore"],
                swiftSettings: numericSettings),

        // Algorithms 39–50: the structural solver, damage states and inference.
        .target(name: "SeismicStructures", dependencies: ["SeismicCore", "SeismicSignal"],
                swiftSettings: numericSettings),

        // BLE protocol, framing, chunk reassembly and the simulated node.
        .target(name: "SeismicDevice", dependencies: ["SeismicCore", "SeismicSignal"],
                swiftSettings: numericSettings),

        // Persistence, the tamper-evident ledger, the sync queue and seed data.
        .target(name: "SeismicData",
                dependencies: ["SeismicCore", "SeismicSignal", "SeismicStructures", "SeismicGeo"],
                resources: [.process("Resources")],
                swiftSettings: numericSettings),

        // Building search and import, the AI analyst, community, reports.
        .target(name: "SeismicServices",
                dependencies: ["SeismicCore", "SeismicData", "SeismicGeo", "SeismicStructures"],
                swiftSettings: numericSettings),

        .testTarget(name: "SeismicCoreTests", dependencies: ["SeismicCore"],
                    swiftSettings: numericSettings),
        .testTarget(name: "SeismicSignalTests", dependencies: ["SeismicSignal"],
                    swiftSettings: numericSettings),
        .testTarget(name: "SeismicGeoTests", dependencies: ["SeismicGeo"],
                    swiftSettings: numericSettings),
        .testTarget(name: "SeismicStructuresTests", dependencies: ["SeismicStructures"],
                    swiftSettings: numericSettings),
        .testTarget(name: "SeismicDeviceTests", dependencies: ["SeismicDevice"],
                    swiftSettings: numericSettings),
        .testTarget(name: "SeismicDataTests", dependencies: ["SeismicData"],
                    swiftSettings: numericSettings),
        .testTarget(name: "SeismicServicesTests", dependencies: ["SeismicServices"],
                    swiftSettings: numericSettings),
    ]
)
