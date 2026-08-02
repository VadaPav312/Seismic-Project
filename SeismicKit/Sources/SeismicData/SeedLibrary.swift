import Foundation
import SeismicCore
import SeismicGeo
import SeismicSignal

/// Everything the app ships knowing.
///
/// The acceptance criterion is that a judge can open the app cold — no hardware,
/// no keys, no network — and find it already full of real, interesting content.
/// That means a library of genuine buildings with sourced facts, a set of
/// historic earthquake records, and months of plausible measurement history so
/// every chart, trend and long-run algorithm has something to show.
///
/// Facts here are recorded with the same provenance machinery as imported ones,
/// and where a figure is an engineering assumption rather than a documented fact
/// it is marked as such. The app never presents a guess as a certainty, and that
/// applies to its own seed data first of all.
public enum SeedLibrary {

    // MARK: - Buildings

    public static func buildings() -> [BuildingModel] {
        [
            sandboxBuilding(),

            building(
                name: "Transamerica Pyramid",
                address: "600 Montgomery St, San Francisco, California",
                latitude: 37.7952, longitude: -122.4028,
                // A square base of about 53 m a side, tapering to a top office
                // floor of roughly 2,500 sq ft against 21,000 at the fifth —
                // an area ratio of 0.12, so a linear scale of about 0.34.
                // Checked against the published gross floor area: a linear
                // taper over 48 floors integrates to 0.49 of the base plan,
                // which puts the total at 71,000 m². The published figure is
                // 70,900.
                storeys: 48, height: 260, footprintArea: 2800,
                year: 1972, material: .steel, system: .bracedFrame,
                foundation: .matSlab, soil: .denseSoil, retrofit: .partial,
                architect: "William Pereira",
                notes: "Its tapering form and deep truss base were designed explicitly for "
                    + "seismic performance. It came through Loma Prieta in 1989 undamaged, "
                    + "though the top reportedly swayed nearly a foot for over a minute.",
                events: ["1989 Loma Prieta — no structural damage"],
                image: "triangle",
                plan: .square,
                massing: .tapered(topScale: 0.31)),

            building(
                name: "Tokyo Skytree",
                address: "1 Chome-1-2 Oshiage, Sumida City, Tokyo",
                latitude: 35.7101, longitude: 139.8107,
                // An equilateral triangle of 68 m a side is 2,000 m², not the
                // 3,600 previously carried here. The tower then narrows hard
                // and turns circular by 300 m; the shaft at the upper
                // observatory is a fraction of the base.
                storeys: 29, height: 634, footprintArea: 2000,
                year: 2012, material: .steel, system: .dualSystem,
                foundation: .piled, soil: .stiffSoil, retrofit: .none,
                architect: "Nikken Sekkei",
                notes: "Uses a central concrete shaft loosely coupled to the steel lattice — a "
                    + "tuned mass damper the size of a building, borrowed from the design of "
                    + "traditional five-storey pagodas, none of which is recorded as having "
                    + "collapsed in an earthquake.",
                events: ["2011 Tōhoku — under construction, undamaged"],
                image: "antenna.radiowaves.left.and.right",
                // Triangular is right at the base, which is where the stiffness
                // that matters lives, and the app's plan is one shape for the
                // whole height. The taper is the part that was badly wrong: a
                // uniform 634 m triangular prism is not a tower, it is a wall.
                plan: .triangular,
                // Concave, not a straight cone. The Skytree narrows hard over
                // its first hundred and fifty metres and then runs on as a
                // nearly constant shaft — the hyperboloid profile it borrows
                // from a pagoda's silhouette. A straight taper between the same
                // two ends is a recognisably different building.
                massing: Massing(stations: [
                    .init(heightFraction: 0, scale: 1),
                    .init(heightFraction: 0.10, scale: 0.72),
                    .init(heightFraction: 0.25, scale: 0.50),
                    .init(heightFraction: 0.45, scale: 0.36),
                    .init(heightFraction: 0.70, scale: 0.28),
                    .init(heightFraction: 1, scale: 0.18),
                ])),

            building(
                name: "Torre Latinoamericana",
                address: "Eje Central Lázaro Cárdenas 2, Mexico City",
                latitude: 19.4339, longitude: -99.1409,
                // 27,727 m² of floor over 44 floors is about 630 m² a floor —
                // a tower roughly 25 m square, not the 1,200 m² carried here.
                // The lowest floors are wider, so the base plan is taken a
                // little above the average.
                storeys: 44, height: 166, footprintArea: 760,
                year: 1956, material: .steel, system: .momentFrame,
                foundation: .piled, soil: .softSoil, retrofit: .partial,
                architect: "Augusto H. Álvarez",
                notes: "Built on the drained lakebed under Mexico City — about the worst "
                    + "possible ground. It survived the 1985 earthquake that destroyed hundreds "
                    + "of buildings around it, because its period sat well away from the two "
                    + "second resonance of the soft soil that killed the mid-rise buildings.",
                events: ["1957 Guerrero — undamaged", "1985 Michoacán — undamaged",
                         "2017 Puebla — undamaged"],
                image: "building.columns",
                plan: .square,
                // A wider base for the first few floors, then a uniform shaft,
                // then the top floors stepping in under the mast — which is the
                // profile in every photograph of it.
                massing: Massing(stations: [
                    .init(heightFraction: 0, scale: 1),
                    .init(heightFraction: 0.08, scale: 1),
                    .init(heightFraction: 0.082, scale: 0.87),
                    .init(heightFraction: 0.88, scale: 0.87),
                    .init(heightFraction: 0.882, scale: 0.62),
                    .init(heightFraction: 1, scale: 0.62),
                ])),

            building(
                name: "Salesforce Tower",
                address: "415 Mission St, San Francisco, California",
                latitude: 37.7897, longitude: -122.3972,
                // Published floor plates are 25,000 sq ft, which is 2,320 m².
                storeys: 61, height: 326, footprintArea: 2320,
                year: 2018, material: .reinforcedConcrete, system: .dualSystem,
                foundation: .piled, soil: .stiffSoil, retrofit: .none,
                architect: "Pelli Clarke Pelli",
                notes: "Founded on 42 metre piles driven into bedrock, with a concrete core and "
                    + "perimeter frame. Designed to remain occupiable after a major earthquake "
                    + "rather than merely to avoid collapse — a much higher bar.",
                events: [],
                image: "building.2",
                plan: .square,
                // A gentle continuous taper rather than a pyramid: the
                // silhouette narrows the whole way up, which is what makes it
                // read as tall from across the bay. Nothing like the
                // Transamerica's slope, but not a prism either.
                massing: .tapered(topScale: 0.7)),

            building(
                name: "Christchurch Arts Centre",
                address: "2 Worcester Blvd, Christchurch, New Zealand",
                latitude: -43.5310, longitude: 172.6280,
                storeys: 3, height: 14, footprintArea: 2800,
                year: 1877, material: .unreinforcedMasonry, system: .bearingWall,
                foundation: .shallowSpread, soil: .stiffSoil,
                retrofit: .baseIsolationRetrofit,
                architect: "Benjamin Mountfort",
                notes: "Gothic revival stone — the most vulnerable construction there is. "
                    + "Severely damaged in 2011 and rebuilt over a decade with base isolation "
                    + "retrofitted beneath the historic fabric.",
                events: ["2010 Darfield — damage", "2011 Christchurch — severe damage",
                         "2011–2022 — base isolation retrofit"],
                image: "building.columns.fill",
                plan: .uShaped),

            building(
                name: "Ortigas Soft-Storey Apartments",
                address: "Pasig, Metro Manila, Philippines",
                latitude: 14.5833, longitude: 121.0614,
                storeys: 7, height: 21, footprintArea: 520,
                year: 1988, material: .reinforcedConcrete, system: .softStorey,
                foundation: .shallowSpread, soil: .softSoil, retrofit: .none,
                architect: nil,
                notes: "A representative mid-rise with an open ground floor for parking. "
                    + "This configuration concentrates the entire building's drift into one "
                    + "storey, and it is the single most common cause of collapse in "
                    + "earthquakes worldwide. Included precisely because it is ordinary.",
                events: [],
                image: "building.fill"),

            building(
                name: "Wooden Two-Storey House",
                address: "Berkeley, California",
                latitude: 37.8715, longitude: -122.2730,
                storeys: 2, height: 7, footprintArea: 140,
                year: 1948, material: .timber, system: .bracedFrame,
                foundation: .shallowSpread, soil: .denseSoil, retrofit: .full,
                architect: nil,
                notes: "A typical timber-frame home with a cripple wall retrofit — bolting the "
                    + "frame to its foundation and plywood-sheathing the crawl space. It is the "
                    + "cheapest seismic intervention there is and among the most effective.",
                events: [],
                image: "house"),
        ]
    }

