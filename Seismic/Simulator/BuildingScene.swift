import SwiftUI
import SceneKit
import SeismicCore
import SeismicStructures
import SeismicGeo

/// The 3D building twin.
///
/// SceneKit rather than RealityKit, for three reasons: it runs on every device
/// the app supports, it gives direct per-frame control of node transforms
/// (which is exactly what animating a solved displacement history requires),
/// and its camera controls are the ones users already know from every other 3D
/// view on the platform.
///
/// The building is built once as a stack of storey nodes; the simulation then
/// only writes each storey's horizontal offset and colour each frame. Rebuilding
/// geometry per frame would be both slow and pointless — the shape does not
/// change, only where each floor is.
@MainActor
final class BuildingSceneController: ObservableObject {

    enum VisualStyle: String, CaseIterable, Identifiable {
        case realistic, wireframe, driftHeatMap
        var id: String { rawValue }

        var label: String {
            switch self {
            case .realistic: "Materials"
            case .wireframe: "Wireframe"
            case .driftHeatMap: "Drift heat map"
            }
        }

        var systemImage: String {
            switch self {
            case .realistic: "cube.fill"
            case .wireframe: "cube.transparent"
            case .driftHeatMap: "thermometer.medium"
            }
        }
    }

    let scene = SCNScene()
    private(set) var storeyNodes: [SCNNode] = []
    private var buildingRoot = SCNNode()
    private var groundNode: SCNNode?
    private var cameraNode = SCNNode()

    private(set) var building: BuildingModel?
    private(set) var model: ShearBuilding?

    @Published var style: VisualStyle = .realistic {
        didSet { applyStyle() }
    }

    /// Bumped whenever the geometry changes, so the view knows to re-frame.
    ///
    /// Positioning the camera by hand does not survive `allowsCameraControl`:
    /// SceneKit's own camera controller takes over and ignores the transform
    /// that was set. Asking *it* to frame the building is the only thing that
    /// reliably works, and it has to happen from the view, which is the only
    /// place the controller is reachable.
    @Published private(set) var framingToken = 0
    /// Vertical exaggeration of the sway. Real drift is a fraction of a per
    /// cent and would be invisible at true scale, so the app amplifies it and
    /// says so on screen rather than silently lying about the magnitude.
    @Published var displacementExaggeration: Double = 40 {
        didSet { exaggerationChanged() }
    }

    private var storeyHeight: Double = 3.4
    private var footprint: [Coordinate2D] = []

    init() { configureScene() }

    // MARK: Scene setup

