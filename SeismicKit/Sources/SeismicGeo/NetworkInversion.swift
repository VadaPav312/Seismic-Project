import Foundation
import SeismicCore

// MARK: - 80. RANSAC arrival-time consensus

/// Algorithm 80 — RANSAC consensus over arrival times.
///
/// The app now supports a crowd of phones as sensors, and a crowd has a
/// property a wired array does not: some of it is wrong. A phone in a moving
/// car, one being picked up as the shaking starts, one whose clock is a second
/// out because it has not synchronised for a week — each contributes an arrival
/// time that is not an arrival time at all.
///
/// Least squares cannot survive that. It minimises the sum of squared
/// residuals, so a single station wrong by two seconds contributes four hundred
/// times as much to the objective as a station wrong by a tenth, and the
/// solution moves to accommodate it. One bad phone in forty can drag an
/// epicentre kilometres.
///
/// RANSAC inverts the problem: instead of fitting everything and hoping,
/// repeatedly fit a *minimal* subset, count how many of the rest agree with it,
/// and keep the hypothesis with the largest agreeing set. Outliers are rarely
/// in the minimal subset and never agree with a good one, so they are excluded
/// rather than accommodated. The final fit uses only the consensus set.
public enum ArrivalConsensus {

    public struct Observation: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var latitude: Double
        public var longitude: Double
        /// Seconds after some common reference. Only differences matter, so the
        /// reference can be arbitrary.
        public var arrivalTime: Double