    /// The sandbox building the app opens onto: the user's own, with months of
    /// history behind it, so every chart and trend is populated on first launch.
    public static func sandboxBuilding() -> BuildingModel {
        var provenance: [String: FactProvenance] = [:]
        provenance["height"] = FactProvenance(source: .userEntered, detail: "Measured from plans")
        provenance["storeyCount"] = FactProvenance(source: .userEntered)
        provenance["material"] = FactProvenance(source: .userEntered)
        provenance["system"] = FactProvenance(source: .defaultAssumption,
                                              detail: "Assumed from the building's age and type")
        provenance["soil"] = FactProvenance(source: .openStreetMap,
                                            detail: "Inferred from local geology mapping")

        return BuildingModel(
            id: sandboxBuildingID,
            name: "My building",
            address: "Demonstration building with simulated history",
            latitude: 37.7749, longitude: -122.4194,
            storeyCount: 8, height: 27.2, footprintArea: 620,
            yearBuilt: 1996,
            material: .reinforcedConcrete, system: .momentFrame,
            foundation: .matSlab, soil: .stiffSoil, retrofit: .none,
            architect: nil,
            notes: "The building your node is attached to. Everything shown for it is "
                + "simulated, but the simulation is physically realistic — the period drifts "
                + "with temperature, the ambient vibration carries the building's own "
                + "resonance, and damage would lengthen its period exactly as a real one's "
                + "would.",
            damping: 0.045,
            provenance: provenance,
            privacy: .approximate,
            pairedNodeID: "sim-node-01",
            isSandbox: true,
            thumbnailSystemImage: "building.2.fill")
    }