    private func configureScene() {
        scene.background.contents = UIColor(Theme.Palette.background)

        // Key light, fill light, and a soft ambient so the massing reads without
        // the scene looking like a product render.
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 780
        key.light?.color = UIColor(white: 1.0, alpha: 1)
        key.light?.castsShadow = true
        key.light?.shadowMode = .deferred
        key.light?.shadowRadius = 8
        key.light?.shadowColor = UIColor(white: 0, alpha: 0.45)
        key.eulerAngles = SCNVector3(-Float.pi / 3.2, Float.pi / 4.5, 0)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 240
        fill.light?.color = UIColor(Theme.Palette.accent)
        fill.eulerAngles = SCNVector3(-Float.pi / 6, -Float.pi / 2.2, 0)
        scene.rootNode.addChildNode(fill)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 240
        ambient.light?.color = UIColor(white: 0.55, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 42
        cameraNode.camera?.zNear = 0.2
        cameraNode.camera?.zFar = 4000
        cameraNode.camera?.wantsHDR = true
        cameraNode.camera?.bloomIntensity = 0.18
        cameraNode.camera?.bloomThreshold = 0.85
        scene.rootNode.addChildNode(cameraNode)

        scene.rootNode.addChildNode(buildingRoot)
    }

    // MARK: Building the geometry

    func build(_ building: BuildingModel, model: ShearBuilding? = nil, animated: Bool = false) {
        self.building = building
        self.model = model ?? ShearBuilding.from(building)
        let solved = self.model!

        buildingRoot.childNodes.forEach { $0.removeFromParentNode() }
        storeyNodes.removeAll()

        storeyHeight = building.height / Double(max(building.storeyCount, 1))
        footprint = building.footprint.isEmpty
            ? BuildingModel.rectangularFootprint(area: building.footprintArea)
            : building.footprint

        addGround(size: max(building.footprintArea.squareRoot() * 6, 60))

        let extents = Polygon.boundingBoxSize(footprint)
        let width = max(extents.width, 4)
        let depth = max(extents.depth, 4)

        for index in 0..<solved.degreesOfFreedom {
            let height = solved.storeys[index].height
            let node = makeStorey(index: index, width: width, depth: depth, height: height)

            // Position by the cumulative height of the storeys below, so a
            // base-isolation layer of 0.6 m does not push the whole tower up by
            // a full storey.
            let base = solved.storeys.prefix(index).reduce(0.0) { $0 + $1.height }
            node.position = SCNVector3(0, Float(base + height / 2), 0)
            buildingRoot.addChildNode(node)
            storeyNodes.append(node)
        }

        applyStyle()
        frameCamera()
        framingToken += 1

        if animated { playConstructionSequence() }
    }

    /// The camera the view must be told to use.
    ///
    /// Without assigning this as the view's `pointOfView`, `allowsCameraControl`
    /// quietly substitutes a camera of its own and auto-frames the entire
    /// scene — including the ground plane, which is far larger than the
    /// building and drags the framing badly off.
    var pointOfView: SCNNode { cameraNode }

    /// What the camera should frame: the building alone. Framing the whole
    /// scene would include the ground plane, which is several times wider and
    /// pushes the building into the distance.
    var framingTargets: [SCNNode] { storeyNodes.isEmpty ? [buildingRoot] : storeyNodes }

    /// Re-applies the computed camera position. Called when the model changes.
    func resetCamera() { frameCamera() }

    private func makeStorey(index: Int, width: Double, depth: Double,
                            height: Double) -> SCNNode {
        // A slab plus a slightly inset body reads as a floor plate and a storey,
        // which is enough to make the massing legible without modelling columns.
        let container = SCNNode()

        let body = SCNBox(width: CGFloat(width), height: CGFloat(height * 0.86),
                          length: CGFloat(depth), chamferRadius: CGFloat(min(width, depth) * 0.015))
        let bodyNode = SCNNode(geometry: body)
        bodyNode.name = "body"
        container.addChildNode(bodyNode)

        let slab = SCNBox(width: CGFloat(width * 1.04), height: CGFloat(height * 0.10),
                          length: CGFloat(depth * 1.04), chamferRadius: 0)
        let slabNode = SCNNode(geometry: slab)
        slabNode.name = "slab"
        slabNode.position = SCNVector3(0, Float(height * 0.46), 0)
        container.addChildNode(slabNode)

        container.name = "storey-\(index + 1)"
        return container
    }

    /// A *finite* ground plane, deliberately not `SCNFloor`.
    ///
    /// `SCNFloor` is infinite, and anything that tries to measure the scene's
    /// bounds — including SceneKit's own automatic camera framing — gets a
    /// meaningless answer from it and puts the camera somewhere useless. A plain
    /// plane sized to the building has the same visual effect and a finite
    /// bounding box.
    private func addGround(size: Double) {
        groundNode?.removeFromParentNode()

        let plane = SCNPlane(width: CGFloat(size), height: CGFloat(size))
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(Theme.Palette.surface)
        material.roughness.contents = 0.95
        material.metalness.contents = 0.0
        material.isDoubleSided = true
        plane.materials = [material]

        let node = SCNNode(geometry: plane)
        node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)   // lay it flat
        node.position = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(node)
        groundNode = node
    }

    private func frameCamera() {
        guard let building else { return }
        let height = Float(building.height)
        let plan = Float(max(building.footprintArea.squareRoot(), 8))

        // Frame the *whole* building with margin, and account for the control
        // panel covering roughly the lower third of the screen — so the aim
        // point sits above centre rather than at mid-height. Framing on height
        // alone leaves a squat, wide building spilling out of both sides.
        let subject = max(height, plan * 1.4)
        let distance = subject * 5.0 + plan

        // Aim a little below mid-height: whatever the camera looks at lands at
        // the centre of the frame, and the collapsed control bar still occupies
        // the bottom of the screen.
        cameraNode.position = SCNVector3(distance * 0.5, height * 0.8 + plan * 0.3,
                                         distance * 0.72)
        cameraNode.look(at: SCNVector3(0, height * 0.38, 0))
    }