        public init(id: UUID = UUID(), latitude: Double, longitude: Double,
                    arrivalTime: Double) {
            self.id = id
            self.latitude = latitude
            self.longitude = longitude
            self.arrivalTime = arrivalTime
        }
    }

    public struct Consensus: Sendable, Equatable {
        /// The stations that agreed.
        public var inliers: [Observation]
        /// The stations that did not, and are excluded from the solution.
        public var outliers: [Observation]
        /// Best-fitting epicentre from the inliers alone.
        public var latitude: Double
        public var longitude: Double
        /// Origin time, in the same reference as the arrivals.
        public var originTime: Double
        /// RMS of the inlier residuals, seconds.
        public var residualRMS: Double
        /// Largest gap between neighbouring inliers as seen from the epicentre,
        /// degrees. Above about 180 the solution is geometrically unconstrained
        /// however small the residuals are.
        public var azimuthalGap: Double

        public init(inliers: [Observation], outliers: [Observation],
                    latitude: Double, longitude: Double, originTime: Double,
                    residualRMS: Double, azimuthalGap: Double) {
            self.inliers = inliers
            self.outliers = outliers
            self.latitude = latitude
            self.longitude = longitude
            self.originTime = originTime
            self.residualRMS = residualRMS
            self.azimuthalGap = azimuthalGap
        }

        /// Whether the geometry supports the answer, independently of how well
        /// it fits. The app already makes this point on its network screen with
        /// three sensors in a line; this is the same test, computed.
        public var isGeometricallySound: Bool { azimuthalGap < 180 }
    }

    /// - Parameters:
    ///   - waveSpeed: km/s. About 6 for P in the crust.
    ///   - tolerance: seconds of residual that still counts as agreement.
    ///   - iterations: random minimal subsets to try.
    public static func locate(_ observations: [Observation],
                              waveSpeed: Double = 6.0,
                              tolerance: Double = 0.5,
                              iterations: Int = 200,
                              seed: UInt64 = 0x5E15) -> Consensus? {
        guard observations.count >= 4 else { return nil }
        var rng = SeededRandom(seed: seed)

        var bestInliers: [Observation] = []
        var bestSolution: (lat: Double, lon: Double, time: Double)?

        for _ in 0..<iterations {
            // A minimal subset. Three stations plus an origin time is the
            // smallest set that pins a surface epicentre.
            var chosen: [Observation] = []
            var used = Set<Int>()
            while chosen.count < 3 && used.count < observations.count {
                let index = Int(rng.next() % UInt64(observations.count))
                guard used.insert(index).inserted else { continue }
                chosen.append(observations[index])
            }
            guard chosen.count == 3 else { continue }

            guard let candidate = gridSearch(chosen, waveSpeed: waveSpeed,
                                             coarse: true) else { continue }

            let inliers = observations.filter { observation in
                abs(residual(observation, at: candidate, waveSpeed: waveSpeed)) <= tolerance
            }
            if inliers.count > bestInliers.count {
                bestInliers = inliers
                bestSolution = candidate
            }
            // Every station agreeing is as good as it gets; stop looking.
            if bestInliers.count == observations.count { break }
        }

        guard bestInliers.count >= 3, bestSolution != nil,
              // Refit on the consensus set alone. The minimal-subset solution
              // was only ever a hypothesis to test membership against; using it
              // as the answer would throw away every station that agreed.
              let refined = gridSearch(bestInliers, waveSpeed: waveSpeed, coarse: false)
        else { return nil }

        let residuals = bestInliers.map { residual($0, at: refined, waveSpeed: waveSpeed) }
        let rms = (residuals.reduce(0) { $0 + $1 * $1 } / Double(residuals.count)).squareRoot()

        let outliers = observations.filter { candidate in
            !bestInliers.contains { $0.id == candidate.id }
        }

        return Consensus(inliers: bestInliers, outliers: outliers,
                         latitude: refined.lat, longitude: refined.lon,
                         originTime: refined.time, residualRMS: rms,
                         azimuthalGap: azimuthalGap(of: bestInliers,
                                                    fromLatitude: refined.lat,
                                                    longitude: refined.lon))
    }

    /// Grid search over the epicentre, with the origin time solved analytically
    /// at each node.
    ///
    /// Grid rather than gradient descent because the travel-time misfit surface
    /// for a small array has local minima — most memorably a mirror-image
    /// solution on the far side of a line of stations — and a gradient method
    /// finds whichever one it started nearest. A coarse grid followed by a fine
    /// one around the winner costs little and cannot be fooled that way.
    static func gridSearch(_ observations: [Observation], waveSpeed: Double,
                           coarse: Bool) -> (lat: Double, lon: Double, time: Double)? {
        guard !observations.isEmpty else { return nil }

        let latitudes = observations.map(\.latitude)
        let longitudes = observations.map(\.longitude)
        let centreLat = Stats.mean(latitudes)
        let centreLon = Stats.mean(longitudes)
        // Search well outside the array: an epicentre is very often not
        // between the stations that recorded it.
        let spanLat = max((latitudes.max()! - latitudes.min()!) * 3, 1.0)
        let spanLon = max((longitudes.max()! - longitudes.min()!) * 3, 1.0)

        var best: (lat: Double, lon: Double, time: Double, misfit: Double)?
        var stepsPerAxis = coarse ? 24 : 40
        var halfLat = spanLat, halfLon = spanLon
        var focusLat = centreLat, focusLon = centreLon

        for pass in 0..<(coarse ? 2 : 3) {
            for i in 0...stepsPerAxis {
                for j in 0...stepsPerAxis {
                    let lat = focusLat - halfLat
                            + 2 * halfLat * Double(i) / Double(stepsPerAxis)
                    let lon = focusLon - halfLon
                            + 2 * halfLon * Double(j) / Double(stepsPerAxis)

                    // With the epicentre fixed, the origin time that minimises
                    // the squared residuals is just the mean of arrival minus
                    // travel time. Solving it here rather than searching over
                    // it removes a whole dimension from the grid.
                    let travelTimes = observations.map {
                        distanceKm(from: ($0.latitude, $0.longitude), to: (lat, lon)) / waveSpeed
                    }
                    let origin = Stats.mean(zip(observations, travelTimes).map {
                        $0.arrivalTime - $1
                    })
                    var misfit = 0.0
                    for (observation, travel) in zip(observations, travelTimes) {
                        let r = observation.arrivalTime - (origin + travel)
                        misfit += r * r
                    }
                    if best == nil || misfit < best!.misfit {
                        best = (lat, lon, origin, misfit)
                    }
                }
            }
            guard let current = best else { return nil }
            // Zoom in around the winner for the next pass.
            focusLat = current.lat; focusLon = current.lon
            halfLat /= Double(stepsPerAxis) / 3
            halfLon /= Double(stepsPerAxis) / 3
            stepsPerAxis = coarse ? 12 : 20
            _ = pass
        }

        guard let final = best else { return nil }
        return (final.lat, final.lon, final.time)
    }

    /// How far a station's arrival is from what the solution predicts.
    ///
    /// Public because the screen shows it per rejected station: "excluded" on
    /// its own is an assertion, whereas "excluded, 3.9 s off" is a reason
    /// somebody can check and overrule.
    public static func residual(_ observation: Observation,
                                at solution: (lat: Double, lon: Double, time: Double),
                                waveSpeed: Double) -> Double {
        let travel = distanceKm(from: (observation.latitude, observation.longitude),
                                to: (solution.lat, solution.lon)) / waveSpeed
        return observation.arrivalTime - (solution.time + travel)
    }

    /// The largest angular gap between neighbouring stations, seen from the
    /// epicentre. The single most useful quality number a location has.
    public static func azimuthalGap(of observations: [Observation],
                                    fromLatitude latitude: Double,
                                    longitude: Double) -> Double {
        guard observations.count >= 2 else { return 360 }
        var azimuths = observations.map { observation -> Double in
            let dLat = observation.latitude - latitude
            let dLon = (observation.longitude - longitude)
                     * cos(latitude * .pi / 180)
            var angle = atan2(dLon, dLat) * 180 / .pi
            if angle < 0 { angle += 360 }
            return angle
        }.sorted()

        var largest = 0.0
        for i in 1..<azimuths.count {
            largest = max(largest, azimuths[i] - azimuths[i - 1])
        }
        // And the wrap-around gap, which is the one people forget and which is
        // usually the largest for a one-sided array.
        largest = max(largest, 360 - azimuths.last! + azimuths.first!)
        azimuths.removeAll()
        return largest
    }

    static func distanceKm(from: (Double, Double), to: (Double, Double)) -> Double {
        let earthRadius = 6371.0
        let dLat = (to.0 - from.0) * .pi / 180
        let dLon = (to.1 - from.1) * .pi / 180
        let meanLat = (from.0 + to.0) / 2 * .pi / 180
        let x = dLon * cos(meanLat)
        return earthRadius * (dLat * dLat + x * x).squareRoot()
    }
}