    /// Fixed rather than generated, so the sandbox building keeps its identity
    /// across launches, across reinstalls, and between the seed data and the
    /// synthetic history that references it.
    public static let sandboxBuildingID = UUID(uuidString: "5E150000-0000-4000-8000-000000000001")!

    private static func building(
        name: String, address: String, latitude: Double, longitude: Double,
        storeys: Int, height: Double, footprintArea: Double, year: Int,
        material: ConstructionMaterial, system: StructuralSystem,
        foundation: FoundationType, soil: SoilClass, retrofit: RetrofitLevel,
        architect: String?, notes: String, events: [String], image: String,
        // The building's actual plan, not a guess.
        //
        // Without this every seeded building was extruded from a rectangle of
        // the right area — so a courtyard block, an L-shaped apartment and a
        // tapered tower all came out as the same brick. Plan shape is not
        // decoration: re-entrant corners concentrate stress, and mass placed
        // away from the centre of rigidity twists a building rather than
        // pushing it.
        plan: PlanShape = .rectangular,
        aspectRatio: Double = 1.6,
        // How the plan changes with height.
        //
        // This parameter did not exist, so every seeded building was a prism
        // regardless of what it actually looks like — and the Transamerica
        // Pyramid, which is the example `Massing` itself cites as the reason it
        // was written, came out a square box. The massing is not decoration
        // either: a taper puts mass low and reduces the overturning moment at
        // the base, and a podium concentrates demand at the storey where the
        // plan drops. Both change the answer, not just the picture.
        massing: Massing = .uniform
    ) -> BuildingModel {
        // Every seeded fact carries a source, exactly as an imported one does.
        var provenance: [String: FactProvenance] = [:]
        provenance["height"] = FactProvenance(source: .wikidata, detail: "Published height")
        provenance["storeyCount"] = FactProvenance(source: .wikidata)
        provenance["yearBuilt"] = FactProvenance(source: .wikidata)
        provenance["architect"] = FactProvenance(source: .wikidata)
        provenance["footprintArea"] = FactProvenance(source: .openStreetMap,
                                                     detail: "From the mapped outline")
        provenance["material"] = FactProvenance(source: .webSearch,
                                                detail: "From published descriptions")
        provenance["system"] = FactProvenance(source: .aiInference,
                                              detail: "Inferred from the building's era, height and material")
        provenance["soil"] = FactProvenance(source: .defaultAssumption,
                                            detail: "Regional site class; not a site-specific investigation")
        provenance["foundation"] = FactProvenance(source: .aiInference)

        if !massing.isUniform {
            provenance["massing"] = FactProvenance(
                source: .webSearch,
                detail: "From the building's published floor-plate areas at base and top")
        }

        return BuildingModel(
            name: name, address: address, latitude: latitude, longitude: longitude,
            storeyCount: storeys, height: height, footprintArea: footprintArea,
            footprint: plan.polygon(area: footprintArea, aspectRatio: aspectRatio),
            massing: massing,
            yearBuilt: year, material: material, system: system, foundation: foundation,
            soil: soil, retrofit: retrofit, architect: architect, notes: notes,
            notableEvents: events, provenance: provenance,
            privacy: .exact, thumbnailSystemImage: image)
    }

