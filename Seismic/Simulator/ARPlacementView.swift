import SwiftUI
import SeismicCore
import SeismicStructures
#if canImport(ARKit) && canImport(RealityKit) && !targetEnvironment(simulator)
import ARKit
import RealityKit
#endif

/// The building, standing on the floor in front of you.
///
/// Scale is the point. A 3D view on a phone screen makes a forty-storey tower
/// and a two-storey house look like the same object at different zoom levels;
/// putting them in the room at a stated scale restores the thing a screen takes
/// away. At 1:1 you have to look up, and the sway that reads as a wobble on a
/// screen becomes a metre of movement over your head.
struct ARPlacementView: View {
    let building: BuildingModel

    @Environment(\.dismiss) private var dismiss
    @State private var scaleDenominator: Double = 100
    @State private var isPlaced = false
    @State private var isSwaying = false

    private var scaleOptions: [Double] { [200, 100, 50, 20, 1] }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                #if canImport(ARKit) && canImport(RealityKit) && !targetEnvironment(simulator)
                if ARWorldTrackingConfiguration.isSupported {
                    ARBuildingContainer(building: building,
                                        scale: 1 / scaleDenominator,
                                        isSwaying: isSwaying,
                                        isPlaced: $isPlaced)
                        .ignoresSafeArea()
                } else {
                    unsupported("This device does not have the tracking hardware augmented "
                                + "reality needs.")
                }
                #else
                unsupported("Augmented reality needs a real device — the simulator has no "
                            + "camera to place anything in.")
                #endif

                controls
            }
            .navigationTitle("In the room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    private func unsupported(_ message: String) -> some View {
        DesignedEmptyState(
            icon: "arkit",
            title: "Not available here",
            message: message + " Everything else about this building — the simulator, the "
                   + "resonance sweep, the mode shapes — works exactly the same without it.")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .seismicBackground()
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            HStack {
                Text(scaleDescription)
                    .font(Theme.Typography.numericSmall)
                    .foregroundStyle(Theme.Palette.accent)
                Spacer()
                if isPlaced {
                    Button {
                        isSwaying.toggle()
                        Haptics.shared.play(.selection)
                    } label: {
                        Label(isSwaying ? "Still" : "Sway",
                              systemImage: isSwaying ? "pause.fill" : "waveform")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(scaleOptions, id: \.self) { option in
                        Button {
                            scaleDenominator = option
                            Haptics.shared.play(.selection)
                        } label: {
                            Text(option == 1 ? "True size" : "1:\(Int(option))")
                                .font(Theme.Typography.label)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .background(
                            Capsule().fill(scaleDenominator == option
                                           ? Theme.Palette.accent.opacity(0.22)
                                           : Theme.Palette.surfaceRaised))
                        .foregroundStyle(scaleDenominator == option
                                         ? Theme.Palette.accent : Theme.Palette.textSecondary)
                    }
                }
            }

            Text(isPlaced
                 ? "Walk around it. Pinch to move it further away."
                 : "Point the camera at the floor, then tap to put the building down.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(Theme.Metrics.screenPadding)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusLarge,
                                    style: .continuous))
        .padding(Theme.Metrics.spacing)
    }

    private var scaleDescription: String {
        let modelHeight = building.height / scaleDenominator
        if scaleDenominator == 1 {
            return String(format: "%.0f m tall — full size", building.height)
        }
        return String(format: "1:%.0f — %.2f m tall in the room, %.0f m in reality",
                      scaleDenominator, modelHeight, building.height)
    }
}

#if canImport(ARKit) && canImport(RealityKit) && !targetEnvironment(simulator)