// MARK: - 81. Inverse-distance intensity interpolation

/// Algorithm 81 — shaking-intensity interpolation from scattered reports.
///
/// A crowd of phones produces intensity at the places phones happen to be:
/// dense along a high street, absent over a park, clustered in one block of
/// flats. What anybody wants is a map — an estimate everywhere, including where
/// nobody was standing.
///
/// This is inverse-distance weighting with two refinements that matter for
/// ground motion specifically. First, the weighting exponent follows the
/// physics rather than being a free parameter: shaking attenuates roughly as
/// one over distance, so squared inverse distance is about right and larger
/// exponents produce the bullseyes that make naive interpolated maps look like
/// dartboards. Second, and more importantly, every estimate carries the
/// distance to the nearest real report — because an interpolated value five
/// kilometres from the closest observation is a guess, and a map that draws it
/// in the same colour as a measured one is lying.
public enum IntensityField {

    public struct Report: Sendable, Equatable {
        public var latitude: Double
        public var longitude: Double
        /// Any intensity measure — Mercalli, PGA, whatever the caller uses
        /// consistently.
        public var value: Double
        /// How much to trust this report, 0–1. A sensor-verified reading
        /// outweighs somebody's impression.
        public var weight: Double

        public init(latitude: Double, longitude: Double, value: Double,
                    weight: Double = 1) {
            self.latitude = latitude
            self.longitude = longitude
            self.value = value
            self.weight = max(weight, 0)
        }
    }