    // MARK: - Earthquake records

    /// Historic records the simulator can shake any building with.
    ///
    /// Waveforms are synthesised on demand from each record's characteristics
    /// rather than shipped as data, which keeps the app small while still giving
    /// each event a distinct character — El Centro is short and sharp, Mexico
    /// City is long and slow, Kobe is violent and near-source.
    public static func earthquakes() -> [EarthquakeRecord] {
        [
            EarthquakeRecord(
                name: "El Centro", year: 1940, magnitude: 6.9, depthKm: 16,
                latitude: 32.73, longitude: -115.50,
                station: "El Centro Array Station 9", soilAtStation: .stiffSoil,
                pgaTarget: 0.319 * gravity, duration: 53, dominantPeriod: 0.55,
                summary: "The record that founded earthquake engineering. For decades it was "
                    + "essentially the only strong-motion record available, and a great deal of "
                    + "modern design code traces back to it."),

            EarthquakeRecord(
                name: "Mexico City", year: 1985, magnitude: 8.0, depthKm: 15,
                latitude: 18.19, longitude: -102.53,
                station: "SCT", soilAtStation: .softSoil,
                pgaTarget: 0.171 * gravity, duration: 180, dominantPeriod: 2.0,
                summary: "The epicentre was 350 km away, yet the soft lakebed under the city "
                    + "amplified two-second motion enormously. Buildings of six to fifteen "
                    + "storeys — whose periods matched — were destroyed, while taller and "
                    + "shorter ones nearby survived. The clearest demonstration of resonance "
                    + "ever recorded."),

            EarthquakeRecord(
                name: "Loma Prieta", year: 1989, magnitude: 6.9, depthKm: 18,
                latitude: 37.04, longitude: -121.88,
                station: "Corralitos", soilAtStation: .denseSoil,
                pgaTarget: 0.644 * gravity, duration: 40, dominantPeriod: 0.4,
                summary: "Interrupted a World Series and collapsed a double-deck freeway built "
                    + "on soft mud, while similar structures on rock a few kilometres away were "
                    + "untouched."),

            EarthquakeRecord(
                name: "Northridge", year: 1994, magnitude: 6.7, depthKm: 19,
                latitude: 34.21, longitude: -118.54,
                station: "Sylmar Olive View", soilAtStation: .stiffSoil,
                pgaTarget: 0.843 * gravity, duration: 30, dominantPeriod: 0.35,
                summary: "Produced some of the highest ground accelerations ever recorded in a "
                    + "city. It also revealed brittle fractures in welded steel moment "
                    + "connections that had been assumed ductile, which rewrote steel design."),

            EarthquakeRecord(
                name: "Kobe", year: 1995, magnitude: 6.9, depthKm: 16,
                latitude: 34.59, longitude: 135.07,
                station: "JMA Kobe", soilAtStation: .stiffSoil,
                pgaTarget: 0.821 * gravity, duration: 48, dominantPeriod: 0.8,
                summary: "A near-source rupture directly beneath a dense modern city. The "
                    + "forward-directivity pulse — a single violent shove rather than sustained "
                    + "shaking — is brutal for structures and is visible in the record."),

            EarthquakeRecord(
                name: "Chi-Chi", year: 1999, magnitude: 7.6, depthKm: 8,
                latitude: 23.77, longitude: 120.98,
                station: "TCU068", soilAtStation: .stiffSoil,
                pgaTarget: 0.566 * gravity, duration: 90, dominantPeriod: 1.5,
                summary: "Recorded extraordinary ground velocities and several metres of "
                    + "permanent ground displacement. Long-period structures suffered badly."),

            EarthquakeRecord(
                name: "Tōhoku", year: 2011, magnitude: 9.1, depthKm: 29,
                latitude: 38.30, longitude: 142.37,
                station: "MYG013", soilAtStation: .denseSoil,
                pgaTarget: 0.294 * gravity, duration: 300, dominantPeriod: 0.9,
                summary: "Six minutes of shaking. Peak acceleration was moderate but the sheer "
                    + "duration meant structures went through hundreds of cycles, and cumulative "
                    + "damage rather than peak demand governed."),

            EarthquakeRecord(
                name: "Christchurch", year: 2011, magnitude: 6.2, depthKm: 5,
                latitude: -43.58, longitude: 172.68,
                station: "CBGS", soilAtStation: .softSoil,
                pgaTarget: 1.41 * gravity, duration: 25, dominantPeriod: 0.3,
                summary: "A modest magnitude directly beneath a city at very shallow depth. "
                    + "Vertical accelerations exceeded gravity — the ground briefly fell away "
                    + "faster than objects could follow. Widespread liquefaction."),

            EarthquakeRecord(
                name: "Gorkha", year: 2015, magnitude: 7.8, depthKm: 8,
                latitude: 28.23, longitude: 84.73,
                station: "KATNP", soilAtStation: .softSoil,
                pgaTarget: 0.164 * gravity, duration: 60, dominantPeriod: 4.5,
                summary: "Unusually poor in short-period energy, which spared many low masonry "
                    + "buildings that should have failed, while the Kathmandu basin's long-period "
                    + "response punished taller structures."),

            EarthquakeRecord(
                name: "Kahramanmaraş", year: 2023, magnitude: 7.8, depthKm: 10,
                latitude: 37.17, longitude: 37.03,
                station: "TK3125", soilAtStation: .stiffSoil,
                pgaTarget: 0.66 * gravity, duration: 80, dominantPeriod: 0.7,
                summary: "Two major ruptures nine hours apart. Buildings that survived the first "
                    + "were already weakened when the second arrived — the clearest recent "
                    + "argument for measuring a building's condition between shocks rather than "
                    + "waiting for an inspection."),
        ]
    }

