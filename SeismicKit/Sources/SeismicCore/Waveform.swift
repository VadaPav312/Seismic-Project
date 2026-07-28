import Foundation

/// A uniformly sampled scalar channel. Everything downstream — filters, FFTs,
/// pickers, the structural solver — speaks this type, so a record from the node,
/// a historic USGS file and a synthetic trace are indistinguishable to the maths.
public struct Waveform: Codable, Sendable, Equatable {
    public var samples: [Double]
    /// Samples per second.
    public var sampleRate: Double
    /// Wall-clock time of `samples[0]`.
    public var startTime: Date
    /// What the numbers mean, for axis labelling and unit safety.
    public var unit: Unit

    public enum Unit: String, Codable, Sendable {
        case acceleration        // m/s²
        case velocity            // m/s
        case displacement        // m
        case dimensionless       // ratios, e.g. STA/LTA
        case degrees

        public var symbol: String {
            switch self {
            case .acceleration: "m/s²"
            case .velocity: "m/s"
            case .displacement: "m"
            case .dimensionless: ""
            case .degrees: "°"
            }
        }
    }

    public init(samples: [Double], sampleRate: Double,
                startTime: Date = Date(), unit: Unit = .acceleration) {
        self.samples = samples
        self.sampleRate = Swift.max(sampleRate, 1e-6)
        self.startTime = startTime
        self.unit = unit
    }

    public var count: Int { samples.count }
    public var dt: Double { 1 / sampleRate }
    public var duration: Double { Double(samples.count) / sampleRate }
    public var isEmpty: Bool { samples.isEmpty }

    /// Seconds from the start of the record for sample `i`.
    public func time(at i: Int) -> Double { Double(i) * dt }

    /// Sample index for a time offset, clamped into range.
    public func index(atTime t: Double) -> Int {
        Swift.min(Swift.max(Int((t * sampleRate).rounded()), 0), Swift.max(samples.count - 1, 0))
    }

    public func mapped(_ transform: ([Double]) -> [Double]) -> Waveform {
        Waveform(samples: transform(samples), sampleRate: sampleRate,
                 startTime: startTime, unit: unit)
    }

    public func slice(from: Double, to: Double) -> Waveform {
        guard !samples.isEmpty else { return self }
        let a = index(atTime: from), b = Swift.max(index(atTime: to), a)
        return Waveform(samples: Array(samples[a...b]), sampleRate: sampleRate,
                        startTime: startTime.addingTimeInterval(Double(a) * dt), unit: unit)
    }

    public var peakAbsolute: Double { Stats.peakAbs(samples) }
    public var rms: Double { Stats.rms(samples) }
}

/// Three-axis motion as the node reports it. Kept as three parallel channels
/// rather than an array of triples, because every algorithm downstream operates
/// on one channel at a time and interleaving would force a copy at every call.
public struct TriaxialRecord: Codable, Sendable, Equatable {
    public var x: Waveform
    public var y: Waveform
    public var z: Waveform

    public init(x: Waveform, y: Waveform, z: Waveform) {
        self.x = x; self.y = y; self.z = z
    }

    public var sampleRate: Double { x.sampleRate }
    public var count: Int { Swift.min(x.count, Swift.min(y.count, z.count)) }
    public var duration: Double { x.duration }
    public var startTime: Date { x.startTime }

    /// Vector magnitude channel. Orientation-independent, which is what the
    /// trigger and the intensity estimate both want.
    public var magnitude: Waveform {
        var out = [Double](repeating: 0, count: count)
        for i in 0..<count {
            out[i] = (x.samples[i] * x.samples[i]
                + y.samples[i] * y.samples[i]
                + z.samples[i] * z.samples[i]).squareRoot()
        }
        return Waveform(samples: out, sampleRate: sampleRate,
                        startTime: startTime, unit: x.unit)
    }

    /// The stronger of the two horizontal channels — the one that actually
    /// drives building response. Vertical motion rarely governs.
    public var dominantHorizontal: Waveform {
        x.peakAbsolute >= y.peakAbsolute ? x : y
    }

    public func channel(_ axis: Axis) -> Waveform {
        switch axis { case .x: x; case .y: y; case .z: z }
    }

    public enum Axis: String, Codable, Sendable, CaseIterable {
        case x, y, z
        public var label: String {
            switch self { case .x: "North–South"; case .y: "East–West"; case .z: "Vertical" }
        }
    }

    public static func zeros(count: Int, sampleRate: Double, startTime: Date = Date()) -> TriaxialRecord {
        let z = Waveform(samples: [Double](repeating: 0, count: count),
                         sampleRate: sampleRate, startTime: startTime)
        return TriaxialRecord(x: z, y: z, z: z)
    }
}
