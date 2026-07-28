import Foundation

// MARK: - A recorded event

public struct SeismicEvent: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var buildingID: UUID?
    public var nodeID: String?
    public var startTime: Date
    public var triggerRatio: Double
    public var triggerChannel: SensorChannel
    public var votes: [SensorVote]
    public var actuatorReports: [ActuatorReport]
    public var faults: [NodeFault]

    /// The high-rate capture. Nil until the transfer completes; a partial
    /// transfer keeps whatever arrived and sets `isComplete` false rather than
    /// throwing the fragment away.
    public var record: TriaxialRecord?
    public var isComplete: Bool
    public var missingChunks: [Int]
    public var expectedChunks: Int

    public var residualDisplacement: Double
    public var permanentTilt: Bool
    public var tiltAngle: Double
    public var structureTemperature: Double
    public var gridPowerLost: Bool
    public var waterDetected: Bool
    public var occupancyAtTrigger: Bool

    /// Set when the supply dipped during capture; such a record is never allowed
    /// to drive an assessment on its own.
    public var capturedDuringBrownout: Bool
    public var isDrill: Bool
    public var isSimulated: Bool
    public var acknowledgedAt: Date?
    public var label: String

    public init(
        id: UUID = UUID(),
        buildingID: UUID? = nil,
        nodeID: String? = nil,
        startTime: Date = Date(),
        triggerRatio: Double = 0,
        triggerChannel: SensorChannel = .accelerometer,
        votes: [SensorVote] = [],
        actuatorReports: [ActuatorReport] = [],
        faults: [NodeFault] = [],
        record: TriaxialRecord? = nil,
        isComplete: Bool = true,
        missingChunks: [Int] = [],
        expectedChunks: Int = 0,
        residualDisplacement: Double = 0,
        permanentTilt: Bool = false,
        tiltAngle: Double = 0,
        structureTemperature: Double = 19,
        gridPowerLost: Bool = false,
        waterDetected: Bool = false,
        occupancyAtTrigger: Bool = false,
        capturedDuringBrownout: Bool = false,
        isDrill: Bool = false,
        isSimulated: Bool = false,
        acknowledgedAt: Date? = nil,
        label: String = ""
    ) {
        self.id = id
        self.buildingID = buildingID
        self.nodeID = nodeID
        self.startTime = startTime
        self.triggerRatio = triggerRatio
        self.triggerChannel = triggerChannel
        self.votes = votes
        self.actuatorReports = actuatorReports
        self.faults = faults
        self.record = record
        self.isComplete = isComplete
        self.missingChunks = missingChunks
        self.expectedChunks = expectedChunks
        self.residualDisplacement = residualDisplacement
        self.permanentTilt = permanentTilt
        self.tiltAngle = tiltAngle
        self.structureTemperature = structureTemperature
        self.gridPowerLost = gridPowerLost
        self.waterDetected = waterDetected
        self.occupancyAtTrigger = occupancyAtTrigger
        self.capturedDuringBrownout = capturedDuringBrownout
        self.isDrill = isDrill
        self.isSimulated = isSimulated
        self.acknowledgedAt = acknowledgedAt
        self.label = label
    }

    public var agreementCount: Int { votes.filter(\.agreed).count }

    public var confirmedActuators: [ActuatorReport] {
        actuatorReports.filter { $0.state == .confirmed }
    }

    /// Weighted fusion of the channels that voted — algorithm 13's output, kept
    /// on the event so the timeline can show it without recomputing.
    public var fusionConfidence: Double {
        let total = votes.reduce(0.0) { $0 + $1.channel.voteWeight }
        guard total > 0 else { return 0 }
        let agreed = votes.filter(\.agreed).reduce(0.0) { $0 + $1.channel.voteWeight }
        return agreed / total
    }
}

/// Arrival picks, kept beside the record so the replay timeline can mark them.
public struct ArrivalPicks: Codable, Sendable, Equatable {
    public var pTime: Double?        // seconds from record start
    public var sTime: Double?
    public var pConfidence: Double
    public var sConfidence: Double

    public init(pTime: Double? = nil, sTime: Double? = nil,
                pConfidence: Double = 0, sConfidence: Double = 0) {
        self.pTime = pTime; self.sTime = sTime
        self.pConfidence = pConfidence; self.sConfidence = sConfidence
    }

    /// The S-minus-P interval, which is the whole basis of single-station
    /// distance estimation.
    public var sMinusP: Double? {
        guard let p = pTime, let s = sTime, s > p else { return nil }
        return s - p
    }
}

// MARK: - Earthquake records (the library the simulator shakes buildings with)

