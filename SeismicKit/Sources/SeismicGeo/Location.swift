import Foundation
import SeismicCore

// Algorithms 35–38. Where it happened, how far away it was, and how hard it is
// about to shake here.

/// A point on the Earth. Deliberately not CoreLocation, so every one of these
/// algorithms is testable on any machine with no framework and no simulator.
public struct GeoPoint: Codable, Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double
    /// Metres below the surface. Positive is down, matching seismological usage.
    public var depth: Double

    public init(latitude: Double, longitude: Double, depth: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.depth = depth
    }

    public var isValid: Bool {
        latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180
            && latitude.isFinite && longitude.isFinite
    }

    /// Normalises a longitude that has wrapped past the antimeridian.
    public var normalised: GeoPoint {
        var lon = longitude
        while lon > 180 { lon -= 360 }
        while lon < -180 { lon += 360 }
        return GeoPoint(latitude: Swift.min(Swift.max(latitude, -90), 90),
                        longitude: lon, depth: depth)
    }
}

// MARK: - 37. Haversine distance and bearing

public enum Geodesy {
    /// Mean Earth radius, metres.
    public static let earthRadius: Double = 6_371_008.8

    /// Algorithm 37 — great-circle distance.
    ///
    /// Used everywhere a range appears: distance to an epicentre, distance to a
    /// neighbour's building, the radius of a map query. The haversine form is
    /// chosen over the simpler spherical law of cosines because it stays
    /// accurate for the short distances that dominate here — two buildings on
    /// the same street — where the cosine form loses precision badly.
    public static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let φ1 = a.latitude * .pi / 180
        let φ2 = b.latitude * .pi / 180
        let dφ = (b.latitude - a.latitude) * .pi / 180
        let dλ = (b.longitude - a.longitude) * .pi / 180

        let sinDφ = sin(dφ / 2), sinDλ = sin(dλ / 2)
        let h = sinDφ * sinDφ + cos(φ1) * cos(φ2) * sinDλ * sinDλ
        return 2 * earthRadius * asin(Swift.min(h.squareRoot(), 1))
    }

    public static func distanceKm(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        distance(a, b) / 1000
    }

    /// Hypocentral distance — including depth. This is the one the travel times
    /// actually depend on; using the surface distance for a deep event
    /// underestimates the path by a large margin.
    public static func hypocentralDistanceKm(from surface: GeoPoint, to hypocentre: GeoPoint) -> Double {
        let horizontal = distanceKm(surface, hypocentre)
        let depthKm = hypocentre.depth / 1000
        return (horizontal * horizontal + depthKm * depthKm).squareRoot()
    }

    /// Initial bearing along the great circle, degrees clockwise from north.
    public static func bearing(from a: GeoPoint, to b: GeoPoint) -> Double {
        let φ1 = a.latitude * .pi / 180
        let φ2 = b.latitude * .pi / 180
        let dλ = (b.longitude - a.longitude) * .pi / 180

        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        let θ = atan2(y, x) * 180 / .pi
        return (θ + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Compass point, for saying "12 km north-east of you" rather than "bearing 043".
    public static func compassPoint(_ bearing: Double) -> String {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                      "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let index = Int(((bearing + 11.25) / 22.5).rounded(.down)) % 16
        return points[(index + 16) % 16]
    }

    /// Projects a point a given distance and bearing away. Used to lay out the
    /// grid the triangulation searches, and to offset a building's published
    /// position for privacy.
    public static func destination(from origin: GeoPoint, distanceMetres: Double,
                                   bearingDegrees: Double) -> GeoPoint {
        let δ = distanceMetres / earthRadius
        let θ = bearingDegrees * .pi / 180
        let φ1 = origin.latitude * .pi / 180
        let λ1 = origin.longitude * .pi / 180

        let sinφ2 = sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ)
        let φ2 = asin(Swift.min(Swift.max(sinφ2, -1), 1))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sinφ2)

        return GeoPoint(latitude: φ2 * 180 / .pi,
                        longitude: λ2 * 180 / .pi, depth: origin.depth).normalised
    }

    /// Metres per degree of longitude at a given latitude — needed to convert a
    /// map region into a search radius without a full projection.
    public static func metresPerDegreeLongitude(atLatitude latitude: Double) -> Double {
        cos(latitude * .pi / 180) * .pi * earthRadius / 180
    }

    public static let metresPerDegreeLatitude: Double = .pi * earthRadius / 180
}

// MARK: - 35. S-minus-P to distance

public enum EpicentralDistance {

