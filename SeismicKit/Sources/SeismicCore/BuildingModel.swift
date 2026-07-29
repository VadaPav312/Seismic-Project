import Foundation

// MARK: - Structural taxonomy

public enum ConstructionMaterial: String, Codable, CaseIterable, Sendable {
    case reinforcedConcrete, steel, timber, masonry, unreinforcedMasonry, hybrid, unknown

    public var label: String {
        switch self {
        case .reinforcedConcrete: "Reinforced concrete"
        case .steel: "Steel"
        case .timber: "Timber"
        case .masonry: "Reinforced masonry"
        case .unreinforcedMasonry: "Unreinforced masonry"
        case .hybrid: "Hybrid"
        case .unknown: "Unknown"
        }
    }

    /// Typical mass density per unit floor area, kg/m². Used to estimate storey
    /// mass when nothing better is known; always shown to the user as an
    /// assumption rather than a measurement.
    public var floorMassPerArea: Double {
        switch self {
        case .reinforcedConcrete: 1100
        case .steel: 700
        case .timber: 400
        case .masonry: 950
        case .unreinforcedMasonry: 1000
        case .hybrid: 850
        case .unknown: 900
        }
    }

    /// Fraction of critical damping typical for this material at low amplitude.
    public var typicalDamping: Double {
        switch self {
        case .reinforcedConcrete: 0.05
        case .steel: 0.02
        case .timber: 0.07
        case .masonry: 0.06
        case .unreinforcedMasonry: 0.08
        case .hybrid: 0.045
        case .unknown: 0.05
        }
    }
}

public enum StructuralSystem: String, Codable, CaseIterable, Sendable {
    case momentFrame, shearWall, bracedFrame, dualSystem, baseIsolated
    case softStorey, bearingWall, unknown

    public var label: String {
        switch self {
        case .momentFrame: "Moment-resisting frame"
        case .shearWall: "Shear wall"
        case .bracedFrame: "Braced frame"
        case .dualSystem: "Dual system"
        case .baseIsolated: "Base isolated"
        case .softStorey: "Soft storey (open ground floor)"
        case .bearingWall: "Bearing wall"
        case .unknown: "Unknown"
        }
    }

    /// Ductility class, as a displacement ductility capacity. Drives how much
    /// the structure can deform before the damage model calls it a loss.
    public var ductility: Double {
        switch self {
        case .momentFrame: 4.0
        case .shearWall: 2.5
        case .bracedFrame: 3.0
        case .dualSystem: 3.5
        case .baseIsolated: 1.5      // the isolators take the demand, not the frame
        case .softStorey: 1.6
        case .bearingWall: 1.8
        case .unknown: 2.5
        }
    }
}

public enum FoundationType: String, Codable, CaseIterable, Sendable {
    case shallowSpread, matSlab, piled, caisson, unknown
    public var label: String {
        switch self {
        case .shallowSpread: "Shallow spread footings"
        case .matSlab: "Mat / raft slab"
        case .piled: "Piled"
        case .caisson: "Caisson"
        case .unknown: "Unknown"
        }
    }
}

/// NEHRP-style site class. Soft soil amplifies long-period motion, which is
/// exactly the band a tall building lives in — the single most important
/// non-structural fact about a site.
public enum SoilClass: String, Codable, CaseIterable, Sendable {
    case rock = "A", stiffRock = "B", denseSoil = "C", stiffSoil = "D", softSoil = "E"

    public var label: String {
        switch self {
        case .rock: "A — Hard rock"
        case .stiffRock: "B — Rock"
        case .denseSoil: "C — Dense soil / soft rock"
        case .stiffSoil: "D — Stiff soil"
        case .softSoil: "E — Soft clay"
        }
    }

    /// Broad-band amplification applied to input ground motion.
    public var amplification: Double {
        switch self {
        case .rock: 0.9
        case .stiffRock: 1.0
        case .denseSoil: 1.2
        case .stiffSoil: 1.5
        case .softSoil: 2.1
        }
    }

    /// Period at which that amplification peaks, seconds. Soft sites ring slowly.
    public var resonantPeriod: Double {
        switch self {
        case .rock: 0.15
        case .stiffRock: 0.2
        case .denseSoil: 0.35
        case .stiffSoil: 0.6
        case .softSoil: 1.1
        }
    }
}