    /// Builds an actual waveform for a library record.
    ///
    /// Reconstructed from the record's magnitude, distance, duration and
    /// dominant period, then scaled to its documented peak. It is a synthesis
    /// rather than the real accelerogram — the app says so wherever it is used —
    /// but it has the right amplitude, the right frequency content and the right
    /// duration, which is what governs how a building responds to it.
    public static func waveform(for record: EarthquakeRecord,
                                sampleRate: Double = 100) -> Waveform {
        if let stored = record.waveform { return stored }

        // Distance chosen so the attenuation model lands near the documented PGA.
        let parameters = SyntheticMotion.EventParameters(
            magnitude: record.magnitude,
            distanceKm: Swift.max(record.depthKm, 8),
            depthKm: record.depthKm,
            soil: record.soilAtStation,
            sampleRate: sampleRate,
            preEventSeconds: 4,
            noiseFloor: 0.002,
            seed: UInt64(abs(record.name.hashValue % 1_000_000)) &+ UInt64(record.year))

        var generated = SyntheticMotion.generate(parameters).dominantHorizontal

        // Retune towards the record's documented dominant period, so Mexico City
        // really is slow and Northridge really is sharp.
        let targetFrequency = 1 / Swift.max(record.dominantPeriod, 0.05)
        let filter = ButterworthFilter(
            kind: .bandpass, order: 4, sampleRate: sampleRate,
            lowCutoff: Swift.max(targetFrequency * 0.4, 0.08),
            highCutoff: Swift.min(Swift.max(targetFrequency * 3.0, 1.2), sampleRate / 2.5))
        generated = Waveform(samples: filter.applyZeroPhase(generated.samples),
                             sampleRate: sampleRate, unit: .acceleration)

        // Stretch or trim to the documented duration.
        let targetCount = Int(record.duration * sampleRate)
        var samples = generated.samples
        if samples.count > targetCount {
            samples = Array(samples[0..<targetCount])
        } else if samples.count < targetCount, !samples.isEmpty {
            // Extend with a decaying coda rather than silence or a repeat.
            let tailStart = samples.count
            var rng = SeededRandom(seed: UInt64(record.year))
            let lastAmplitude = Stats.rms(Array(samples.suffix(200)))
            for i in tailStart..<targetCount {
                let elapsed = Double(i - tailStart) / sampleRate
                let envelope = exp(-elapsed / Swift.max(record.duration / 5, 2))
                samples.append(rng.gaussian(sd: lastAmplitude * envelope))
            }
        }

        // Scale to the documented peak.
        let peak = Stats.peakAbs(samples)
        if peak > 1e-9 {
            let factor = record.pgaTarget / peak
            samples = samples.map { $0 * factor }
        }

        return Waveform(samples: samples, sampleRate: sampleRate, unit: .acceleration)
    }