    /// Crustal P-wave velocity, km/s.
    public static let vP = 6.0
    /// Crustal S-wave velocity, km/s. The ratio √3 is close to universal in
    /// continental crust.
    public static let vS = 3.45

    /// The constant in the rule of thumb `distance ≈ k · (S−P)`.
    public static var kilometresPerSecondOfSMinusP: Double {
        1 / (1 / vS - 1 / vP)
    }

    /// Algorithm 35 — epicentral distance from a single station.
    ///
    /// The P-wave and S-wave leave the source together and travel at different
    /// speeds, so the gap between their arrivals grows steadily with distance.
    /// One sensor, one subtraction, and you know how far away it was — no
    /// network required. It cannot tell you the *direction*, which is why the
    /// result is a circle rather than a point, and why the app draws it that way.
    public struct Result: Sendable, Equatable {
        public var distanceKm: Double
        public var uncertaintyKm: Double
        public var sMinusP: Double
        /// Seconds until the S-wave arrives, given how far it has to come.
        /// This is the warning time.
        public var explanation: String

        public var range: ClosedRange<Double> {
            Swift.max(distanceKm - uncertaintyKm, 0)...(distanceKm + uncertaintyKm)
        }
    }

    public static func from(sMinusP: Double, pickConfidence: Double = 1.0) -> Result? {
        guard sMinusP > 0, sMinusP.isFinite else { return nil }
        let distance = kilometresPerSecondOfSMinusP * sMinusP

        // Uncertainty has two parts: how well the arrivals were picked, and how
        // much the real crust differs from the assumed velocities. The second
        // dominates at range, so the uncertainty is proportional rather than fixed.
        let pickError = (1 - Swift.min(Swift.max(pickConfidence, 0), 1)) * 0.8 + 0.15
        let velocityError = 0.12
        let uncertainty = distance * velocityError + kilometresPerSecondOfSMinusP * pickError

        return Result(
            distanceKm: distance,
            uncertaintyKm: uncertainty,
            sMinusP: sMinusP,
            explanation: "The S-wave arrived \(String(format: "%.1f", sMinusP)) s after the "
                + "P-wave. At typical crustal velocities that puts the source about "
                + "\(String(format: "%.0f", distance)) km away, give or take "
                + "\(String(format: "%.0f", uncertainty)) km. A single sensor cannot tell "
                + "which direction, so this is a circle around you rather than a point.")
    }

    /// Warning time remaining: how long until the S-wave gets here, measured
    /// from the moment the P-wave was detected.
    public static func warningSeconds(distanceKm: Double, elapsedSinceP: Double = 0) -> Double {
        guard distanceKm > 0 else { return 0 }
        let sTravel = distanceKm / vS
        let pTravel = distanceKm / vP
        return Swift.max(sTravel - pTravel - elapsedSinceP, 0)
    }
}

// MARK: - 36. Multi-node triangulation

public struct NodeArrival: Sendable, Equatable, Identifiable {
    public var id: String
    public var location: GeoPoint
    /// Absolute time the P-wave arrived at this node.
    public var pArrivalTime: Date
    public var weight: Double

    public init(id: String, location: GeoPoint, pArrivalTime: Date, weight: Double = 1) {
        self.id = id; self.location = location
        self.pArrivalTime = pArrivalTime; self.weight = weight
    }
}

public enum Triangulation {

    public struct Solution: Sendable, Equatable {
        public var epicentre: GeoPoint
        public var originTime: Date
        /// Root-mean-square travel-time residual, seconds. The honest measure of
        /// how well the solution fits.
        public var rmsResidualSeconds: Double
        public var horizontalUncertaintyKm: Double
        public var stationCount: Int
        public var explanation: String

        /// A solution from three stations in a line is geometrically weak no
        /// matter how small the residual is. The UI must say so.
        public var isWellConstrained: Bool {
            stationCount >= 3 && rmsResidualSeconds < 1.5 && horizontalUncertaintyKm < 30
        }
    }