    public struct Estimate: Sendable, Equatable {
        public var value: Double
        /// Kilometres to the nearest real report.
        public var nearestReportKm: Double
        /// How many reports contributed meaningfully.
        public var supportingReports: Int

        public init(value: Double, nearestReportKm: Double, supportingReports: Int) {
            self.value = value
            self.nearestReportKm = nearestReportKm
            self.supportingReports = supportingReports
        }

        /// Whether this square is worth drawing at full strength.
        ///
        /// The honest answer to "what was the shaking over the reservoir where
        /// nobody was standing" is "we do not know", and a map that fades out
        /// rather than extrapolating confidently says so without a legend.
        public var confidence: Double {
            let proximity = 1 / (1 + nearestReportKm / 2)
            let support = min(Double(supportingReports) / 4, 1)
            return min(max(proximity * 0.7 + support * 0.3, 0), 1)
        }
    }

    /// - Parameters:
    ///   - exponent: how fast influence falls with distance. Two matches
    ///     ground-motion attenuation; higher makes bullseyes.
    ///   - searchRadiusKm: reports beyond this are ignored entirely, which
    ///     keeps a report from the next city from tinting a whole map.
    public static func estimate(at latitude: Double, longitude: Double,
                                from reports: [Report],
                                exponent: Double = 2,
                                searchRadiusKm: Double = 25) -> Estimate? {
        guard !reports.isEmpty else { return nil }

        var weightedSum = 0.0
        var weightTotal = 0.0
        var nearest = Double.greatestFiniteMagnitude
        var supporting = 0

        for report in reports {
            let distance = ArrivalConsensus.distanceKm(
                from: (latitude, longitude), to: (report.latitude, report.longitude))
            nearest = min(nearest, distance)
            guard distance <= searchRadiusKm, report.weight > 0 else { continue }

            // Standing exactly on a report returns that report, rather than
            // dividing by zero — the classic IDW singularity.
            if distance < 0.01 {
                return Estimate(value: report.value, nearestReportKm: distance,
                                supportingReports: 1)
            }
            let weight = report.weight / Foundation.pow(distance, exponent)
            weightedSum += weight * report.value
            weightTotal += weight
            supporting += 1
        }

        guard weightTotal > 0 else {
            return Estimate(value: 0, nearestReportKm: nearest, supportingReports: 0)
        }
        return Estimate(value: weightedSum / weightTotal,
                        nearestReportKm: nearest,
                        supportingReports: supporting)
    }

    /// A grid of estimates covering a bounding box, for drawing.
    public static func grid(reports: [Report],
                            minimumLatitude: Double, maximumLatitude: Double,
                            minimumLongitude: Double, maximumLongitude: Double,
                            resolution: Int = 24,
                            exponent: Double = 2,
                            searchRadiusKm: Double = 25) -> [[Estimate?]] {
        guard resolution > 1, !reports.isEmpty else { return [] }
        return (0..<resolution).map { row in
            let latitude = minimumLatitude
                + (maximumLatitude - minimumLatitude) * Double(row) / Double(resolution - 1)
            return (0..<resolution).map { column in
                let longitude = minimumLongitude
                    + (maximumLongitude - minimumLongitude)
                    * Double(column) / Double(resolution - 1)
                return estimate(at: latitude, longitude: longitude, from: reports,
                                exponent: exponent, searchRadiusKm: searchRadiusKm)
            }
        }
    }
}

// MARK: - 82. DBSCAN