public struct EarthquakeRecord: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var year: Int
    public var magnitude: Double
    public var depthKm: Double
    public var latitude: Double
    public var longitude: Double
    public var station: String
    public var soilAtStation: SoilClass
    public var pgaTarget: Double            // m/s², the record's peak
    public var duration: Double             // s
    public var dominantPeriod: Double       // s — where its energy sits
    public var summary: String
    public var origin: Origin
    /// Present for real captures and imported files; synthesised on demand for
    /// library records so the app ships small but shakes with real character.
    public var waveform: Waveform?

    public enum Origin: String, Codable, Sendable {
        case historic, liveFeed, nodeCapture, synthetic, imported
        public var label: String {
            switch self {
            case .historic: "Historic record"
            case .liveFeed: "Live USGS feed"
            case .nodeCapture: "Captured by your node"
            case .synthetic: "Synthetic"
            case .imported: "Imported file"
            }
        }
    }

    public init(id: UUID = UUID(), name: String, year: Int, magnitude: Double,
                depthKm: Double = 10, latitude: Double = 0, longitude: Double = 0,
                station: String = "", soilAtStation: SoilClass = .denseSoil,
                pgaTarget: Double, duration: Double, dominantPeriod: Double,
                summary: String = "", origin: Origin = .historic,
                waveform: Waveform? = nil) {
        self.id = id; self.name = name; self.year = year; self.magnitude = magnitude
        self.depthKm = depthKm; self.latitude = latitude; self.longitude = longitude
        self.station = station; self.soilAtStation = soilAtStation
        self.pgaTarget = pgaTarget; self.duration = duration
        self.dominantPeriod = dominantPeriod; self.summary = summary
        self.origin = origin; self.waveform = waveform
    }
}

// MARK: - Assessment

public enum SafetyVerdict: String, Codable, Sendable, CaseIterable, Identifiable {
    case green, amber, red, needsInspection
    public var id: String { rawValue }

    public var placard: String {
        switch self {
        case .green: "APPEARS SAFE"
        case .amber: "LIMITED USE"
        case .red: "DO NOT ENTER"
        case .needsInspection: "NEEDS INSPECTION"
        }
    }

    public var shortLabel: String {
        switch self {
        case .green: "Green"
        case .amber: "Amber"
        case .red: "Red"
        case .needsInspection: "Inspect"
        }
    }

    /// Colour is never the only channel — every verdict also carries a distinct
    /// glyph so it survives colour blindness and greyscale printing.
    public var systemImage: String {
        switch self {
        case .green: "checkmark.circle.fill"
        case .amber: "exclamationmark.triangle.fill"
        case .red: "xmark.octagon.fill"
        case .needsInspection: "questionmark.circle.fill"
        }
    }

    public var plainMeaning: String {
        switch self {
        case .green: "No evidence of structural change was found. Normal occupancy is reasonable."
        case .amber: "Measurable change was found. Limit occupancy to essential access and get a professional inspection."
        case .red: "Strong evidence of structural damage. Do not enter until a qualified engineer has inspected the building."
        case .needsInspection: "The evidence is inconclusive or incomplete. A professional inspection is needed to decide."
        }
    }
}

/// One piece of evidence behind a verdict. The assessment screen lists every one
/// of these; nothing contributes to a verdict invisibly.
public struct Evidence: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var kind: Kind
    public var headline: String
    public var detail: String
    public var value: Double?
    public var unit: String
    /// −1 strongly reassuring … +1 strongly incriminating.
    public var damageIndication: Double
    public var weight: Double
    public var source: FactProvenance.Source

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case periodChange, residualDisplacement, permanentTilt, peakAcceleration
        case driftDemand, visualDamage, humanJudgment, ariasIntensity, aftershockContext

        public var label: String {
            switch self {
            case .periodChange: "Period change"
            case .residualDisplacement: "Residual displacement"
            case .permanentTilt: "Permanent tilt"
            case .peakAcceleration: "Peak acceleration"
            case .driftDemand: "Storey drift demand"
            case .visualDamage: "Visual damage"
            case .humanJudgment: "Human judgment"
            case .ariasIntensity: "Arias intensity"
            case .aftershockContext: "Aftershock context"
            }
        }

        public var systemImage: String {
            switch self {
            case .periodChange: "waveform.path.ecg"
            case .residualDisplacement: "arrow.left.and.right"
            case .permanentTilt: "angle"
            case .peakAcceleration: "speedometer"
            case .driftDemand: "building.columns"
            case .visualDamage: "camera"
            case .humanJudgment: "person.fill.checkmark"
            case .ariasIntensity: "chart.bar.fill"
            case .aftershockContext: "clock.arrow.circlepath"
            }
        }
    }

    public init(id: UUID = UUID(), kind: Kind, headline: String, detail: String,
                value: Double? = nil, unit: String = "", damageIndication: Double,
                weight: Double = 1, source: FactProvenance.Source = .measured) {
        self.id = id; self.kind = kind; self.headline = headline; self.detail = detail
        self.value = value; self.unit = unit; self.damageIndication = damageIndication
        self.weight = weight; self.source = source
    }
}