    /// Algorithm 36 — epicentre by grid-search least squares.
    ///
    /// With arrivals at three or more nodes the source can be located rather
    /// than merely ranged. A coarse-to-fine grid search is used in preference to
    /// an iterative gradient method because the travel-time residual surface has
    /// local minima — a gradient solver started in the wrong place converges
    /// confidently onto the wrong answer, which is a far worse failure than
    /// being slow.
    public static func locate(_ arrivals: [NodeArrival],
                              assumedDepthKm: Double = 10,
                              searchRadiusKm: Double = 400) -> Solution? {
        guard arrivals.count >= 3 else { return nil }
        let valid = arrivals.filter { $0.location.isValid }
        guard valid.count >= 3 else { return nil }

        // Start centred on the station that felt it first — the source is
        // usually nearest to it.
        guard let earliest = valid.min(by: { $0.pArrivalTime < $1.pArrivalTime }) else { return nil }

        var centre = earliest.location
        var span = searchRadiusKm
        var best: (point: GeoPoint, origin: Date, rms: Double)?

        // Four refinement passes, each an 11×11 grid over a shrinking box. That
        // is 484 evaluations for a resolution of roughly a kilometre over a
        // 400 km search — cheap enough to run on arrival of every new report.
        for pass in 0..<4 {
            let steps = 11
            let stepKm = span / Double(steps - 1)
            var passBest: (GeoPoint, Date, Double)?

            for i in 0..<steps {
                for j in 0..<steps {
                    let northKm = (Double(i) - Double(steps - 1) / 2) * stepKm
                    let eastKm = (Double(j) - Double(steps - 1) / 2) * stepKm

                    // `abs` matters: the bearing already encodes the direction,
                    // so passing a signed distance as well would cancel it out
                    // and fold the whole southern half of the grid onto the
                    // northern half.
                    var candidate = Geodesy.destination(from: centre,
                                                        distanceMetres: abs(northKm) * 1000,
                                                        bearingDegrees: northKm >= 0 ? 0 : 180)
                    candidate = Geodesy.destination(from: candidate,
                                                    distanceMetres: abs(eastKm) * 1000,
                                                    bearingDegrees: eastKm >= 0 ? 90 : 270)
                    candidate.depth = assumedDepthKm * 1000

                    guard let evaluation = evaluate(candidate, arrivals: valid) else { continue }
                    if passBest == nil || evaluation.rms < passBest!.2 {
                        passBest = (candidate, evaluation.origin, evaluation.rms)
                    }
                }
            }

            guard let found = passBest else { break }
            if best == nil || found.2 < best!.rms {
                best = (found.0, found.1, found.2)
            }
            centre = found.0
            span = stepKm * 2        // zoom into the winning cell
            _ = pass
        }

        guard let solution = best else { return nil }

        // Uncertainty from the residual and the network geometry. A tight
        // cluster of stations gives a poor azimuthal spread and a correspondingly
        // uncertain location, however well the times fit.
        let gap = azimuthalGap(from: solution.point, to: valid.map(\.location))
        let geometryPenalty = gap > 180 ? (gap - 180) / 180 * 40 : 0
        let uncertainty = solution.rms * EpicentralDistance.vP * 1.5 + geometryPenalty

        let quality: String
        switch (valid.count, solution.rms, gap) {
        case (_, ..<0.5, ..<180):
            quality = "Well constrained: \(valid.count) sensors, good coverage in every direction."
        case (_, ..<1.5, _):
            quality = "Reasonably constrained by \(valid.count) sensors, but they are clustered "
                + "on one side (\(Int(gap))° gap), so the position is better along one axis than the other."
        default:
            quality = "Weakly constrained. The arrival times do not fit a single source well "
                + "(\(String(format: "%.1f", solution.rms)) s residual) — treat this as a rough indication."
        }

        return Solution(
            epicentre: solution.point,
            originTime: solution.origin,
            rmsResidualSeconds: solution.rms,
            horizontalUncertaintyKm: uncertainty,
            stationCount: valid.count,
            explanation: quality)
    }

    /// For a candidate epicentre, the best-fitting origin time is simply the
    /// weighted mean of (arrival − travel time); the residual then measures how
    /// consistently that single origin time explains every station.
    private static func evaluate(_ candidate: GeoPoint,
                                 arrivals: [NodeArrival]) -> (origin: Date, rms: Double)? {
        var weightedOriginSum = 0.0
        var weightSum = 0.0
        var travelTimes: [Double] = []

        for arrival in arrivals {
            let distance = Geodesy.hypocentralDistanceKm(from: arrival.location, to: candidate)
            let travel = distance / EpicentralDistance.vP
            travelTimes.append(travel)
            let implied = arrival.pArrivalTime.timeIntervalSinceReferenceDate - travel
            weightedOriginSum += implied * arrival.weight
            weightSum += arrival.weight
        }
        guard weightSum > 0 else { return nil }
        let origin = weightedOriginSum / weightSum

        var sumSquares = 0.0
        for (i, arrival) in arrivals.enumerated() {
            let predicted = origin + travelTimes[i]
            let residual = arrival.pArrivalTime.timeIntervalSinceReferenceDate - predicted
            sumSquares += residual * residual * arrival.weight
        }
        let rms = (sumSquares / weightSum).squareRoot()

        return (Date(timeIntervalSinceReferenceDate: origin), rms)
    }