public enum RetrofitLevel: String, Codable, CaseIterable, Sendable {
    case none, partial, full, baseIsolationRetrofit
    public var label: String {
        switch self {
        case .none: "None"
        case .partial: "Partial"
        case .full: "Full seismic retrofit"
        case .baseIsolationRetrofit: "Base isolation retrofit"
        }
    }
    /// Multiplier on lateral stiffness relative to the un-retrofitted building.
    public var stiffnessFactor: Double {
        switch self {
        case .none: 1.0
        case .partial: 1.25
        case .full: 1.6
        case .baseIsolationRetrofit: 0.45   // deliberately softer, and far more damped
        }
    }
}

// MARK: - Provenance

/// Where a fact came from and how much to trust it. Every imported attribute
/// carries one of these so the UI can show a source beside a number, and so a
/// user correction can outrank a scraped guess.
public struct FactProvenance: Codable, Sendable, Hashable {
    public enum Source: String, Codable, Sendable {
        case wikidata, openStreetMap, googlePlaces, webSearch, aiInference
        case userEntered, photogrammetry, measured, defaultAssumption

        public var label: String {
            switch self {
            case .wikidata: "Wikidata"
            case .openStreetMap: "OpenStreetMap"
            case .googlePlaces: "Google Places"
            case .webSearch: "Web search"
            case .aiInference: "AI inference"
            case .userEntered: "Entered by you"
            case .photogrammetry: "Photo measurement"
            case .measured: "Measured by sensor"
            case .defaultAssumption: "Standard assumption"
            }
        }

        /// Base trust before any corroboration.
        public var baseConfidence: Double {
            switch self {
            case .measured: 0.97
            case .userEntered: 0.95
            case .wikidata: 0.88
            case .openStreetMap: 0.80
            case .googlePlaces: 0.78
            case .photogrammetry: 0.70
            case .webSearch: 0.62
            case .aiInference: 0.50
            case .defaultAssumption: 0.35
            }
        }
    }

    public var source: Source
    public var confidence: Double
    public var detail: String?
    public var retrievedAt: Date?

    public init(source: Source, confidence: Double? = nil,
                detail: String? = nil, retrievedAt: Date? = nil) {
        self.source = source
        self.confidence = confidence ?? source.baseConfidence
        self.detail = detail
        self.retrievedAt = retrievedAt
    }

    /// A number we inferred is never allowed to look like a number we know.
    public var isConfirmed: Bool {
        switch source {
        case .measured, .userEntered, .wikidata: true
        default: false
        }
    }
}

// MARK: - Storeys

/// One lumped mass and the lateral spring below it. The structural solver never
/// sees anything more detailed than this, which is exactly right for the
/// question being asked: how does the whole building sway?
public struct Storey: Codable, Sendable, Equatable, Identifiable {
    public var id: Int                  // 1 = lowest occupied storey
    public var height: Double           // metres, floor to floor
    public var mass: Double             // kg
    public var stiffness: Double        // N/m, lateral
    public var floorArea: Double        // m²

    public init(id: Int, height: Double, mass: Double, stiffness: Double, floorArea: Double) {
        self.id = id; self.height = height; self.mass = mass
        self.stiffness = stiffness; self.floorArea = floorArea
    }
}

// MARK: - Building