/// The RealityKit half. Kept separate so the SwiftUI file above compiles on
/// every platform, including the simulator, where AR does not exist.
struct ARBuildingContainer: UIViewRepresentable {
    let building: BuildingModel
    let scale: Double
    let isSwaying: Bool
    @Binding var isPlaced: Bool

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        configuration.environmentTexturing = .automatic
        view.session.run(configuration)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.building = building
        // `scale` is deliberately *not* assigned here: `rescale` compares the
        // new value against the stored one to decide whether to rebuild, and
        // assigning first would make that comparison always find them equal.
        context.coordinator.setSwaying(isSwaying)
        context.coordinator.rescale(to: scale)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(building: building, scale: scale,
                    onPlaced: { isPlaced = true })
    }

    final class Coordinator: NSObject {
        weak var view: ARView?
        var building: BuildingModel
        var scale: Double
        private let onPlaced: () -> Void
        private var anchor: AnchorEntity?
        private var storeyEntities: [ModelEntity] = []
        private var modeShape: [Double] = []
        private var period: Double = 1
        private var displayLink: CADisplayLink?
        private var phase: Double = 0

        init(building: BuildingModel, scale: Double, onPlaced: @escaping () -> Void) {
            self.building = building
            self.scale = scale
            self.onPlaced = onPlaced
            super.init()
        }

        @objc @MainActor func handleTap(_ recogniser: UITapGestureRecognizer) {
            guard let view else { return }
            let location = recogniser.location(in: view)
            // Prefer a detected plane; fall back to an estimated one so a tap
            // on a poorly-lit floor still puts the building somewhere sensible
            // rather than doing nothing.
            let hit = view.raycast(from: location, allowing: .existingPlaneGeometry,
                                   alignment: .horizontal).first
                ?? view.raycast(from: location, allowing: .estimatedPlane,
                                alignment: .horizontal).first
            guard let hit else { return }

            if let anchor { view.scene.removeAnchor(anchor) }
            let placed = AnchorEntity(world: hit.worldTransform)
            buildModel(into: placed)
            view.scene.addAnchor(placed)
            anchor = placed
            onPlaced()
            Task { @MainActor in Haptics.shared.play(.actuatorConfirmed) }
        }

        private func buildModel(into anchor: AnchorEntity) {
            storeyEntities.removeAll()

            let model = ShearBuilding.from(building)
            let modes = ModalAnalysis.modes(of: model)
            modeShape = modes.first?.shape ?? Array(repeating: 1, count: building.storeyCount)
            period = modes.first?.period ?? building.empiricalPeriod

            let side = sqrt(max(building.footprintArea, 10))
            let storeyHeight = building.storeyHeight
            let material = SimpleMaterial(color: UIColor(white: 0.75, alpha: 1),
                                          roughness: 0.6, isMetallic: false)
            let edgeMaterial = SimpleMaterial(color: UIColor(red: 0.23, green: 0.78,
                                                             blue: 0.91, alpha: 1),
                                              roughness: 0.3, isMetallic: false)

            for index in 0..<building.storeyCount {
                let mesh = MeshResource.generateBox(
                    size: SIMD3(Float(side * scale),
                                Float(storeyHeight * scale * 0.94),
                                Float(side * scale)),
                    cornerRadius: Float(0.01 * scale * side))
                let entity = ModelEntity(mesh: mesh,
                                         materials: [index == building.storeyCount - 1
                                                     ? edgeMaterial : material])
                entity.position = SIMD3(0,
                                        Float((Double(index) + 0.5) * storeyHeight * scale),
                                        0)
                anchor.addChild(entity)
                storeyEntities.append(entity)
            }

            // A ground pad, so the building reads as standing on something
            // rather than hovering.
            let pad = ModelEntity(
                mesh: .generatePlane(width: Float(side * scale * 2.2),
                                     depth: Float(side * scale * 2.2)),
                materials: [SimpleMaterial(color: UIColor(white: 0.2, alpha: 0.6),
                                           roughness: 1, isMetallic: false)])
            pad.position = SIMD3(0, 0.001, 0)
            anchor.addChild(pad)
        }

        func rescale(to newScale: Double) {
            guard let anchor, abs(newScale - scale) > 1e-9 || storeyEntities.isEmpty else { return }
            scale = newScale
            anchor.children.removeAll()
            buildModel(into: anchor)
        }

        /// Sways at the building's own period, with the real first mode shape —
        /// so the top moves furthest and the base barely at all, exactly as the
        /// eigenvector says it should.
        func setSwaying(_ swaying: Bool) {
            if swaying, displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(step))
                link.add(to: .main, forMode: .common)
                displayLink = link
            } else if !swaying {
                displayLink?.invalidate()
                displayLink = nil
                for entity in storeyEntities {
                    entity.position.x = 0
                }
            }
        }

        @objc private func step(_ link: CADisplayLink) {
            guard period > 0.01 else { return }
            phase += link.duration * 2 * .pi / period
            let side = sqrt(max(building.footprintArea, 10))
            // A tenth of the plan dimension at the roof: large enough to read
            // across a room, small enough to stay believable.
            let amplitude = side * scale * 0.10
            for (index, entity) in storeyEntities.enumerated() {
                let shape = index < modeShape.count ? modeShape[index] : 1
                entity.position.x = Float(sin(phase) * amplitude * shape)
            }
        }

        deinit { displayLink?.invalidate() }
    }
}

#endif