    // MARK: Styling

    private func applyStyle() {
        for (index, node) in storeyNodes.enumerated() {
            let fraction = storeyNodes.count > 1
                ? Double(index) / Double(storeyNodes.count - 1) : 0
            for child in node.childNodes {
                guard let geometry = child.geometry else { continue }
                geometry.materials = [material(for: style, fraction: fraction,
                                               isSlab: child.name == "slab")]
            }
        }
    }

    private func material(for style: VisualStyle, fraction: Double, isSlab: Bool) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased

        switch style {
        case .realistic:
            let base = building?.material ?? .reinforcedConcrete
            material.diffuse.contents = UIColor(realisticColor(for: base, isSlab: isSlab))
            material.roughness.contents = base == .steel ? 0.35 : 0.82
            material.metalness.contents = base == .steel ? 0.55 : 0.0

        case .wireframe:
            material.fillMode = .lines
            material.diffuse.contents = UIColor(Theme.Palette.accent.opacity(isSlab ? 1.0 : 0.55))
            material.lightingModel = .constant
            material.isDoubleSided = true

        case .driftHeatMap:
            // Coloured later, per frame, from the actual drift. Start neutral so
            // an un-run simulation does not imply damage.
            material.diffuse.contents = UIColor(DamageStateColors.color(for: 0))
            material.roughness.contents = 0.9
        }
        return material
    }

    private func realisticColor(for material: ConstructionMaterial, isSlab: Bool) -> Color {
        let base: Color = switch material {
        case .reinforcedConcrete: Color(red: 0.62, green: 0.63, blue: 0.65)
        case .steel: Color(red: 0.55, green: 0.60, blue: 0.68)
        case .timber: Color(red: 0.66, green: 0.50, blue: 0.34)
        case .masonry, .unreinforcedMasonry: Color(red: 0.66, green: 0.51, blue: 0.44)
        case .hybrid: Color(red: 0.58, green: 0.60, blue: 0.62)
        case .unknown: Color(red: 0.55, green: 0.57, blue: 0.60)
        }
        return isSlab ? base.opacity(0.85) : base
    }

    // MARK: Animation

    /// Writes one frame of a solved response.
    ///
    /// - Parameters:
    ///   - displacements: horizontal displacement of each floor, metres.
    ///   - drifts: interstorey drift ratio per floor, for colouring.
    func apply(displacements: [Double], drifts: [Double]) {
        guard !storeyNodes.isEmpty else { return }
        let exaggeration = Float(displacementExaggeration)

        for (index, node) in storeyNodes.enumerated() {
            let offset = index < displacements.count ? Float(displacements[index]) : 0
            node.position.x = offset * exaggeration

            if style == .driftHeatMap, index < drifts.count {
                let stateIndex = damageStateIndex(forDrift: abs(drifts[index]))
                let color = UIColor(DamageStateColors.color(for: stateIndex))
                for child in node.childNodes {
                    child.geometry?.firstMaterial?.diffuse.contents = color
                }
            }
        }
    }

    /// Permanently tints a storey that has been damaged, so the damage stays
    /// visible after the shaking stops — as it does in reality.
    func markDamage(_ results: [StoreyResult]) {
        for result in results {
            let index = result.storey - 1
            guard storeyNodes.indices.contains(index) else { continue }
            guard result.damageState != .none else { continue }
            let color = UIColor(DamageStateColors.color(for: result.damageState.rawValue))
            for child in storeyNodes[index].childNodes {
                child.geometry?.firstMaterial?.emission.contents =
                    color.withAlphaComponent(0.35)
            }
        }
    }

    func resetPositions() {
        for node in storeyNodes {
            node.position.x = 0
            for child in node.childNodes {
                child.geometry?.firstMaterial?.emission.contents = UIColor.black
            }
        }
        applyStyle()
    }

    private func damageStateIndex(forDrift drift: Double) -> Int {
        guard let building else { return 0 }
        let thresholds = DriftThresholds.forSystem(building.system, material: building.material)
        return thresholds.state(for: drift).rawValue
    }

    private func exaggerationChanged() {
        // Nothing to do: the next applied frame picks up the new value. Kept
        // explicit so the intent is obvious rather than looking like a missing
        // implementation.
    }

    /// Animates a mode shape, for the "show me how it wants to move" control.
    func animateModeShape(_ mode: ModeShape, amplitude: Double = 0.6) {
        guard !storeyNodes.isEmpty else { return }
        for (index, node) in storeyNodes.enumerated() {
            guard index < mode.shape.count else { continue }
            let offset = Float(mode.shape[index] * amplitude)
            let forward = SCNAction.moveBy(x: CGFloat(offset), y: 0, z: 0,
                                           duration: mode.period / 2)
            forward.timingMode = .easeInEaseOut
            let back = SCNAction.moveBy(x: CGFloat(-offset * 2), y: 0, z: 0,
                                        duration: mode.period)
            back.timingMode = .easeInEaseOut
            let recover = SCNAction.moveBy(x: CGFloat(offset), y: 0, z: 0,
                                           duration: mode.period / 2)
            recover.timingMode = .easeInEaseOut
            node.removeAllActions()
            node.runAction(.repeatForever(.sequence([forward, back, recover])))
        }
    }

    func stopModeAnimation() {
        for node in storeyNodes { node.removeAllActions(); node.position.x = 0 }
    }

    /// The narrated assembly: storeys appear from the ground up.
    ///
    /// This is the moment the import feature earns its keep — watching a real
    /// building assemble itself makes the abstraction concrete.
    func playConstructionSequence(storeyInterval: TimeInterval = 0.09) {
        for (index, node) in storeyNodes.enumerated() {
            node.opacity = 0
            node.scale = SCNVector3(1, 0.01, 1)
            let delay = SCNAction.wait(duration: Double(index) * storeyInterval)
            let appear = SCNAction.group([
                .fadeIn(duration: 0.22),
                .scale(to: 1, duration: 0.26),
            ])
            appear.timingMode = .easeOut
            node.runAction(.sequence([delay, appear]))
        }
    }

    var constructionDuration: TimeInterval {
        Double(storeyNodes.count) * 0.09 + 0.3
    }
}

