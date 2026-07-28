import Foundation

/// The fifty algorithms, as data.
///
/// This exists so none of them is invisible work. The diagnostics screen renders
/// this catalogue directly: every entry names where its output is visible in the
/// app, and tapping one jumps there. If an algorithm cannot state where it
/// surfaces, it does not belong in the build.
public struct AlgorithmEntry: Identifiable, Sendable, Hashable {
    public let number: Int
    public let name: String
    public let family: Family
    /// One sentence on what it does and why this app needs it.
    public let purpose: String
    /// Where in the UI its output appears.
    public let surfacedAt: String
    public var id: Int { number }

    public enum Family: String, CaseIterable, Sendable, Identifiable {
        case conditioning = "Signal conditioning"
        case detection = "Detection and picking"
        case spectral = "Spectral analysis"
        case modal = "Modal and damping"
        case characterisation = "Earthquake characterisation"
        case location = "Location and distance"
        case structural = "Structural simulation"
        case assessment = "Assessment and inference"
        case infrastructure = "Supporting infrastructure"
        public var id: String { rawValue }

        public var systemImage: String {
            switch self {
            case .conditioning: "waveform.path"
            case .detection: "bolt.badge.clock"
            case .spectral: "chart.bar.xaxis"
            case .modal: "tuningfork"
            case .characterisation: "waveform.badge.magnifyingglass"
            case .location: "mappin.and.ellipse"
            case .structural: "building.columns"
            case .assessment: "checkmark.shield"
            case .infrastructure: "gearshape.2"
            }
        }
    }

    public init(_ number: Int, _ name: String, _ family: Family,
                _ purpose: String, surfacedAt: String) {
        self.number = number; self.name = name; self.family = family
        self.purpose = purpose; self.surfacedAt = surfacedAt
    }
}