    /// Largest gap in azimuth between consecutive stations, seen from the
    /// epicentre. The single most useful number for judging network geometry:
    /// under 180° is good, over 270° means the solution is essentially a guess
    /// in one direction.
    public static func azimuthalGap(from epicentre: GeoPoint, to stations: [GeoPoint]) -> Double {
        guard stations.count >= 2 else { return 360 }
        var azimuths = stations.map { Geodesy.bearing(from: epicentre, to: $0) }.sorted()
        guard let first = azimuths.first else { return 360 }
        azimuths.append(first + 360)

        var maxGap = 0.0
        for i in 1..<azimuths.count {
            maxGap = Swift.max(maxGap, azimuths[i] - azimuths[i - 1])
        }
        return maxGap
    }
}

// MARK: - 38. Ground motion attenuation

public enum AttenuationModel {

    public struct Prediction: Sendable, Equatable {
        /// Expected peak ground acceleration here, m/s².
        public var pga: Double
        /// Logarithmic standard deviation — ground motion prediction is
        /// genuinely uncertain by roughly a factor of two, and pretending
        /// otherwise would be dishonest.
        public var sigmaLn: Double
        public var intensity: Double
        public var mercalli: MercalliIntensity
        public var distanceKm: Double
        public var explanation: String

        /// The 16th–84th percentile band: one sigma either side.
        public var plausibleRange: ClosedRange<Double> {
            (pga * exp(-sigmaLn))...(pga * exp(sigmaLn))
        }
    }

    /// Algorithm 38 — predict the shaking about to arrive.
    ///
    /// This is what the countdown is counting down *to*. Knowing that strong
    /// shaking is 8 seconds away is only useful alongside knowing how strong:
    /// "intensity IV, you will feel it" and "intensity VIII, get under the
    /// table" call for entirely different behaviour.
    ///
    /// Form: magnitude scaling, geometric spreading, anelastic attenuation, and
    /// a site term. The coefficients are a compact regional average rather than
    /// a specific published model, and the app says so wherever it is shown.
    public static func predict(magnitude: Double, distanceKm: Double,
                               depthKm: Double = 10, soil: SoilClass = .denseSoil) -> Prediction {
        let m = Swift.min(Swift.max(magnitude, 1), 9.5)
        let r = (distanceKm * distanceKm + depthKm * depthKm).squareRoot()

        // The near-source saturation term stops the prediction going to infinity
        // directly above the hypocentre — real shaking does not.
        let saturation = 0.149 * exp(0.647 * m)
        let effectiveR = (r * r + saturation).squareRoot()

        let lnPGA = -3.512 + 0.904 * m
            - 1.328 * log(effectiveR)
            - 0.00206 * r
        let pgaInG = exp(lnPGA)
        let pga = pgaInG * gravity * soil.amplification

        let (mercalli, continuous) = IntensityScale.fromPGA(pga)

        return Prediction(
            pga: pga,
            sigmaLn: 0.6,
            intensity: continuous,
            mercalli: mercalli,
            distanceKm: distanceKm,
            explanation: "A magnitude \(String(format: "%.1f", m)) at "
                + "\(String(format: "%.0f", distanceKm)) km, on "
                + "\(soil.label.lowercased()), would typically produce about "
                + "\(String(format: "%.2f", pga / gravity)) g — intensity \(mercalli.roman), "
                + "\(mercalli.shortLabel.lowercased()). \(mercalli.consequence) "
                + "Ground motion varies by roughly a factor of two either way even for "
                + "identical earthquakes, so treat this as a range rather than a figure.")
    }

    /// Seconds of warning available at a given distance, allowing for the time
    /// the system itself takes to detect, decide and deliver.
    public static func warningTime(distanceKm: Double, systemLatency: Double = 1.5) -> Double {
        Swift.max(EpicentralDistance.warningSeconds(distanceKm: distanceKm) - systemLatency, 0)
    }

    /// The blind zone: inside this radius the S-wave arrives before any warning
    /// possibly could. Being honest about it is part of not overselling the
    /// system.
    public static func blindZoneRadiusKm(systemLatency: Double = 1.5) -> Double {
        // Solve warningSeconds(d) = latency for d.
        let perKm = 1 / EpicentralDistance.vS - 1 / EpicentralDistance.vP
        return systemLatency / perKm
    }
}
