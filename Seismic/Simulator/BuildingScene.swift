import SwiftUI
import SceneKit
import SeismicCore
import SeismicStructures
import SeismicGeo
import SeismicServices

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

    /// The street around the building. Kept apart from `buildingRoot` because
    /// nothing that happens to these is a result — they are scenery that sways,
    /// not structures under assessment, and they must never be picked up by
    /// anything that walks the storey nodes looking for drift.
    private var streetRoot = SCNNode()
    private var neighbourNodes: [(node: SCNNode, period: Double, height: Double)] = []

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

    /// The view currently rendering this scene, if any. Weak, because the view
    /// belongs to SwiftUI's lifetime and the controller outlives it.
    weak var renderView: SCNView?
    /// Vertical exaggeration of the sway. Real drift is a fraction of a per
    /// cent and would be invisible at true scale, so the app amplifies it and
    /// says so on screen rather than silently lying about the magnitude.
    @Published var displacementExaggeration: Double = 40 {
        didSet { exaggerationChanged() }
    }

    /// Shape of the view currently showing this scene, width over height.
    ///
    /// Reported by the view on layout rather than read from it on demand:
    /// `updateUIView` runs before the view has been laid out, where the bounds
    /// are still zero. Reading them there returned an aspect ratio of exactly 1
    /// for a tall portrait screen and framed it as though it were square.
    private var viewportAspect: Float = 0.6

    func setViewportAspect(_ aspect: Float) {
        guard aspect > 0.01 else { return }
        viewportAspect = aspect
    }

    private var storeyHeight: Double = 3.4
    private var footprint: [Coordinate2D] = []

    /// How this building twists, derived from its plan when it is built.
    ///
    /// Held here so the per-frame path stays arithmetic: the eccentricity and
    /// the torsional radius are properties of the shape and do not change while
    /// the earthquake runs, so computing them once at build time and doing two
    /// multiplications per floor per frame is all the twist costs.
    private(set) var torsion: TorsionModel = .none

    /// The largest twist the view will draw, radians.
    ///
    /// Rotation is exaggerated by the same factor as the sway, because a twist
    /// drawn at true scale is as invisible as a drift of 0.3% — but a large
    /// exaggeration on an already torsionally irregular building would spin the
    /// floors past the point where the picture means anything. Twelve degrees
    /// is about the limit at which a viewer still reads it as one building
    /// rather than a stack of loose plates.
    private let maximumDrawnRotation: Float = 12 * .pi / 180

    init() { configureScene() }

    // MARK: Scene setup

    private func configureScene() {
        scene.background.contents = UIColor(Theme.Palette.background)

        // Key light, fill light, and a soft ambient so the massing reads without
        // the scene looking like a product render.
        // Lit for a dark room.
        //
        // The previous values were tuned looking at a bright screen and were
        // genuinely uncomfortable in the dark — which is the condition this app
        // is most likely to be opened in. A key light at 780 against the near
        // black background is most of a stop brighter than the rest of the
        // interface, and HDR bloom then smeared a halo off every lit edge.
        //
        // Roughly 40% off the key, a much dimmer ambient, and no bloom at all.
        // The massing still reads because the contrast between the lit and
        // shadowed faces is what makes a shape legible, not the absolute level.
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 460
        key.light?.color = UIColor(white: 0.95, alpha: 1)
        key.light?.castsShadow = true
        key.light?.shadowMode = .deferred
        key.light?.shadowRadius = 6
        key.light?.shadowColor = UIColor(white: 0, alpha: 0.42)
        key.eulerAngles = SCNVector3(-Float.pi / 3.2, Float.pi / 4.5, 0)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 130
        // Desaturated: the accent at full strength tinted the whole model, and
        // a cyan building is harder to read as concrete than a grey one.
        fill.light?.color = UIColor(Theme.Palette.accent.opacity(0.55))
        fill.eulerAngles = SCNVector3(-Float.pi / 6, -Float.pi / 2.2, 0)
        scene.rootNode.addChildNode(fill)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 150
        ambient.light?.color = UIColor(white: 0.42, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 42
        cameraNode.camera?.zNear = 0.2
        cameraNode.camera?.zFar = 4000
        // HDR and bloom off: bloom was the glare, and the tone mapping pass it
        // requires is a full-screen GPU cost per frame for an effect that adds
        // nothing to a structural diagram.
        cameraNode.camera?.wantsHDR = false
        cameraNode.camera?.bloomIntensity = 0
        scene.rootNode.addChildNode(cameraNode)

        scene.rootNode.addChildNode(buildingRoot)
        scene.rootNode.addChildNode(streetRoot)
    }

    // MARK: The street

    /// Stands the neighbours up around the building.
    ///
    /// They are drawn as plain extrusions with no storeys, no damage states and
    /// no drift colouring, and that restraint is the point. The eye has to be
    /// able to tell in one glance which building in the scene is the one being
    /// assessed — so exactly one of them is detailed, coloured and instrumented,
    /// and everything else is grey massing. A street of equally rendered
    /// buildings would be prettier and would answer no question at all.
    func setStreet(_ neighbours: [BlockBuilding]) {
        streetRoot.childNodes.forEach { $0.removeFromParentNode() }
        neighbourNodes.removeAll()
        guard !neighbours.isEmpty else { return }

        for neighbour in neighbours {
            let (height, isMeasured) = neighbour.estimatedHeight
            guard height > 1, neighbour.ring.count >= 3 else { continue }

            let centred = neighbour.ring.map {
                Coordinate2D(x: $0.x - neighbour.centre.x, y: $0.y - neighbour.centre.y)
            }
            guard let shape = Self.path(from: centred) else { continue }

            let solid = SCNShape(path: shape, extrusionDepth: CGFloat(height))
            solid.chamferRadius = 0.15

            let material = SCNMaterial()
            // Buildings whose height was mapped are drawn solid; ones where it
            // was assumed are drawn faintly, so a skyline that is partly
            // invented looks partly invented.
            material.diffuse.contents = UIColor(white: isMeasured ? 0.30 : 0.22,
                                                alpha: isMeasured ? 1.0 : 0.72)
            material.roughness.contents = 0.9
            material.metalness.contents = 0.0
            solid.firstMaterial = material

            // SCNShape extrudes along Z, so the whole thing is laid down flat
            // and then the extrusion becomes the vertical axis.
            let pivot = SCNNode(geometry: solid)
            pivot.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
            pivot.position = SCNVector3(0, Float(height / 2), 0)

            // A sway pivot at ground level, so the block leans from its base the
            // way the assessed building does rather than sliding sideways.
            let base = SCNNode()
            base.addChildNode(pivot)
            base.position = SCNVector3(Float(neighbour.centre.x), 0,
                                       Float(-neighbour.centre.y))
            streetRoot.addChildNode(base)
            neighbourNodes.append((node: base, period: neighbour.approximatePeriod,
                                   height: height))
        }
    }

    var hasStreet: Bool { !neighbourNodes.isEmpty }

    // MARK: Photographed damage

    /// Marks the storeys somebody has photographed damage on.
    ///
    /// The point of putting these on the model rather than in a list is that a
    /// list of "storey 2, storey 2, storey 3, storey 7" tells you nothing,
    /// whereas three pins clustered at the base of a building whose first mode
    /// bends hardest at the base is an argument you can see in one glance —
    /// and one pin near the roof of the same building is a question.
    ///
    /// They ride on the storey nodes, so they lean with the building as it
    /// sways rather than hanging in the air beside it.
    func markPhotographedStoreys(_ storeys: Set<Int>) {
        for node in storeyNodes {
            node.childNodes
                .filter { $0.name == Self.damagePinName }
                .forEach { $0.removeFromParentNode() }
        }
        guard !storeys.isEmpty else { return }

        for storey in storeys {
            let index = storey - 1
            guard storeyNodes.indices.contains(index) else { continue }

            let marker = SCNNode(geometry: SCNSphere(radius: 0.55))
            marker.name = Self.damagePinName
            let material = SCNMaterial()
            material.diffuse.contents = UIColor(Theme.Palette.accentSecondary)
            material.emission.contents = UIColor(Theme.Palette.accentSecondary
                                                     .opacity(0.55))
            material.lightingModel = .constant
            marker.geometry?.firstMaterial = material

            // On the outside of the storey, on the corner facing the default
            // camera, so it is not swallowed by the massing.
            let extents = Polygon.boundingBoxSize(footprint)
            marker.position = SCNVector3(Float(extents.width / 2), 0,
                                         Float(extents.depth / 2))
            storeyNodes[index].addChildNode(marker)
        }
    }

    private static let damagePinName = "damage-pin"

    func clearStreet() {
        streetRoot.childNodes.forEach { $0.removeFromParentNode() }
        neighbourNodes.removeAll()
    }

    /// Sways the neighbours for one frame of the simulation.
    ///
    /// Each leans by a single-degree-of-freedom response to the same ground
    /// displacement, at its own period. That is a far cruder model than the
    /// solver runs for the assessed building, and it has to be — nothing is
    /// known about these beyond an outline and a storey count, so a stiffness
    /// matrix for them would be arithmetic performed on invented numbers.
    ///
    /// What it gets right is the thing the picture is for: buildings near the
    /// ground motion's dominant period move a great deal, and their neighbours
    /// two storeys shorter barely move at all. That is resonance, it is the
    /// single most counter-intuitive fact in earthquake engineering, and a
    /// street shows it in one frame where a chart takes a paragraph.
    func swayStreet(groundDisplacement: Double, dominantPeriod: Double) {
        guard !neighbourNodes.isEmpty else { return }
        for entry in neighbourNodes {
            // Amplification from the classic SDOF steady-state expression at 5%
            // damping. Peaks when the building's period matches the shaking.
            let ratio = dominantPeriod > 0 ? entry.period / dominantPeriod : 0
            let damping = 0.05
            let denominator = pow(1 - ratio * ratio, 2) + pow(2 * damping * ratio, 2)
            let amplification = denominator > 1e-6 ? 1 / denominator.squareRoot() : 1
            let tipMetres = groundDisplacement * min(amplification, 6)
                          * displacementExaggeration
            // Converted to a lean about the base, capped so a resonant block
            // does not fold over into its neighbour.
            let angle = atan2(tipMetres, entry.height)
            entry.node.eulerAngles = SCNVector3(0, 0, Float(min(max(angle, -0.22), 0.22)))
        }
    }

    func resetStreet() {
        for entry in neighbourNodes { entry.node.eulerAngles = SCNVector3Zero }
    }

    /// A closed path from a ring of local metres.
    private static func path(from ring: [Coordinate2D]) -> UIBezierPath? {
        guard let first = ring.first, ring.count >= 3 else { return nil }
        let path = UIBezierPath()
        path.move(to: CGPoint(x: first.x, y: first.y))
        for point in ring.dropFirst() {
            path.addLine(to: CGPoint(x: point.x, y: point.y))
        }
        path.close()
        path.flatness = 0.2
        return path
    }

    // MARK: Building the geometry

    func build(_ building: BuildingModel, model: ShearBuilding? = nil, animated: Bool = false) {
        self.building = building
        self.model = model ?? ShearBuilding.from(building)
        let solved = self.model!

        buildingRoot.childNodes.forEach { $0.removeFromParentNode() }
        storeyNodes.removeAll()
        appliedDamageState.removeAll()

        storeyHeight = building.height / Double(max(building.storeyCount, 1))
        footprint = building.footprint.isEmpty
            ? BuildingModel.rectangularFootprint(area: building.footprintArea)
            : building.footprint
        torsion = TorsionModel.of(building)
        cachedRing = nil

        addGround(size: max(building.footprintArea.squareRoot() * 6, 60))

        let extents = Polygon.boundingBoxSize(footprint)
        let width = max(extents.width, 4)
        let depth = max(extents.depth, 4)

        // The massing profile, so a podium is wider than the tower on it and a
        // tapered building actually tapers. A uniform building gives all ones
        // and this changes nothing.
        let planScales = building.massing.scales(storeys: solved.degreesOfFreedom)

        // The plan at each storey's own floor and ceiling, so a storey can be
        // built as the solid between them rather than as a prism of one plan.
        // Sampling only the middle — which is what `scales(storeys:)` gives —
        // is right for the mass but wrong for the surface: it makes every
        // change in plan happen as a step between floors.
        let storeyCount = solved.degreesOfFreedom
        func planScale(atLevel level: Int) -> Double {
            building.massing.scale(at: Double(level) / Double(max(storeyCount, 1)))
        }

        for index in 0..<storeyCount {
            let height = solved.storeys[index].height
            let scale = index < planScales.count ? planScales[index] : 1
            let node = makeStorey(index: index, width: width * scale,
                                  depth: depth * scale, height: height,
                                  planScale: scale,
                                  bottomScale: planScale(atLevel: index),
                                  topScale: planScale(atLevel: index + 1))

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
                            height: Double, planScale: Double = 1,
                            bottomScale: Double = 1, topScale: Double = 1) -> SCNNode {
        // A slab plus a slightly inset body reads as a floor plate and a storey,
        // which is enough to make the massing legible without modelling columns.
        let container = SCNNode()

        // A floor line, not a tray.
        //
        // The slab used to stand 4% proud of the body and the two together
        // covered only 96% of the storey height, so every building came out as
        // a stack of loose plates with air between them — on a 53 m wide base
        // that overhang is more than two metres a side. Real floor slabs are
        // flush with the facade; what you see banding a real tower is the
        // spandrel, which is a line and not a ledge. On a tapered building the
        // overhang was worse than untidy: it turned a smooth slope into a
        // visible staircase.
        // The body spans the storey's own floor to its ceiling; the slab sits
        // at the top and takes the plan it finds there. Interpolating rather
        // than sharing one plan is what stops a curved profile reading as a
        // stack of trays.
        let ceiling = bottomScale + (topScale - bottomScale) * 0.93

        let bodyNode = storeyNode(height: height * 0.93, inset: 0,
                                  width: width, depth: depth, planScale: planScale,
                                  bottomScale: bottomScale, topScale: ceiling)
        bodyNode.name = "body"
        container.addChildNode(bodyNode)

        let slabNode = storeyNode(height: height * 0.07, inset: -0.005,
                                  width: width, depth: depth, planScale: planScale,
                                  bottomScale: ceiling, topScale: topScale)
        slabNode.name = "slab"
        slabNode.position = SCNVector3(0, Float(height * 0.465), 0)
        container.addChildNode(slabNode)

        container.name = "storey-\(index + 1)"
        return container
    }

    /// One storey's solid: the real mapped outline where there is one, a box
    /// where there is not.
    ///
    /// Every imported building used to come out a rectangle. The cause was not
    /// missing data — the Overpass import already fetches the OpenStreetMap
    /// footprint polygon and stores it on the model — but this function, which
    /// took only the polygon's *bounding box* and built an `SCNBox` from it. So
    /// a cruciform tower, an L-shaped block and a circular drum all rendered as
    /// the same slab, and the one genuinely site-specific fact the importer had
    /// gone and found was discarded at the last step.
    ///
    /// Extruding the outline is also structurally honest: torsional response
    /// depends on how mass sits about the centre of rigidity, and a shape the
    /// user can recognise as their own building is the thing that makes the
    /// rest of the model believable.
    private func storeyNode(height: Double, inset: Double,
                            width: Double, depth: Double, planScale: Double = 1,
                            bottomScale: Double = 1, topScale: Double = 1) -> SCNNode {
        let thickness = max(height, 0.01)
        let insetFactor = 1 - inset

        // A lofted solid, so the plan changes across the storey rather than
        // between storeys. `SCNShape` can only extrude one cross-section, which
        // is what turned every curved profile into a ziggurat.
        if let ring = centredRing(), !ring.points.isEmpty,
           let geometry = Loft.solid(ring: ring.points, curved: ring.curved,
                                     bottomScale: bottomScale * insetFactor,
                                     topScale: topScale * insetFactor,
                                     height: thickness) {
            return SCNNode(geometry: geometry)
        }

        let scale = insetFactor * planScale
        let box = SCNBox(width: CGFloat(width * scale), height: CGFloat(thickness),
                         length: CGFloat(depth * scale),
                         chamferRadius: CGFloat(min(width, depth) * 0.015))
        return SCNNode(geometry: box)
    }

    /// The plan centred on its centroid and densified, computed once per build.
    ///
    /// Every storey needs the same ring; flattening the curves and running the
    /// arc detection sixty times over for a sixty-storey tower would be pure
    /// waste.
    private var cachedRing: (points: [Coordinate2D], curved: [Bool])?

    private func centredRing() -> (points: [Coordinate2D], curved: [Bool])? {
        if let cachedRing { return cachedRing }

        let ring = OutlineCurvature.normalised(footprint)
        guard ring.count >= 3 else { return nil }
        let box = Polygon.boundingBox(ring)
        guard box.max.x - box.min.x > 0.5, box.max.y - box.min.y > 0.5 else { return nil }

        // Centred on the centroid, not the bounding box: each storey is this
        // ring scaled, so whatever it is centred on is what the tower stacks
        // about. For a triangle those are ten metres apart and the tower leans.
        let centre = centroid(of: ring)
        let centred = ring.map { Coordinate2D(x: $0.x - centre.x, y: $0.y - centre.y) }

        let densified = Loft.densified(centred)
        guard densified.points.count >= 3 else { return nil }
        cachedRing = densified
        return densified
    }

    /// The footprint as a path centred on the origin, or nil if it is too
    /// degenerate to extrude.
    ///
    /// Centring matters: the polygon arrives in metres relative to the
    /// building's anchor, so an un-centred path would put the tower off to one
    /// side of its own ground plane and out of the camera's framing.
    /// Area centroid of a closed ring, by the shoelace formula.
    ///
    /// Falls back to the bounding-box centre for a degenerate outline, where
    /// the signed area is zero and the centroid is undefined.
    private func centroid(of ring: [Coordinate2D]) -> (x: Double, y: Double) {
        var area = 0.0, x = 0.0, y = 0.0
        for index in ring.indices {
            let a = ring[index], b = ring[(index + 1) % ring.count]
            let cross = a.x * b.y - b.x * a.y
            area += cross
            x += (a.x + b.x) * cross
            y += (a.y + b.y) * cross
        }
        guard abs(area) > 1e-9 else {
            let box = Polygon.boundingBox(ring)
            return ((box.min.x + box.max.x) / 2, (box.min.y + box.max.y) / 2)
        }
        return (x / (3 * area), y / (3 * area))
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

        // A provisional position, in case a fit never arrives. `fitToViewport`
        // supersedes this as soon as the view can report its own shape.
        let plan = Float(max(building.footprintArea.squareRoot(), 8))
        let standoff = max(height, plan) * 3.0

        cameraNode.position = SCNVector3(standoff * 0.42, height * 0.75,
                                         standoff * 0.63)
        cameraNode.look(at: SCNVector3(0, height * 0.45, 0))
    }

    /// Pulls the camera to a distance that fits the building in *this* viewport.
    ///
    /// `frameNodes` keeps the orientation `frameCamera` established and solves
    /// only for distance, against the view's real aspect ratio and field of
    /// view. It fits tightly, so `margin` then backs off along the same axis to
    /// leave room for whatever chrome is drawn over the scene — more on the
    /// simulator, which has a card at the top and a control bar at the bottom,
    /// than in a preview that has neither.
    /// Frames the building for a viewport of a given shape.
    ///
    /// The aspect ratio has to come from the view, because it is the whole
    /// difficulty: the same building sits in a near-square preview and in a
    /// full-bleed portrait screen, and a distance that suits one leaves the
    /// other either spilling off both edges or reduced to a speck. Three
    /// attempts at a viewport-independent constant each got one screen right.
    ///
    /// `frameNodes` looks like the answer — it is SceneKit's own fit — but it
    /// fits tightly with no way to ask for margin, and margin is exactly what a
    /// screen with a card over the top and a control bar across the bottom
    /// needs. Pulling the camera back afterwards does not survive
    /// `allowsCameraControl`. So the distance is solved here instead.
    func fitToViewport(margin: Float) {
        guard let building, viewportAspect > 0.01 else { return }
        let aspectRatio = viewportAspect

        // Measure what was built rather than what was described. The plan is
        // rarely square — this seed's is 2.6:1 — so `sqrt(footprintArea)`
        // understates the long side badly, and the floor slabs overhang on top
        // of that.
        var minimum = SCNVector3Zero
        var maximum = SCNVector3Zero
        buildingRoot.__getBoundingBoxMin(&minimum, max: &maximum)

        let height = Float(building.height)
        let fallback = Float(max(building.footprintArea.squareRoot(), 8))
        let sizeX = maximum.x > minimum.x ? maximum.x - minimum.x : fallback
        let sizeY = maximum.y > minimum.y ? maximum.y - minimum.y : height
        let sizeZ = maximum.z > minimum.z ? maximum.z - minimum.z : fallback
        let centreY = maximum.y > minimum.y ? (minimum.y + maximum.y) / 2 : height / 2

        // Aim at where the building actually is, not at the origin.
        //
        // Each storey is the plan centred on its *centroid*, because that is
        // what the storeys have to stack about — but the centroid of a U or an
        // L is nowhere near the middle of its bounding box, so a camera pointed
        // at the origin puts the long arm of a courtyard block off the side of
        // the screen. For a rectangle or a circle these are the same point and
        // this changes nothing.
        let centreX = maximum.x > minimum.x ? (minimum.x + maximum.x) / 2 : 0
        let centreZ = maximum.z > minimum.z ? (minimum.z + maximum.z) / 2 : 0

        // Fit the bounding sphere. Slightly generous for a long thin plan, since
        // it uses the diagonal, but it holds for every viewing angle — and the
        // camera can be orbited to any of them.
        let radius = (sizeX * sizeX + sizeY * sizeY + sizeZ * sizeZ).squareRoot() / 2

        // The field of view is pinned vertical, so the horizontal one follows
        // from the aspect ratio rather than from SceneKit's automatic choice —
        // which silently switches to whichever dimension is smaller and made
        // the two screens behave differently for no visible reason.
        let vertical = Float(42 * Double.pi / 180)
        let horizontal = 2 * atan(tan(vertical / 2) * aspectRatio)
        let limiting = min(vertical, horizontal)
        let distance = radius / sin(limiting / 2) * margin

        cameraNode.position = SCNVector3(centreX + distance * 0.42, centreY + radius * 0.55,
                                         centreZ + distance * 0.63)
        cameraNode.look(at: SCNVector3(centreX, centreY, centreZ))
    }

    // MARK: Styling

    private func applyStyle() {
        appliedDamageState.removeAll()
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
        // The storeys are lofted solids built here rather than extruded by
        // SceneKit, so the triangle winding is this code's responsibility. It
        // is normalised when the mesh is built; this makes a residual
        // disagreement invisible rather than a hole in the side of a building.
        // Nothing inside a storey is ever seen, so the cost is a few hidden
        // faces that would have been culled.
        material.isDoubleSided = true

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
            let offset = index < displacements.count ? displacements[index] : 0

            // A floor plate is rigid, so it does not merely slide: it slides,
            // crabs sideways, and rotates, all fixed by the same storey shear.
            // Writing only the first of those was drawing a building that
            // cannot exist — every real plan with any asymmetry in it twists,
            // and the twist is what the corners feel.
            let motion = torsion.motion(forDisplacement: offset)
            node.position.x = Float(motion.along) * exaggeration
            node.position.z = Float(motion.across) * exaggeration
            node.eulerAngles.y = min(max(Float(motion.rotation) * exaggeration,
                                         -maximumDrawnRotation), maximumDrawnRotation)

            guard style == .driftHeatMap, index < drifts.count else { continue }

            // Only touch the material when the damage state actually changes.
            //
            // This previously rebuilt a UIColor and reassigned `diffuse.contents`
            // for every child of every storey on every frame. Writing to a
            // material invalidates it and forces SceneKit to re-upload it to the
            // GPU, so a sixty-storey tower was pushing thousands of pointless
            // material updates a second. The state is one of five values and
            // changes a handful of times in an entire event.
            let stateIndex = damageStateIndex(forDrift: abs(drifts[index]))
            guard appliedDamageState[index] != stateIndex else { continue }
            appliedDamageState[index] = stateIndex

            let color = UIColor(DamageStateColors.color(for: stateIndex))
            for child in node.childNodes {
                child.geometry?.firstMaterial?.diffuse.contents = color
            }
        }
    }

    /// The damage state currently written into each storey's material, so a
    /// frame that changes nothing costs nothing.
    private var appliedDamageState: [Int: Int] = [:]

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
            node.position.z = 0
            node.eulerAngles.y = 0
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
            let displacement = mode.shape[index] * amplitude
            let offset = Float(displacement)
            // The same twist the solved response gets. A mode shape animated as
            // pure translation shows a building that only leans, which for an
            // irregular plan is the wrong picture of its own first mode.
            let across = CGFloat(displacement * torsion.crossAxisRatio)
            let spin = CGFloat(min(max(torsion.rotation(forDisplacement: displacement),
                                       Double(-maximumDrawnRotation)),
                                   Double(maximumDrawnRotation)))

            func leg(_ scale: CGFloat, _ duration: TimeInterval) -> SCNAction {
                let action = SCNAction.group([
                    .moveBy(x: CGFloat(offset) * scale, y: 0, z: across * scale,
                            duration: duration),
                    .rotateBy(x: 0, y: spin * scale, z: 0, duration: duration),
                ])
                action.timingMode = .easeInEaseOut
                return action
            }

            node.removeAllActions()
            node.runAction(.repeatForever(.sequence([
                leg(1, mode.period / 2),
                leg(-2, mode.period),
                leg(1, mode.period / 2),
            ])))
        }
    }

    func stopModeAnimation() {
        for node in storeyNodes {
            node.removeAllActions()
            node.position.x = 0
            node.position.z = 0
            node.eulerAngles.y = 0
        }
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
    /// How much room to leave around the building, over a tight fit. The default
    /// suits a full screen with a card over the top of it and a control bar
    /// across the bottom; a plain preview wants less.
    var framingMargin: Float = 1.35

    /// Reports its own shape when the layout system settles it.
    ///
    /// The only reliable moment to learn a view's aspect ratio: by the time
    /// `updateUIView` runs, SwiftUI has not yet given the view a size.
    final class FramingView: SCNView {
        var onResize: ((CGSize) -> Void)?
        private var lastSize: CGSize = .zero

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.width > 1, bounds.height > 1, bounds.size != lastSize else { return }
            lastSize = bounds.size
            onResize?(bounds.size)
        }
    }

    func makeUIView(context: Context) -> SCNView {
        let view = FramingView()
        // Captured by value: the margin is a property of this view, not of the
        // controller, because several screens share one controller shape but not
        // one amount of chrome over it.
        let controller = controller
        let margin = framingMargin
        view.onResize = { size in
            MainActor.assumeIsolated {
                controller.setViewportAspect(Float(size.width / size.height))
                controller.fitToViewport(margin: margin)
            }
        }
        view.scene = controller.scene
        view.pointOfView = controller.pointOfView
        view.allowsCameraControl = allowsCameraControl
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling2X
        view.backgroundColor = UIColor(Theme.Palette.background)

        // 30 fps, and only while something is moving.
        //
        // `rendersContinuously = true` makes SceneKit redraw the scene forever
        // at the full frame rate whether or not a single pixel has changed —
        // so a stationary building was costing a full GPU pass sixty times a
        // second, warming the phone and starving the rest of the interface.
        // SceneKit already redraws on demand when a node moves or a gesture
        // arrives, so the continuous mode buys nothing here.
        //
        // A structural response at 30 fps is indistinguishable from 60: the
        // motion being shown has a period near a second.
        view.preferredFramesPerSecond = 30
        view.rendersContinuously = false

        // Double tap resets the camera — the standard gesture, and the one
        // people try instinctively after spinning a model into a strange angle.
        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        context.coordinator.view = view
        // Held weakly so still and clip export can capture the rendered frames
        // directly, without the surrounding interface in them.
        controller.renderView = view

        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        view.allowsCameraControl = allowsCameraControl

        guard context.coordinator.lastFramingToken != controller.framingToken else { return }
        context.coordinator.lastFramingToken = controller.framingToken
        controller.resetCamera()
        view.pointOfView = controller.pointOfView
        view.defaultCameraController.pointOfView = controller.pointOfView
        // After the point of view is in place, not before: `frameNodes` solves
        // for the camera it has been given.
        if view.bounds.width > 1, view.bounds.height > 1 {
            controller.setViewportAspect(Float(view.bounds.width / view.bounds.height))
        }
        controller.fitToViewport(margin: framingMargin)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, margin: framingMargin)
    }

    @MainActor
    final class Coordinator: NSObject {
        let controller: BuildingSceneController
        weak var view: SCNView?
        var lastFramingToken = -1
        var margin: Float

        init(controller: BuildingSceneController, margin: Float) {
            self.controller = controller
            self.margin = margin
        }

        @objc func handleDoubleTap() {
            guard let view else { return }
            controller.resetCamera()
            controller.fitToViewport(margin: margin)
            view.pointOfView = controller.pointOfView
            view.defaultCameraController.pointOfView = controller.pointOfView
            Haptics.shared.play(.selection)
        }
    }
}