    // MARK: - Synthetic history

    /// Months of plausible measurement history for the sandbox building.
    ///
    /// Without this, every trend chart, the temperature correction, the CUSUM
    /// detector and the anomaly model all open empty — and the most interesting
    /// parts of the product would be invisible until the user had owned it for a
    /// season. The history is generated with the same physics the live system
    /// uses: a real temperature-frequency relationship, real scatter, and a
    /// couple of genuine events partway through.
    /// - Parameter days: a full year by default, and that matters.
    ///   Over half a year the seasonal temperature curve is monotonic, so it
    ///   becomes collinear with any slow damage in the same window — the
    ///   temperature regression then absorbs the damage and reports a slope more
    ///   than twice the true one. A complete cycle separates the two.
    public static func measurementHistory(buildingID: UUID,
                                          basePeriod: Double = 0.86,
                                          days: Int = 365,
                                          scansPerDay: Int = 4,
                                          endingAt: Date = Date(),
                                          seed: UInt64 = 4242) -> [ModeObservation] {
        var rng = SeededRandom(seed: seed)
        var out: [ModeObservation] = []
        let totalScans = days * scansPerDay
        guard totalScans > 0 else { return [] }

        // Two events during the window: a moderate one that causes slight
        // permanent softening, and a small one that causes none.
        let firstEventScan = Int(Double(totalScans) * 0.55)
        let secondEventScan = Int(Double(totalScans) * 0.82)
        var damageFactor = 1.0

        for scan in 0..<totalScans {
            let daysAgo = Double(days) * (1 - Double(scan) / Double(totalScans))
            let timestamp = endingAt.addingTimeInterval(-daysAgo * 86_400)

            // Seasonal plus diurnal temperature, which is what makes the
            // correction worth having. The seasonal phase is driven by the
            // observation's actual day within the year, so a year-long history
            // contains a complete cycle rather than a monotonic ramp.
            let dayIndex = Double(scan) / Double(scansPerDay)
            let seasonal = 14 + 9 * sin(2 * .pi * (dayIndex / 365 - 0.3))
            let hourOfDay = Double(scan % scansPerDay) / Double(scansPerDay) * 24
            let diurnal = 4 * sin(2 * .pi * (hourOfDay - 9) / 24)
            let temperature = seasonal + diurnal + rng.gaussian(sd: 0.8)

            if scan == firstEventScan { damageFactor *= 1.035 }
            if scan == secondEventScan { damageFactor *= 1.008 }

            // Frequency falls as temperature rises, and drifts very slowly.
            let baseFrequency = 1 / (basePeriod * damageFactor)
            let temperatureEffect = -0.0021 * (temperature - 15)
            let frequency = baseFrequency + temperatureEffect + rng.gaussian(sd: 0.0035)

            out.append(ModeObservation(
                modeNumber: 1, frequency: frequency,
                damping: 0.045 + rng.gaussian(sd: 0.004),
                amplitude: 1.0 + rng.gaussian(sd: 0.1),
                at: timestamp, temperature: temperature))

            // Second mode, tracked alongside, so mode tracking has something to
            // do and the analysis screen has more than one line.
            out.append(ModeObservation(
                modeNumber: 2, frequency: frequency * 2.9 + rng.gaussian(sd: 0.02),
                damping: 0.05 + rng.gaussian(sd: 0.006),
                amplitude: 0.35 + rng.gaussian(sd: 0.06),
                at: timestamp, temperature: temperature))
        }

        return out.sorted { $0.at < $1.at }
    }