extension Polygon {
    /// Width and depth of a footprint's bounding box, in metres.
    static func boundingBoxSize(_ points: [Coordinate2D]) -> (width: Double, depth: Double) {
        let box = boundingBox(points)
        return (max(box.max.x - box.min.x, 1), max(box.max.y - box.min.y, 1))
    }
}

// MARK: - SwiftUI wrapper

struct BuildingSceneView: UIViewRepresentable {
    @ObservedObject var controller: BuildingSceneController
    var allowsCameraControl = true

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = controller.scene
        view.pointOfView = controller.pointOfView
        view.allowsCameraControl = allowsCameraControl
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling2X
        view.backgroundColor = UIColor(Theme.Palette.background)
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true

        // Double tap resets the camera — the standard gesture, and the one
        // people try instinctively after spinning a model into a strange angle.
        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        context.coordinator.view = view

        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        view.allowsCameraControl = allowsCameraControl

        guard context.coordinator.lastFramingToken != controller.framingToken else { return }
        context.coordinator.lastFramingToken = controller.framingToken
        controller.resetCamera()
        view.pointOfView = controller.pointOfView
        view.defaultCameraController.pointOfView = controller.pointOfView

    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    @MainActor
    final class Coordinator: NSObject {
        let controller: BuildingSceneController
        weak var view: SCNView?
        var lastFramingToken = -1

        init(controller: BuildingSceneController) { self.controller = controller }

        @objc func handleDoubleTap() {
            guard let view else { return }
            view.defaultCameraController.frameNodes(controller.framingTargets)
            Haptics.shared.play(.selection)
        }
    }
}