public enum AlgorithmCatalog {
    public static let all: [AlgorithmEntry] = [
        // Signal conditioning
        .init(1, "DC offset removal and linear detrend", .conditioning,
              "Strips the sensor's resting bias and any slow ramp, so an integration does not run away.",
              surfacedAt: "Monitor → Processing chain"),
        .init(2, "Butterworth bandpass filter", .conditioning,
              "Keeps the seismic band and discards both DC wander and electrical hash.",
              surfacedAt: "Monitor → Processing chain"),
        .init(3, "Hann and Hamming windowing", .conditioning,
              "Tapers each analysis block so spectral leakage does not invent peaks.",
              surfacedAt: "Analysis → Spectrum settings"),
        .init(4, "Baseline correction", .conditioning,
              "Removes the residual acceleration offset that would otherwise fake a permanent displacement.",
              surfacedAt: "Event → Replay → Displacement trace"),
        .init(5, "Trapezoidal integration to velocity and displacement", .conditioning,
              "Turns what the accelerometer measured into the displacement an engineer reasons about.",
              surfacedAt: "Event → Replay → Velocity and displacement traces"),
        .init(6, "High-pass drift removal after integration", .conditioning,
              "Kills the parabolic drift each integration stage introduces.",
              surfacedAt: "Event → Replay → Displacement trace"),
        .init(7, "Reservoir sampling", .conditioning,
              "Keeps a statistically fair sample of a stream that never ends, in bounded memory.",
              surfacedAt: "Node → Diagnostics → Long-run statistics"),
        .init(8, "Douglas-Peucker decimation", .conditioning,
              "Draws a million-sample trace at screen resolution without losing a single visible peak.",
              surfacedAt: "Everywhere a waveform is drawn"),

        // Detection and picking
        .init(9, "STA/LTA trigger", .detection,
              "The classic ratio detector: short-term energy against the long-term background.",
              surfacedAt: "Monitor → ratio trace beneath the seismograph"),
        .init(10, "Recursive STA/LTA", .detection,
              "The same detector in constant memory, which is what runs continuously on the node.",
              surfacedAt: "Monitor → ratio trace"),
        .init(11, "Akaike Information Criterion P-wave picker", .detection,
              "Finds the exact sample where the P-wave arrives, far more precisely than a threshold can.",
              surfacedAt: "Event → Replay timeline → P marker"),
        .init(12, "S-wave detection by polarisation change", .detection,
              "Spots the moment the motion turns transverse, which is the destructive wave arriving.",
              surfacedAt: "Event → Replay timeline → S marker"),
        .init(13, "Weighted multi-channel fusion vote", .detection,
              "Requires independent sensors to agree before an event is believed.",
              surfacedAt: "Event → Sensor agreement panel"),
        .init(14, "False-trigger rejection against a nuisance library", .detection,
              "Recognises a slammed door or a passing lorry by its signature and refuses to call it an earthquake.",
              surfacedAt: "Node → Diagnostics → Rejected triggers"),

        // Spectral
        .init(15, "Radix-2 FFT", .spectral,
              "The transform every frequency-domain answer in the app is built on.",
              surfacedAt: "Analysis → Spectrum"),
        .init(16, "Welch power spectral density", .spectral,
              "Averages overlapping segments so the building's peak stands clear of the noise.",
              surfacedAt: "Analysis → Spectrum"),
        .init(17, "Konno-Ohmachi smoothing", .spectral,
              "Smooths with constant resolution in log-frequency, the way spectra are meant to be read.",
              surfacedAt: "Analysis → Spectrum → Smoothing control"),
        .init(18, "Peak picking with prominence and separation", .spectral,
              "Finds the modal peaks and ignores the ripples between them.",
              surfacedAt: "Analysis → Identified modes"),
        .init(19, "Parabolic sub-bin interpolation", .spectral,
              "Recovers frequency precision finer than the FFT bin spacing, which matters when a 2% shift is the signal.",
              surfacedAt: "Analysis → Period readout"),
        .init(20, "Autocorrelation period estimate", .spectral,
              "An independent second opinion on the period, computed a completely different way.",
              surfacedAt: "Analysis → Cross-check panel"),
        .init(21, "Zero-crossing rate estimate", .spectral,
              "A third opinion, cheap enough to run continuously.",
              surfacedAt: "Analysis → Cross-check panel"),
        .init(22, "Short-time Fourier transform", .spectral,
              "Shows how the building's frequency content evolved through the shaking.",
              surfacedAt: "Event → Waterfall view"),

        // Modal
        .init(23, "Hilbert transform envelope", .modal,
              "Extracts the decay envelope that damping is measured from.",
              surfacedAt: "Analysis → Damping"),
        .init(24, "Logarithmic decrement damping", .modal,
              "Reads damping straight off the decay of free vibration.",
              surfacedAt: "Analysis → Damping"),
        .init(25, "Half-power bandwidth damping", .modal,
              "Reads damping off the width of the spectral peak, as a cross-check.",
              surfacedAt: "Analysis → Damping"),
        .init(26, "Random decrement technique", .modal,
              "Pulls a free-decay signature out of ordinary ambient vibration, so no shaking is needed to measure the building.",
              surfacedAt: "Analysis → Ambient measurement"),
        .init(27, "Mode tracking with hysteresis", .modal,
              "Guarantees mode one is always compared with mode one, across months of scans.",
              surfacedAt: "Analysis → Period history chart"),
        .init(28, "Temperature-frequency regression", .modal,
              "The correction that stops a cold morning being reported as structural damage.",
              surfacedAt: "Assess → Temperature correction"),

        // Characterisation
        .init(29, "Peak ground acceleration, velocity and displacement", .characterisation,
              "The three headline severity numbers for any record.",
              surfacedAt: "Event → Peak values"),
        .init(30, "Arias intensity", .characterisation,
              "Total energy delivered, which correlates with damage far better than peak alone.",
              surfacedAt: "Event → Energy panel"),
        .init(31, "Cumulative absolute velocity", .characterisation,
              "The measure used operationally to decide whether shaking was strong enough to matter.",
              surfacedAt: "Event → Energy panel"),
        .init(32, "Significant duration (5–95% Arias)", .characterisation,
              "How long the shaking actually mattered for, ignoring the quiet tails.",
              surfacedAt: "Event → Energy panel"),
        .init(33, "Response spectrum by Newmark-beta", .characterisation,
              "What this ground motion does to buildings of every period — including this one.",
              surfacedAt: "Simulator → Response spectrum"),
        .init(34, "Magnitude estimate from early P-wave", .characterisation,
              "Estimates size from the first seconds, which is the only estimate available while there is still time to warn.",
              surfacedAt: "Event → Early warning header"),

        // Location
        .init(35, "S-minus-P to epicentral distance", .location,
              "Turns the gap between the two arrivals into a distance, from a single station.",
              surfacedAt: "Event → Epicentre estimate"),
        .init(36, "Multi-node epicentre triangulation", .location,
              "Grid-search least squares across every node that felt it.",
              surfacedAt: "Map → Network view"),
        .init(37, "Haversine distance and geodesic bearing", .location,
              "Distance and direction on a sphere, used everywhere a range appears.",
              surfacedAt: "Feed → Distance from you"),
        .init(38, "Ground motion attenuation model", .location,
              "Predicts the shaking about to reach the user, which is what the countdown is counting down to.",
              surfacedAt: "Early warning → Expected intensity"),

        // Structural
        .init(39, "Lumped-mass shear building assembly", .structural,
              "Turns storey masses and stiffnesses into the matrices the solver integrates.",
              surfacedAt: "Simulator → Model inspector"),
        .init(40, "Jacobi eigenvalue extraction", .structural,
              "Natural frequencies and mode shapes, from the matrices.",
              surfacedAt: "Simulator → Mode shapes"),
        .init(41, "Rayleigh damping matrix", .structural,
              "Gives the model realistic energy loss instead of ringing forever.",
              surfacedAt: "Simulator → What-if → Damping"),
        .init(42, "Newmark-beta time integration", .structural,
              "Steps the whole building through the earthquake, storey by storey, sample by sample.",
              surfacedAt: "Simulator → the building swaying"),
        .init(43, "Modal superposition", .structural,
              "The fast path, for live scrubbing and comparison mode.",
              surfacedAt: "Simulator → Comparison mode"),
        .init(44, "Hysteretic stiffness degradation", .structural,
              "Softens the model as it is damaged, so its period lengthens during the run exactly as a real building's does.",
              surfacedAt: "Simulator → Progressive damage"),
        .init(45, "Storey drift with damage-state classification", .structural,
              "The measure engineers actually use, classified against threshold sets.",
              surfacedAt: "Simulator → Drift per floor"),

        // Assessment
        .init(46, "Fragility curve evaluation", .assessment,
              "Probability of each damage state given the demand this building saw.",
              surfacedAt: "Assess → Damage-state probabilities"),
        .init(47, "Bayesian evidence fusion", .assessment,
              "Combines period change, residual displacement, tilt and photographs into one verdict with an honest interval.",
              surfacedAt: "Assess → Verdict and confidence"),
        .init(48, "CUSUM change detection", .assessment,
              "Catches slow softening between events, which no single measurement would reveal.",
              surfacedAt: "Analysis → Period history chart"),
        .init(49, "Mahalanobis distance anomaly detection", .assessment,
              "Learns what normal looks like for this specific building and flags departures from it.",
              surfacedAt: "Home → Behaviour anomaly badge"),
        .init(50, "Omori-Utsu and Gutenberg-Richter aftershock model", .assessment,
              "Turns aftershock statistics into a defensible answer to 'when can I go back inside?'.",
              surfacedAt: "Assess → Re-entry guidance"),

        // Supporting infrastructure — implemented and tested, not counted in the fifty.
        .init(51, "Merkle hash chaining", .infrastructure,
              "Makes the event ledger tamper-evident, so an assessment cannot be quietly edited.",
              surfacedAt: "Settings → Ledger verification"),
        .init(52, "CRC-verified gap-detecting chunk reassembly", .infrastructure,
              "Guarantees a recording pulled over BLE is the recording the node captured.",
              surfacedAt: "Node → Transfer progress"),
        .init(53, "Delta encoding for waveform transfer", .infrastructure,
              "Cuts the bytes a slow BLE link has to carry.",
              surfacedAt: "Node → Transfer statistics"),
        .init(54, "Exponential backoff with jitter", .infrastructure,
              "Reconnects reliably without hammering the radio or synchronising with other clients.",
              surfacedAt: "Node → Connection state"),
        .init(55, "Token-bucket rate limiting", .infrastructure,
              "Keeps every external API inside its quota, and explains it when it does not.",
              surfacedAt: "Settings → API keys → status"),
        .init(56, "LRU cache with size bounds", .infrastructure,
              "Keeps tiles, search results and rendered models fast without unbounded growth.",
              surfacedAt: "Settings → Storage"),
        .init(57, "Geohash indexing and marker clustering", .infrastructure,
              "Makes a map of thousands of community tags legible and fast.",
              surfacedAt: "Map"),
        .init(58, "Polygon extrusion and shoelace area", .infrastructure,
              "Turns a footprint outline into the 3D mass the simulator shakes.",
              surfacedAt: "Simulator → geometry"),
        .init(59, "Ray-casting point-in-polygon", .infrastructure,
              "Decides which building a tap, a tag or a node belongs to.",
              surfacedAt: "Map → tap targets"),
        .init(60, "BM25 ranking and fuzzy matching", .infrastructure,
              "Ranks and de-duplicates building search candidates from several providers.",
              surfacedAt: "Import → candidate list"),
        .init(61, "Confidence-weighted fact merging", .infrastructure,
              "Reconciles disagreeing sources into one figure, and shows its working.",
              surfacedAt: "Import → facts with sources"),
        .init(62, "Reputation-weighted consensus", .infrastructure,
              "Lets a professional assessment outweigh a crowd, without silencing the crowd.",
              surfacedAt: "Map → building consensus"),
    ]

    public static let countedAlgorithms = 50

    public static func entry(_ n: Int) -> AlgorithmEntry? { all.first { $0.number == n } }

    public static func family(_ f: AlgorithmEntry.Family) -> [AlgorithmEntry] {
        all.filter { $0.family == f }
    }
}