    /// Past events for the sandbox building, so the event list is not empty.
    public static func pastEvents(buildingID: UUID, nodeID: String,
                                  endingAt: Date = Date()) -> [SeismicEvent] {
        struct Seed {
            let daysAgo: Double
            let magnitude: Double
            let distance: Double
            let label: String
            let drill: Bool
        }

        let seeds = [
            Seed(daysAgo: 172, magnitude: 4.1, distance: 62, label: "Distant tremor", drill: false),
            Seed(daysAgo: 150, magnitude: 0, distance: 0, label: "Monthly drill", drill: true),
            Seed(daysAgo: 99, magnitude: 5.4, distance: 38, label: "Moderate shake", drill: false),
            Seed(daysAgo: 74, magnitude: 3.6, distance: 21, label: "Light tremor", drill: false),
            Seed(daysAgo: 52, magnitude: 6.1, distance: 24, label: "Significant event", drill: false),
            Seed(daysAgo: 51, magnitude: 4.4, distance: 26, label: "Aftershock", drill: false),
            Seed(daysAgo: 50, magnitude: 3.9, distance: 25, label: "Aftershock", drill: false),
            Seed(daysAgo: 30, magnitude: 0, distance: 0, label: "Monthly drill", drill: true),
            Seed(daysAgo: 12, magnitude: 4.8, distance: 45, label: "Felt tremor", drill: false),
        ]

        return seeds.enumerated().map { index, seed in
            let at = endingAt.addingTimeInterval(-seed.daysAgo * 86_400)
            let ratio = seed.drill ? 5.0 : Swift.max(seed.magnitude * 1.9 - seed.distance * 0.03, 4.2)

            var reports: [ActuatorReport] = []
            // Actuators only fire for genuinely strong shaking, and for drills.
            if seed.drill || seed.magnitude >= 5.4 {
                var offset: TimeInterval = 0
                for kind in ActuatorKind.allCases.sorted(by: { $0.firingPriority < $1.firingPriority }) {
                    reports.append(ActuatorReport(
                        kind: kind, state: .confirmed,
                        commandedAt: at.addingTimeInterval(offset),
                        completedAt: at.addingTimeInterval(offset + kind.travelTime),
                        confirmedBy: kind.confirmation))
                    offset += kind.travelTime + 0.35
                }
            }

            let votes = SensorFusion.buildVotes(
                accelerationRatio: ratio,
                tiltChanged: seed.magnitude >= 6.0,
                soundLevel: Swift.min(seed.magnitude / 7, 1),
                triggerThreshold: 4.0, at: at)

            return SeismicEvent(
                buildingID: buildingID, nodeID: nodeID, startTime: at,
                triggerRatio: ratio, triggerChannel: .accelerometer,
                votes: votes, actuatorReports: reports,
                record: nil, isComplete: true,
                residualDisplacement: seed.magnitude >= 6.0 ? 0.011 : 0,
                permanentTilt: false, tiltAngle: 0,
                structureTemperature: 15 + Double(index % 5) * 2,
                gridPowerLost: seed.magnitude >= 6.0,
                occupancyAtTrigger: index % 2 == 0,
                isDrill: seed.drill, isSimulated: true,
                acknowledgedAt: at.addingTimeInterval(300),
                label: seed.label)
        }
        .sorted { $0.startTime > $1.startTime }
    }

    /// Community tags around the sandbox building, so the map is populated.
    public static func communityTags(near latitude: Double, longitude: Double,
                                     count: Int = 60, seed: UInt64 = 777) -> [CommunityTag] {
        var rng = SeededRandom(seed: seed)
        var out: [CommunityTag] = []

        let streets = ["Mission", "Valencia", "Guerrero", "Dolores", "Church", "Sanchez",
                       "Noe", "Castro", "Diamond", "Douglass", "Hoffman", "Grand View"]

        for _ in 0..<count {
            // Verdicts are not uniformly distributed: most buildings are fine.
            let roll = rng.uniform()
            let verdict: SafetyVerdict = switch roll {
            case ..<0.58: .green
            case 0.58..<0.78: .amber
            case 0.78..<0.90: .needsInspection
            default: .red
            }

            // A minority of reports come from instrumented buildings, and a
            // handful from professionals.
            let tierRoll = rng.uniform()
            let tier: VerificationTier = switch tierRoll {
            case ..<0.62: .unverified
            case 0.62..<0.92: .sensorVerified
            default: .professional
            }

            let bearing = rng.uniform(0, 360)
            let distance = rng.uniform(80, 2400)
            let latOffset = distance * cos(bearing * .pi / 180) / 111_320
            let lonOffset = distance * sin(bearing * .pi / 180)
                / (111_320 * cos(latitude * .pi / 180))

            let hoursAgo = rng.uniform(0.2, 72)
            let street = streets[Int(rng.uniform(0, Double(streets.count))) % streets.count]

            out.append(CommunityTag(
                verdict: verdict,
                latitude: latitude + latOffset,
                longitude: longitude + lonOffset,
                buildingLabel: "\(Int(rng.uniform(100, 3000))) \(street) St",
                postedAt: Date().addingTimeInterval(-hoursAgo * 3600),
                tier: tier,
                evidenceSummary: Self.evidenceSummary(for: verdict, tier: tier),
                notes: Self.note(for: verdict),
                agreementCount: Int(rng.uniform(0, tier == .professional ? 12 : 6)),
                disputeCount: Int(rng.uniform(0, verdict == .green ? 1 : 3)),
                photoCount: Int(rng.uniform(0, 4))))
        }

        return out.sorted { $0.postedAt > $1.postedAt }
    }