public struct BuildingModel: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var address: String
    public var latitude: Double
    public var longitude: Double

    public var storeyCount: Int
    public var height: Double                 // metres, above grade
    public var footprintArea: Double          // m²
    public var footprint: [Coordinate2D]      // local metres, closed polygon, for extrusion

    /// How the plan changes with height: podium, setback, taper, or uniform.
    ///
    /// Not decoration. The modal analysis integrates mass up the height, and a
    /// podium puts a large fraction of a building's mass in its bottom few
    /// storeys — the case where a uniform prism gets the period wrong rather
    /// than merely looking wrong.
    public var massing: Massing = .uniform
    public var yearBuilt: Int?
    public var material: ConstructionMaterial
    public var system: StructuralSystem
    public var foundation: FoundationType
    public var soil: SoilClass
    public var retrofit: RetrofitLevel
    public var architect: String?
    public var notes: String
    public var notableEvents: [String]

    /// Fraction of critical damping, first mode.
    public var damping: Double

    /// Keyed by the field it describes ("height", "yearBuilt", …).
    public var provenance: [String: FactProvenance]

    public var privacy: PrivacyLevel
    public var pairedNodeID: String?
    public var isSandbox: Bool
    public var createdAt: Date
    public var thumbnailSystemImage: String

    public enum PrivacyLevel: String, Codable, CaseIterable, Sendable {
        case privateOnly, household, approximate, exact
        public var label: String {
            switch self {
            case .privateOnly: "Private"
            case .household: "Household only"
            case .approximate: "Approximate location"
            case .exact: "Exact location"
            }
        }
        public var explanation: String {
            switch self {
            case .privateOnly: "Never leaves this device unless you sync it."
            case .household: "Visible to people in your household, nobody else."
            case .approximate: "Shown on the community map, offset to block level. No address, no name."
            case .exact: "Shown on the community map at its true position, with the name you gave it."
            }
        }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        address: String = "",
        latitude: Double = 0,
        longitude: Double = 0,
        storeyCount: Int,
        height: Double,
        footprintArea: Double = 400,
        footprint: [Coordinate2D] = [],
        massing: Massing = .uniform,
        yearBuilt: Int? = nil,
        material: ConstructionMaterial = .reinforcedConcrete,
        system: StructuralSystem = .momentFrame,
        foundation: FoundationType = .unknown,
        soil: SoilClass = .denseSoil,
        retrofit: RetrofitLevel = .none,
        architect: String? = nil,
        notes: String = "",
        notableEvents: [String] = [],
        damping: Double? = nil,
        provenance: [String: FactProvenance] = [:],
        privacy: PrivacyLevel = .approximate,
        pairedNodeID: String? = nil,
        isSandbox: Bool = false,
        createdAt: Date = Date(),
        thumbnailSystemImage: String = "building.2"
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.storeyCount = Swift.max(storeyCount, 1)
        self.height = Swift.max(height, 2.5)
        self.footprintArea = Swift.max(footprintArea, 10)
        self.footprint = footprint.isEmpty
            ? Self.rectangularFootprint(area: Swift.max(footprintArea, 10)) : footprint
        self.massing = massing
        self.yearBuilt = yearBuilt
        self.material = material
        self.system = system
        self.foundation = foundation
        self.soil = soil
        self.retrofit = retrofit
        self.architect = architect
        self.notes = notes
        self.notableEvents = notableEvents
        self.damping = damping ?? material.typicalDamping
        self.provenance = provenance
        self.privacy = privacy
        self.pairedNodeID = pairedNodeID
        self.isSandbox = isSandbox
        self.createdAt = createdAt
        self.thumbnailSystemImage = thumbnailSystemImage
    }

    public var storeyHeight: Double { height / Double(storeyCount) }

    /// Squarish plan, centred on the origin — the fallback when we have an area
    /// but no real outline.
    public static func rectangularFootprint(area: Double, aspect: Double = 1.4) -> [Coordinate2D] {
        let w = (area * aspect).squareRoot()
        let d = area / w
        return [Coordinate2D(x: -w / 2, y: -d / 2), Coordinate2D(x: w / 2, y: -d / 2),
                Coordinate2D(x: w / 2, y: d / 2), Coordinate2D(x: -w / 2, y: d / 2)]
    }

    /// The empirical period estimate, ASCE 7-style `T = Ct·H^x`, adjusted for
    /// retrofit. This is the *prior*: the solver refines it, and a real
    /// measurement from a node overrides it entirely.
    public var empiricalPeriod: Double {
        let (ct, x): (Double, Double) = switch (system, material) {
        case (.momentFrame, .steel): (0.0724, 0.8)
        case (.momentFrame, _): (0.0466, 0.9)
        case (.bracedFrame, _): (0.0731, 0.75)
        case (.baseIsolated, _): (0.075, 0.95)
        case (.softStorey, _): (0.055, 0.92)
        default: (0.0488, 0.75)
        }
        let base = ct * pow(height, x)
        // A stiffer building has a shorter period: T ∝ 1/√k.
        return base / retrofit.stiffnessFactor.squareRoot()
    }

    public func provenance(for field: String) -> FactProvenance {
        provenance[field] ?? FactProvenance(source: .defaultAssumption)
    }
}

/// Plain planar point in metres. Deliberately not CoreLocation — the core has no
/// platform dependencies so it stays testable on any machine.
public struct Coordinate2D: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}