/// Algorithm 82 — density-based spatial clustering (DBSCAN).
///
/// The map already clusters tags by geohash cell, which is fast and has the
/// flaw every grid method has: a cell boundary running down the middle of a
/// street splits one group of buildings into two clusters that then sit side by
/// side on screen, and moving the map by one pixel merges them again.
///
/// DBSCAN clusters by density instead of by position. A point belongs to a
/// cluster if enough other points are within a given radius of it, and clusters
/// grow transitively through those neighbourhoods — so a terrace of tagged
/// buildings forms one cluster of whatever shape the terrace happens to be,
/// with no grid to be misaligned with. It also does something no grid method
/// can: it labels sparse points as *noise* rather than forcing them into a
/// cluster, which for a map of building assessments means a single tagged
/// building on its own is drawn as itself rather than as a cluster of one.
public enum DensityClustering {

    public struct Cluster<Item>: Identifiable {
        public var id: Int
        public var items: [Item]
        public var centreLatitude: Double
        public var centreLongitude: Double

        public init(id: Int, items: [Item], centreLatitude: Double,
                    centreLongitude: Double) {
            self.id = id
            self.items = items
            self.centreLatitude = centreLatitude
            self.centreLongitude = centreLongitude
        }
    }

    public struct Result<Item> {
        public var clusters: [Cluster<Item>]
        /// Points too isolated to belong to any cluster. Drawn individually.
        public var noise: [Item]

        public init(clusters: [Cluster<Item>], noise: [Item]) {
            self.clusters = clusters
            self.noise = noise
        }
    }

    /// - Parameters:
    ///   - radiusKm: the neighbourhood radius, ε.
    ///   - minimumPoints: how many neighbours make a point a core point. Two is
    ///     right for map clustering — a pair of adjacent buildings is a cluster
    ///     — whereas the textbook default of four suits higher dimensions.
    public static func cluster<Item>(_ items: [Item],
                                     radiusKm: Double,
                                     minimumPoints: Int = 2,
                                     latitude: (Item) -> Double,
                                     longitude: (Item) -> Double) -> Result<Item> {
        let n = items.count
        guard n > 0 else { return Result(clusters: [], noise: []) }

        let points = items.map { (latitude($0), longitude($0)) }

        func neighbours(of index: Int) -> [Int] {
            (0..<n).filter { other in
                other != index &&
                ArrivalConsensus.distanceKm(from: points[index], to: points[other]) <= radiusKm
            }
        }

        var labels = [Int?](repeating: nil, count: n)   // nil = unvisited
        var isNoise = [Bool](repeating: false, count: n)
        var clusterID = 0

        for index in 0..<n where labels[index] == nil {
            let found = neighbours(of: index)
            if found.count < minimumPoints {
                isNoise[index] = true
                continue
            }

            labels[index] = clusterID
            isNoise[index] = false

            // Breadth-first growth through the density-connected region.
            var queue = found
            var head = 0
            while head < queue.count {
                let candidate = queue[head]
                head += 1

                // A point previously called noise can still join a cluster as a
                // border point — it just cannot seed one. Getting this wrong is
                // the classic DBSCAN bug and it leaves stray singletons dotted
                // around every cluster edge.
                if isNoise[candidate] {
                    isNoise[candidate] = false
                    labels[candidate] = clusterID
                }
                guard labels[candidate] == nil else { continue }
                labels[candidate] = clusterID

                let candidateNeighbours = neighbours(of: candidate)
                if candidateNeighbours.count >= minimumPoints {
                    for neighbour in candidateNeighbours where !queue.contains(neighbour) {
                        queue.append(neighbour)
                    }
                }
            }
            clusterID += 1
        }

        var clusters: [Cluster<Item>] = []
        for id in 0..<clusterID {
            let members = (0..<n).filter { labels[$0] == id && !isNoise[$0] }
            guard !members.isEmpty else { continue }
            clusters.append(Cluster(
                id: id,
                items: members.map { items[$0] },
                centreLatitude: Stats.mean(members.map { points[$0].0 }),
                centreLongitude: Stats.mean(members.map { points[$0].1 })))
        }
        let noise = (0..<n).filter { isNoise[$0] || labels[$0] == nil }.map { items[$0] }
        return Result(clusters: clusters, noise: noise)
    }
}