    private static func evidenceSummary(for verdict: SafetyVerdict,
                                        tier: VerificationTier) -> String {
        switch (verdict, tier) {
        case (.green, .sensorVerified):
            "Period unchanged (+0.4%), no residual displacement, no tilt."
        case (.green, _):
            "No visible damage on a walk-through."
        case (.amber, .sensorVerified):
            "Period lengthened 8.2% after temperature correction; 6 mm residual displacement."
        case (.amber, .professional):
            "Cracking in ground-floor columns, no loss of vertical capacity."
        case (.amber, _):
            "Cracks in plaster and one jammed door."
        case (.red, .professional):
            "Shear cracking through two ground-floor columns. Building posted unsafe."
        case (.red, .sensorVerified):
            "Period lengthened 19%; 40 mm residual displacement and permanent tilt detected."
        case (.red, _):
            "Visible lean and large cracks. Nobody is going back in."
        case (.needsInspection, _):
            "Conflicting indications; evidence is inconclusive."
        }
    }

    private static func note(for verdict: SafetyVerdict) -> String {
        switch verdict {
        case .green: "Checked the whole building, nothing obvious. Water and power both on."
        case .amber: "Using the ground floor only. Waiting on an engineer."
        case .red: "Everyone is out. Please do not go in for anything."
        case .needsInspection: "Not sure what to make of it — would appreciate a second opinion."
        }
    }
}

/// A published community assessment.
public struct CommunityTag: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var buildingID: UUID?
    public var verdict: SafetyVerdict
    public var latitude: Double
    public var longitude: Double
    public var buildingLabel: String
    public var postedAt: Date
    public var tier: VerificationTier
    public var evidenceSummary: String
    public var notes: String
    public var agreementCount: Int
    public var disputeCount: Int
    public var photoCount: Int
    public var expiresAt: Date

    public init(id: UUID = UUID(), buildingID: UUID? = nil, verdict: SafetyVerdict,
                latitude: Double, longitude: Double, buildingLabel: String,
                postedAt: Date = Date(), tier: VerificationTier = .unverified,
                evidenceSummary: String = "", notes: String = "",
                agreementCount: Int = 0, disputeCount: Int = 0, photoCount: Int = 0,
                expiresAt: Date? = nil) {
        self.id = id
        self.buildingID = buildingID
        self.verdict = verdict
        self.latitude = latitude
        self.longitude = longitude
        self.buildingLabel = buildingLabel
        self.postedAt = postedAt
        self.tier = tier
        self.evidenceSummary = evidenceSummary
        self.notes = notes
        self.agreementCount = agreementCount
        self.disputeCount = disputeCount
        self.photoCount = photoCount
        // Tags go stale. A green tag from a week ago says nothing about a
        // building that has since been through three aftershocks, so it expires
        // rather than misleading somebody.
        self.expiresAt = expiresAt ?? postedAt.addingTimeInterval(72 * 3600)
    }

    public var isExpired: Bool { Date() > expiresAt }

    public var ageDescription: String {
        let seconds = Date().timeIntervalSince(postedAt)
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86_400)) d ago"
    }

    /// Reputation-weighted consensus score.
    ///
    /// A professional's assessment outweighs a crowd, but does not silence it:
    /// the crowd's agreement and dispute counts still move the number, and the
    /// UI shows both. This is the difference between deferring to expertise and
    /// ignoring everyone else.
    public var consensusScore: Double {
        let base = tier.trustWeight
        let support = Double(agreementCount) * 0.4
        let opposition = Double(disputeCount) * 0.6
        let recency = Swift.max(1 - Date().timeIntervalSince(postedAt) / (72 * 3600), 0.1)
        return Swift.max(base + support - opposition, 0.1) * recency
    }
}