public struct Assessment: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var buildingID: UUID
    public var eventID: UUID?
    public var createdAt: Date
    public var verdict: SafetyVerdict
    /// Posterior probability that the building is damaged, from the Bayesian
    /// fusion. The interval is the honest part.
    public var damageProbability: Double
    public var confidenceInterval: ClosedRange<Double>
    public var confidence: Double
    public var evidence: [Evidence]

    public var periodBefore: Double?
    public var periodDuring: Double?
    public var periodAfter: Double?
    public var periodAfterTemperatureCorrection: Double?
    public var temperatureAtBaseline: Double?
    public var temperatureAtMeasurement: Double?

    public var narrative: String
    public var narrativeIsAIGenerated: Bool
    public var photoIDs: [UUID]
    public var noteIDs: [UUID]
    public var assessorTier: VerificationTier
    public var professionalSignature: String?
    /// Merkle chain position — proves this record has not been altered.
    public var ledgerHash: String?

    public init(
        id: UUID = UUID(), buildingID: UUID, eventID: UUID? = nil,
        createdAt: Date = Date(), verdict: SafetyVerdict = .needsInspection,
        damageProbability: Double = 0, confidenceInterval: ClosedRange<Double> = 0...1,
        confidence: Double = 0, evidence: [Evidence] = [],
        periodBefore: Double? = nil, periodDuring: Double? = nil, periodAfter: Double? = nil,
        periodAfterTemperatureCorrection: Double? = nil,
        temperatureAtBaseline: Double? = nil, temperatureAtMeasurement: Double? = nil,
        narrative: String = "", narrativeIsAIGenerated: Bool = false,
        photoIDs: [UUID] = [], noteIDs: [UUID] = [],
        assessorTier: VerificationTier = .unverified,
        professionalSignature: String? = nil, ledgerHash: String? = nil
    ) {
        self.id = id; self.buildingID = buildingID; self.eventID = eventID
        self.createdAt = createdAt; self.verdict = verdict
        self.damageProbability = damageProbability
        self.confidenceInterval = confidenceInterval
        self.confidence = confidence; self.evidence = evidence
        self.periodBefore = periodBefore; self.periodDuring = periodDuring
        self.periodAfter = periodAfter
        self.periodAfterTemperatureCorrection = periodAfterTemperatureCorrection
        self.temperatureAtBaseline = temperatureAtBaseline
        self.temperatureAtMeasurement = temperatureAtMeasurement
        self.narrative = narrative
        self.narrativeIsAIGenerated = narrativeIsAIGenerated
        self.photoIDs = photoIDs; self.noteIDs = noteIDs
        self.assessorTier = assessorTier
        self.professionalSignature = professionalSignature
        self.ledgerHash = ledgerHash
    }

    /// The headline number: how much longer the building's period got, in per
    /// cent. Positive means softer, which means damaged.
    public var periodChangePercent: Double? {
        guard let before = periodBefore, before > 0,
              let after = periodAfterTemperatureCorrection ?? periodAfter else { return nil }
        return (after - before) / before * 100
    }

    /// Never let a screening tool be mistaken for an inspection.
    public static let disclaimer = """
    Seismic is a screening aid, not a structural inspection. It measures how a \
    building's dynamic behaviour changed and reports that evidence. It cannot see \
    cracks inside a wall, and it cannot replace a qualified engineer's judgment.
    """
}

// MARK: - Identity

public enum VerificationTier: String, Codable, Sendable, CaseIterable, Comparable {
    case unverified, sensorVerified, professional

    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    public var rank: Int {
        switch self { case .unverified: 0; case .sensorVerified: 1; case .professional: 2 }
    }

    public var label: String {
        switch self {
        case .unverified: "Community"
        case .sensorVerified: "Sensor-verified"
        case .professional: "Professional"
        }
    }

    public var systemImage: String {
        switch self {
        case .unverified: "person"
        case .sensorVerified: "sensor.tag.radiowaves.forward"
        case .professional: "checkmark.seal.fill"
        }
    }

    /// Weight on the community map's consensus score.
    public var trustWeight: Double {
        switch self { case .unverified: 1.0; case .sensorVerified: 2.5; case .professional: 6.0 }
    }
}
